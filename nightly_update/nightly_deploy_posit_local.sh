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
# config/sponsor_norm_v2/ is deliberately absent. It is the mutable registry, it
# lives outside the work tree via SPONSOR_V2_DIR, and committing it would both
# fight the `git reset --hard` below and add megabytes of churn per night.
GENERATED_FILES=(
    "trials_cache.rds"
    "www/preprocessing.html"
    "config/substance_norm_pipeline/3_substance_review_queue.csv"
    "data/country_normalisation_log.csv"
    "data/meddra_term_normalisation_log.csv"
    "data/organ_class_normalisation_log.csv"
    "data/phase_normalisation_log.csv"
    "data/sponsor_normalisation_log.csv"
    "data/sponsor_normalisation_log_v2.csv"
    "data/status_category_normalisation_log.csv"
    "data/status_display_normalisation_log.csv"
    "data/substance_normalisation_log.csv"
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
    ':(exclude)config/substance_norm_pipeline/3_substance_review_queue.csv'
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
rm -f "$SPONSOR_SENTINEL"

log "Step 2/4: Rebuilding RDS cache..."
docker exec "$instanceName" Rscript /shiny_trials/shiny_trials/rebuild_cache.R >> "$LOG_FILE" 2>&1

SPONSOR_FAILED=0
if [ -f "$SPONSOR_SENTINEL" ]; then
    SPONSOR_FAILED=1
    log "ERROR: sponsor nightly resolution failed — $(cat "$SPONSOR_SENTINEL")"
    log "       see \$SPONSOR_V2_DIR/N_nightly_runs.csv for the full history"
fi

# 3. Commit generated files on deploy only and push to trigger Posit Cloud deploy.
log "Step 3/4: Committing generated deploy artifacts..."
# -f is REQUIRED: the label CSVs and logs are gitignored, and a plain `git add`
# skips them silently — the deploy would push a cache with no labels beside it.
git add -f "${GENERATED_FILES[@]}" >> "$LOG_FILE" 2>&1
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
    exit "$SPONSOR_FAILED"
fi
timeout "$PUSH_TIMEOUT_SECONDS" git push --force-with-lease "$REMOTE" "$DEPLOY_BRANCH" >> "$LOG_FILE" 2>&1 \
    && log "Push succeeded." \
    || { log "ERROR: git push failed or timed out after ${PUSH_TIMEOUT_SECONDS}s."; exit 1; }

log "=== Nightly deploy complete ==="

# Report a sponsor failure only AFTER the push: the app must still ship. cron
# mails on a non-zero exit, which is the only alerting this job has.
if [ "$SPONSOR_FAILED" -ne 0 ]; then
    log "Exiting non-zero: the deploy shipped, but sponsor resolution failed."
    exit 3
fi
