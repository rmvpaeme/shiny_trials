# Rebuilds the RDS cache from the SQLite database.
# Run this after update_data.R to regenerate trials_cache.rds.
# Usage: Rscript rebuild_cache.R

message("=== Rebuilding RDS cache ===")

# Source app.R to load all data-prep functions and trigger cache rebuild.
# After update_data.R runs, the SQLite DB is newer than the cache, so
# load_trial_data() will automatically rebuild and save the .rds file.
try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)
source("app.R")

message("=== Cache rebuild complete ===")

# ── Regenerate preprocessing report ──────────────────────────────────────────
# Knit preprocessing.Rmd against the freshly rebuilt cache and write the
# self-contained HTML to www/ so the Shiny app can serve it from the About tab.
message("=== Regenerating preprocessing report ===")
tryCatch({
  if (!requireNamespace("rmarkdown", quietly = TRUE))
    stop("rmarkdown package not available")
  if (!file.exists("preprocessing.Rmd"))
    stop("preprocessing.Rmd not found")

  # Rscript launched from cron/CLI doesn't inherit RStudio's pandoc.
  # Search known locations and expose the first one found.
  if (!rmarkdown::pandoc_available()) {
    pandoc_search <- c(
      Sys.getenv("RSTUDIO_PANDOC"),
      "/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools",
      "/Applications/RStudio.app/Contents/MacOS/pandoc",
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin"
    )
    pandoc_search <- pandoc_search[nzchar(pandoc_search)]
    has_pandoc <- function(d) file.exists(file.path(d, "pandoc"))
    found <- Filter(has_pandoc, pandoc_search)
    if (length(found) == 0L)
      stop("pandoc not found; install pandoc or run from RStudio")
    Sys.setenv(RSTUDIO_PANDOC = found[[1L]])
    message("Using pandoc from: ", found[[1L]])
  }

  if (!dir.exists("www")) dir.create("www")
  rmarkdown::render(
    input       = "preprocessing.Rmd",
    output_file = "www/preprocessing.html",
    quiet       = TRUE
  )
  message("=== Preprocessing report written to www/preprocessing.html ===")
}, error = function(e) {
  message("WARNING: preprocessing report generation failed — ", conditionMessage(e))
  message("         Cache rebuild was successful; report will be stale until next run.")
})
