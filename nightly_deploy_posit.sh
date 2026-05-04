#!/bin/bash
# Nightly job: update DB, rebuild cache, commit, push to GitHub (triggers Posit Cloud deploy)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/nightly_deploy.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Nightly deploy started ==="
cd "$SCRIPT_DIR"

# 0. Pull latest app code from GitHub before running anything
log "Step 0/3: Pulling latest from GitHub..."
git pull --rebase --autostash >> "$LOG_FILE" 2>&1 || { log "ERROR: git pull --rebase failed."; exit 1; }

# 1. Update the SQLite database
log "Step 1/3: Updating database..."
Rscript update_data.R >> "$LOG_FILE" 2>&1

# 2. Rebuild the RDS cache from the updated database
log "Step 2/3: Rebuilding RDS cache..."
Rscript rebuild_cache.R >> "$LOG_FILE" 2>&1

# 3. Commit updated cache files and push to trigger Posit Cloud deploy
log "Step 3/3: Committing and pushing..."
git add trials_cache.rds >> "$LOG_FILE" 2>&1
if git diff --cached --quiet; then
    log "No cache changes, skipping commit."
else
    git commit -m "chore: nightly cache update $(date '+%Y-%m-%d')" >> "$LOG_FILE" 2>&1
fi
git push >> "$LOG_FILE" 2>&1 && log "Push succeeded." || log "ERROR: git push failed (exit $?)."

log "=== Nightly deploy complete ==="
