#!/bin/bash
# Nightly job: update DB, rebuild cache, commit generated artifacts to `deploy`,
# push to trigger the Posit Cloud deploy.
#
# THIS IS THE COPY THAT RUNS ON THE SERVER. It was maintained by hand there and
# had drifted from the repo (the repo copy staged 2 files; this stages 16, and
# uses `git add -f` because the label CSVs are gitignored). Committed here
# 2026-08-16 so the two cannot drift again — edit this file, then copy it to the
# server, rather than editing the server copy in place.
#
# Expects to live at the REPO ROOT on the server: every git path below is
# relative to $SCRIPT_DIR.

set -e

instanceName="rstudio-rstudio-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/nightly_deploy.log"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-deploy}"
REMOTE="${REMOTE:-origin}"
PUSH_TIMEOUT_SECONDS="${PUSH_TIMEOUT_SECONDS:-120}"
# Force-added below: data/*labels*, data/*log* and the raw exports are gitignored
# so they never reach main, but the deploy branch is how they reach Posit — the
# app reads data/trial_sponsor_labels.csv at startup.
#
# The four config/ entries are the curation app's inputs. It runs on Posit with
# a read-only filesystem and no database, so it fetches everything it displays
# from the public repo — which means the queue and registry have to BE there,
# and be current. See the publish step below for why listing them is not enough.
#
# assignments.csv is deliberately NOT here: 7.4 MB rewritten nightly, and the
# app does not need it (siblings on a canonical are derivable from the cache,
# which carries both sponsor_name_raw and sponsor_clean). registry.csv is 916 KB
# + 2.4 MB and only changes when the nightly mints, so the earlier blanket
# "megabytes of churn per night" objection is true of assignments and not of
# these — measured at roughly +0.35 MB/night steady state.
#
# Safe only because `deploy` is FORCE-PUSHED and reset to origin/main every
# night. If it ever becomes an ordinary branch these files conflict every run.
GENERATED_FILES=(
    "trials_cache.rds"
    "www/preprocessing.html"
    "config/sponsor_norm_v2/E_review_queue.csv"
    "config/sponsor_norm_v2/registry.csv"
    "config/substance_norm_v2/E_review_queue.csv"
    "config/substance_norm_v2/registry.csv"
    "data/trial_overrides.csv"
    "data/country_normalisation_log.csv"
    "data/meddra_term_normalisation_log.csv"
    "data/organ_class_normalisation_log.csv"
    "data/phase_normalisation_log.csv"
    "data/sponsor_normalisation_log.csv"
    "data/sponsor_normalisation_log_v2.csv"
    "data/status_category_normalisation_log.csv"
    "data/status_display_normalisation_log.csv"
    "data/substance_normalisation_log_v2.csv"
    "data/substance_rejected.csv"
    "data/trial_sponsor_labels.csv"
    "data/trial_sponsors_raw.csv"
    "data/trial_substance_labels.csv"
    "data/trial_substances_raw.csv"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Nightly deploy started ==="
cd "$SCRIPT_DIR"

# 0. Rebuild deploy from the latest source branch.
log "Step 0/4: Fetching latest from GitHub..."
git fetch "$REMOTE" >> "$LOG_FILE" 2>&1 || { log "ERROR: git fetch failed."; exit 1; }

# Dirty check, SCOPED to files a human would have edited.
#
# Unscoped, this wedges the nightly permanently: the run rewrites generated
# artefacts, so a run that dies after writing them but before committing leaves
# every subsequent night exiting 1 here until someone logs in. Those paths are
# regenerated from scratch anyway.
GENERATED_PATHSPEC=(
    ':(exclude)trials_cache.rds'
    ':(exclude)www/preprocessing.html'
    ':(exclude)data'
    ':(exclude)config/sponsor_norm_v2'
    ':(exclude)config/substance_norm_v2'
)
if ! git diff --quiet -- . "${GENERATED_PATHSPEC[@]}" ||
   ! git diff --cached --quiet -- . "${GENERATED_PATHSPEC[@]}"; then
    log "ERROR: Work tree has local changes. Commit/stash them before nightly deploy."
    git status --short -- . "${GENERATED_PATHSPEC[@]}" >> "$LOG_FILE" 2>&1
    exit 1
fi

if git show-ref --verify --quiet "refs/heads/$DEPLOY_BRANCH"; then
    log "Checking out existing $DEPLOY_BRANCH branch..."
    git checkout "$DEPLOY_BRANCH" >> "$LOG_FILE" 2>&1
else
    log "Creating local $DEPLOY_BRANCH branch from $REMOTE/$SOURCE_BRANCH..."
    git checkout -b "$DEPLOY_BRANCH" "$REMOTE/$SOURCE_BRANCH" >> "$LOG_FILE" 2>&1
fi

log "Resetting $DEPLOY_BRANCH to $REMOTE/$SOURCE_BRANCH..."
git reset --hard "$REMOTE/$SOURCE_BRANCH" >> "$LOG_FILE" 2>&1 || {
    log "ERROR: reset to $REMOTE/$SOURCE_BRANCH failed."
    exit 1
}

# 1. Update the SQLite database
log "Step 1/4: Updating database..."
docker exec "$instanceName" Rscript /shiny_trials/shiny_trials/update_data.R >> "$LOG_FILE" 2>&1

# 2. Rebuild the RDS cache from the updated database.
#
# Clear any sentinel from a previous night first, or a stale one reports a
# failure that already happened. rebuild_cache.R deliberately exits 0 even when
# sponsor resolution fails — `set -e` above would otherwise abort before
# trials_cache.rds is committed, losing the whole data refresh over an LLM
# hiccup. The sentinel is how that failure still gets reported.
SPONSOR_SENTINEL="$SCRIPT_DIR/data/.sponsor_nightly_failed"
SUBSTANCE_SENTINEL="$SCRIPT_DIR/data/.substance_nightly_failed"
rm -f "$SPONSOR_SENTINEL" "$SUBSTANCE_SENTINEL"

log "Step 2/4: Rebuilding RDS cache..."
docker exec "$instanceName" Rscript /shiny_trials/shiny_trials/rebuild_cache.R >> "$LOG_FILE" 2>&1

NORM_FAILED=0
if [ -f "$SUBSTANCE_SENTINEL" ]; then
    NORM_FAILED=1
    log "ERROR: substance nightly resolution failed — $(cat "$SUBSTANCE_SENTINEL")"
    log "       see \$SUBSTANCE_V2_DIR/N_nightly_runs.csv for the full history"
fi
SPONSOR_FAILED=0
if [ -f "$SPONSOR_SENTINEL" ]; then
    SPONSOR_FAILED=1
    log "ERROR: sponsor nightly resolution failed — $(cat "$SPONSOR_SENTINEL")"
    log "       see \$SPONSOR_V2_DIR/N_nightly_runs.csv for the full history"
fi

# ── Publish the LIVE registries and queues into the work tree ────────────────
#
# `git add -f <path>` stages the WORK TREE copy. After the `git reset --hard
# origin/main` above that is main's frozen version — NOT the live file, which
# lives outside the work tree in $SPONSOR_V2_DIR / $SUBSTANCE_V2_DIR precisely
# so the reset cannot revert it (see AGENTS/DEPLOY.md).
#
# So listing a queue in GENERATED_FILES is not enough, and this is not
# hypothetical: config/substance_norm_v2/E_review_queue.csv has been listed
# since 2026-08-22 and has published main's frozen copy every night since,
# silently. The curation app reads its backlog from the deploy branch, so
# without this it would show a queue that never changes and nothing would say
# why.
#
# NOTE THE PATHS ARE HOST PATHS. SPONSOR_V2_DIR is the CONTAINER path
# (/shiny_trials/sponsor_norm_v2); this script runs on the host, where the same
# directory is a sibling of the repo checkout under the existing
# /home/ruben/shiny_trials:/shiny_trials bind mount.
SPONSOR_V2_DIR_HOST="${SPONSOR_V2_DIR_HOST:-$(dirname "$SCRIPT_DIR")/sponsor_norm_v2}"
SUBSTANCE_V2_DIR_HOST="${SUBSTANCE_V2_DIR_HOST:-$(dirname "$SCRIPT_DIR")/substance_norm_v2}"

publish_live() {   # $1 = live source dir, $2 = work-tree dir, $3 = filename
    if [ -f "$1/$3" ]; then
        cp -f "$1/$3" "$2/$3"
    else
        # Loud on purpose. A silent skip here republishes main's stale copy and
        # looks exactly like success, which is the failure this whole block
        # exists to end.
        log "WARNING: $1/$3 not found — publishing main's frozen $2/$3 instead."
    fi
}

for _f in E_review_queue.csv registry.csv; do
    publish_live "$SPONSOR_V2_DIR_HOST"   "config/sponsor_norm_v2"   "$_f"
    publish_live "$SUBSTANCE_V2_DIR_HOST" "config/substance_norm_v2" "$_f"
done

# 3. Commit generated files on deploy only and push to trigger Posit Cloud deploy.
log "Step 3/4: Committing generated deploy artifacts..."
# -f is REQUIRED: the label CSVs and logs are gitignored, and a plain `git add`
# skips them silently — the deploy would push a cache with no labels beside it.
# Only stage what exists. A `git add -f` on a missing pathspec is FATAL, and
# under `set -e` that aborts the deploy before it pushes — so a blocked
# regression gate, which is a SUCCESSFUL outcome (yesterday's labels are kept on
# purpose), would take the whole deploy down with it. E_emit does not write its
# log when the gate blocks, which is exactly when this fires.
STAGE_FILES=()
for _f in "${GENERATED_FILES[@]}"; do
    [ -e "$_f" ] && STAGE_FILES+=("$_f")
done
if [ ${#STAGE_FILES[@]} -eq 0 ]; then
    log "WARNING: none of the generated files exist — nothing to commit."
else
    git add -f "${STAGE_FILES[@]}" >> "$LOG_FILE" 2>&1
fi
if git diff --cached --quiet; then
    log "No generated changes, skipping commit."
else
    git commit -m "chore: nightly deploy refresh $(date '+%Y-%m-%d')" >> "$LOG_FILE" 2>&1
fi

log "Step 4/4: Pushing $DEPLOY_BRANCH..."
if ! git ls-remote --exit-code --heads "$REMOTE" "$DEPLOY_BRANCH" >> "$LOG_FILE" 2>&1; then
    log "Remote $DEPLOY_BRANCH branch does not exist yet; first push will create it."
elif git rev-parse --verify --quiet "$REMOTE/$DEPLOY_BRANCH" >> "$LOG_FILE" 2>&1 &&
     [ "$(git rev-parse "$DEPLOY_BRANCH")" = "$(git rev-parse "$REMOTE/$DEPLOY_BRANCH")" ]; then
    log "Remote $DEPLOY_BRANCH already matches local $DEPLOY_BRANCH; skipping push."
    log "=== Nightly deploy complete ==="
    exit $(( SPONSOR_FAILED || NORM_FAILED ))
fi
timeout "$PUSH_TIMEOUT_SECONDS" git push --force-with-lease "$REMOTE" "$DEPLOY_BRANCH" >> "$LOG_FILE" 2>&1 \
    && log "Push succeeded." \
    || { log "ERROR: git push failed or timed out after ${PUSH_TIMEOUT_SECONDS}s."; exit 1; }

log "=== Nightly deploy complete ==="

# Report a sponsor failure only AFTER the push: the app must still ship. cron
# mails on a non-zero exit, which is the only alerting this job has.
if [ "$SPONSOR_FAILED" -ne 0 ] || [ "$NORM_FAILED" -ne 0 ]; then
    log "Exiting non-zero: the deploy shipped, but sponsor resolution failed."
    exit 3
fi
