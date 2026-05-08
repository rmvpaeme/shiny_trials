#!/bin/bash
# Nightly job: update DB, rebuild cache, sync to deploy/, push to shinyapps.io

set -e

instanceName="shiny_trials"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$SCRIPT_DIR/nightly_deploy.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Nightly deploy started ==="
cd "$PROJECT_DIR"

# 1. Update the SQLite database
log "Step 1/4: Updating database..."
docker exec -it $instanceName Rscript update_data.R >> "$LOG_FILE" 2>&1

# 2. Rebuild the RDS cache from the updated database
log "Step 2/4: Rebuilding RDS cache..."
docker exec -it $instanceName Rscript  rebuild_cache.R >> "$LOG_FILE" 2>&1

# 3. Sync app.R and cache to deploy/
log "Step 3/4: Syncing files to deploy/..."
cp app.R deploy/app.R
mkdir -p deploy/rmarkdown
cp rmarkdown/report.Rmd deploy/rmarkdown/report.Rmd
cp pediatric_trials_cache.rds deploy/pediatric_trials_cache.rds
cp trials_cache.rds deploy/trials_cache.rds
cp rmarkdown/comparison_report.Rmd deploy/rmarkdown/comparison_report.Rmd
cp rmarkdown/preprocessing.Rmd deploy/rmarkdown/preprocessing.Rmd
cp www/preprocessing.html deploy/www/preprocessing.html

# 4. Deploy to shinyapps.io
log "Step 4/4: Deploying to shinyapps.io..."
docker exec -it $instanceName Rscript  -e "rsconnect::deployApp('deploy/', forceUpdate = TRUE, launch.browser = FALSE)" >> "$LOG_FILE" 2>&1

log "=== Nightly deploy complete ==="
