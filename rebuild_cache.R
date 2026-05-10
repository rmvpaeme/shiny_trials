# Rebuilds the RDS cache from the SQLite database.
# Run this after update_data.R to regenerate trials_cache.rds.
# Usage: Rscript rebuild_cache.R

message("=== Rebuilding RDS cache ===")

# Source app.R to load all data-prep functions and trigger cache rebuild.
# After update_data.R runs, the SQLite DB is newer than the cache, so
# load_trial_data() will automatically rebuild and save the .rds file.
try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)
source("app.R")

# ── Substance normalisation pipeline ─────────────────────────────────────────
# Runs after the cache is on disk so export_trial_substances.R can read it.
# Produces data/trial_substance_labels.csv which app.R reads at startup.
message("=== Building substance labels ===")
rscript_bin <- function() {
  bin <- file.path(R.home("bin"), "Rscript")
  if (file.exists(bin)) bin else "Rscript"
}
export_script  <- file.path("helper_scripts", "substance_norm_pipeline", "export_trial_substances.R")
build_script   <- file.path("helper_scripts", "substance_norm_pipeline", "build_substance_labels.R")

if (file.exists(export_script) && file.exists(build_script)) {
  status <- system2(rscript_bin(), export_script)
  if (!identical(status, 0L)) {
    warning("export_trial_substances.R exited with status ", status)
  } else {
    status <- system2(rscript_bin(), c(build_script, "--write-queue"))
    if (!identical(status, 0L)) warning("build_substance_labels.R exited with status ", status)
  }
  message("=== Substance labels build complete ===")
} else {
  warning("Substance normalisation scripts not found — skipping label build")
}

message("=== Cache rebuild complete ===")

# ── Regenerate preprocessing report ──────────────────────────────────────────
# Knit rmarkdown/preprocessing.Rmd against the freshly rebuilt cache and write the
# self-contained HTML to www/ so the Shiny app can serve it from the About tab.
render_preprocessing <- identical(Sys.getenv("RENDER_PREPROCESSING", unset = "auto"), "true") ||
  (identical(Sys.getenv("RENDER_PREPROCESSING", unset = "auto"), "auto") &&
     identical(Sys.getenv("CACHE_PATH", unset = "trials_cache.rds"), "trials_cache.rds"))

if (!render_preprocessing) {
  message("=== Skipping preprocessing report for non-standard CACHE_PATH ===")
} else {
  message("=== Regenerating preprocessing report ===")
  tryCatch({
    if (!requireNamespace("rmarkdown", quietly = TRUE))
      stop("rmarkdown package not available")
    preprocessing_path <- file.path("rmarkdown", "preprocessing.Rmd")
    if (!file.exists(preprocessing_path))
      stop("rmarkdown/preprocessing.Rmd not found")

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
      input       = preprocessing_path,
      output_file = normalizePath(file.path("www", "preprocessing.html"), mustWork = FALSE),
      params      = list(
        cache_path = normalizePath("trials_cache.rds", mustWork = FALSE),
        log_dir = normalizePath("data", mustWork = FALSE)
      ),
      quiet       = TRUE
    )
    message("=== Preprocessing report written to www/preprocessing.html ===")
  }, error = function(e) {
    message("WARNING: preprocessing report generation failed — ", conditionMessage(e))
    message("         Cache rebuild was successful; report will be stale until next run.")
  })
}
