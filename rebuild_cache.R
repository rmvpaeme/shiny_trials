# Rebuilds the RDS cache from the SQLite database.
# Run this after update_data.R to regenerate pediatric_trials_cache.rds.
# Usage: Rscript rebuild_cache.R

message("=== Rebuilding RDS cache ===")

# Source app.R to load all data-prep functions and trigger cache rebuild.
# After update_data.R runs, the SQLite DB is newer than the cache, so
# load_trial_data() will automatically rebuild and save the .rds file.
source("app.R")

message("=== Cache rebuild complete ===")
