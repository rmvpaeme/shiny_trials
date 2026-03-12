#!/bin/bash
# Nightly job: update DB, rebuild cache, sync to deploy/, push to shinyapps.io

set -e

instanceName="shiny_trials"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/nightly_deploy.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Nightly deploy started ==="
cd "$SCRIPT_DIR"

# 1. Update the SQLite database
log "Step 1/4: Updating database..."
docker exec -it $instanceName Rscript update_data.R >> "$LOG_FILE" 2>&1

# 2. Rebuild the RDS cache from the updated database
log "Step 2/4: Rebuilding RDS cache..."
docker exec -it $instanceName Rscript  rebuild_cache.R >> "$LOG_FILE" 2>&1

# 3. Sync app.R and cache to deploy/
log "Step 3/4: Syncing files to deploy/..."
docker exec -it $instanceName cp /app/app.R /app/data/deploy/app.R
docker exec -it $instanceName cp /app/data/pediatric_trials_cache.rds /app/data/deploy/pediatric_trials_cache.rds

# 4. Deploy to shinyapps.io
log "Step 4/4: Deploying to shinyapps.io..."
docker exec -it $instanceName Rscript  -e "rsconnect::deployApp('/app/data/deploy', forceUpdate = TRUE, launch.browser = FALSE)" >> "$LOG_FILE" 2>&1

log "=== Nightly deploy complete ==="
