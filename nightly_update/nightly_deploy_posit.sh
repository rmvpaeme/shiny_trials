#!/bin/bash
# Nightly job: rebuild deploy branch from main, update DB/cache inside the
# RStudio Docker container, commit generated artifacts, and push deploy to
# GitHub (triggers Posit Cloud deploy).

set -e

INSTANCE_NAME="${INSTANCE_NAME:-rstudio-rstudio-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$SCRIPT_DIR/nightly_deploy.log"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-deploy}"
REMOTE="${REMOTE:-origin}"
PUSH_TIMEOUT_SECONDS="${PUSH_TIMEOUT_SECONDS:-120}"
GENERATED_FILES=(
    "trials_cache.rds"
    "www/preprocessing.html"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Nightly deploy started ==="
cd "$PROJECT_DIR"

# 0. Rebuild deploy from the latest source branch.
log "Step 0/4: Fetching latest from GitHub..."
git fetch "$REMOTE" >> "$LOG_FILE" 2>&1 || { log "ERROR: git fetch failed."; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
    log "ERROR: Work tree has local changes. Commit/stash them before nightly deploy."
    git status --short >> "$LOG_FILE" 2>&1
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
docker exec "$INSTANCE_NAME" Rscript /shiny_trials/shiny_trials/update_data.R >> "$LOG_FILE" 2>&1

# 2. Rebuild the RDS cache from the updated database
log "Step 2/4: Rebuilding RDS cache and preprocessing report..."
docker exec "$INSTANCE_NAME" Rscript /shiny_trials/shiny_trials/rebuild_cache.R >> "$LOG_FILE" 2>&1

# 3. Commit generated files on deploy only and push to trigger Posit Cloud deploy.
log "Step 3/4: Committing generated deploy artifacts..."
git add "${GENERATED_FILES[@]}" >> "$LOG_FILE" 2>&1
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
    exit 0
fi
timeout "$PUSH_TIMEOUT_SECONDS" git push --force-with-lease "$REMOTE" "$DEPLOY_BRANCH" >> "$LOG_FILE" 2>&1 \
    && log "Push succeeded." \
    || { log "ERROR: git push failed or timed out after ${PUSH_TIMEOUT_SECONDS}s."; exit 1; }

log "=== Nightly deploy complete ==="
