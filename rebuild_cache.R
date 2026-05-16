# Rebuilds the RDS cache from the SQLite database.
# Run this after update_data.R to regenerate trials_cache.rds.
# Usage: Rscript rebuild_cache.R

message("=== Rebuilding RDS cache ===")

# Source app.R to load all data-prep functions and trigger cache rebuild.
# After update_data.R runs, the SQLite DB is newer than the cache, so
# load_trial_data() will automatically rebuild and save the .rds file.
try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)
source("app.R")

rscript_bin <- function() {
  bin <- file.path(R.home("bin"), "Rscript")
  if (file.exists(bin)) bin else "Rscript"
}

run_pipeline <- function(export_script, build_script, label, extra_args = character()) {
  if (!file.exists(export_script) || !file.exists(build_script)) {
    warning(label, " scripts not found — skipping")
    return(invisible(FALSE))
  }
  status <- system2(rscript_bin(), export_script)
  if (!identical(status, 0L)) {
    warning(basename(export_script), " exited with status ", status)
    return(invisible(FALSE))
  }
  status <- system2(rscript_bin(), c(build_script, extra_args))
  if (!identical(status, 0L)) warning(basename(build_script), " exited with status ", status)
  invisible(identical(status, 0L))
}

# ── Sponsor normalisation pipeline ────────────────────────────────────────────
# Runs after the cache is on disk so export_trial_sponsors.R can read it.
message("=== Building sponsor labels ===")
run_pipeline(
  file.path("helper_scripts", "sponsor_norm_pipeline", "export_trial_sponsors.R"),
  file.path("helper_scripts", "sponsor_norm_pipeline", "build_sponsor_labels.R"),
  "Sponsor normalisation"
)
message("=== Sponsor labels build complete ===")

# ── Substance normalisation pipeline ─────────────────────────────────────────
# Runs after the cache is on disk so export_trial_substances.R can read it.
message("=== Building substance labels ===")
run_pipeline(
  file.path("helper_scripts", "substance_norm_pipeline", "export_trial_substances.R"),
  file.path("helper_scripts", "substance_norm_pipeline", "build_substance_labels.R"),
  "Substance normalisation",
  "--write-queue"
)
message("=== Substance labels build complete ===")

message("=== Refreshing cache with latest substance labels and PIP helpers ===")
tryCatch({
  if (!file.exists(CACHE_PATH))
    stop("Cache not found at ", CACHE_PATH)
  d <- readRDS(CACHE_PATH)
  substance_labels_path <- file.path(dirname(DB_PATH), "trial_substance_labels.csv")
  if (file.exists(substance_labels_path)) {
    d <- dplyr::select(d, -dplyr::any_of("substance_label"))
    sub_labels <- readr::read_csv(substance_labels_path, show_col_types = FALSE,
                                  col_types = readr::cols(
                                    `_id` = readr::col_character(),
                                    substance_label = readr::col_character()))
    d <- dplyr::left_join(d, sub_labels, by = "_id")
  }
  d <- add_pip_analysis_cache(d)
  saveRDS(d, CACHE_PATH)
  message("=== Cache PIP helper refresh complete ===")
}, error = function(e) {
  message("WARNING: cache PIP helper refresh failed — ", conditionMessage(e))
})

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
      output_file = "preprocessing.html",
      output_dir  = normalizePath("www", mustWork = TRUE),
      params      = list(
        cache_path = "trials_cache.rds",
        log_dir = "data"
      ),
      knit_root_dir = getwd(),
      quiet       = TRUE
    )
    message("=== Preprocessing report written to www/preprocessing.html ===")
  }, error = function(e) {
    message("WARNING: preprocessing report generation failed — ", conditionMessage(e))
    message("         Cache rebuild was successful; report will be stale until next run.")
  })
}
