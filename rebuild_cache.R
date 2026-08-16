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

# run_pipeline() swallows failures into warnings, which is right for the
# substance pipeline but useless when the caller has to branch. run_step()
# returns the status.
run_step <- function(script, args = character(), label = basename(script)) {
  if (!file.exists(script)) {
    message("SKIP  ", label, " — not found at ", script)
    return(127L)
  }
  status <- system2(rscript_bin(), c(script, args))
  if (!identical(status, 0L)) message(sprintf("      %s exited %s", label, status))
  invisible(status)
}

# ── Sponsor normalisation pipeline (v2) ───────────────────────────────────────
# Runs after the cache is on disk so 1_export_trial_sponsors.R can read it.
#
# E_emit.R replaced 3_build_sponsor_labels.R. Both write
# data/trial_sponsor_labels.csv, so leaving the old script here meant the next
# production rebuild would silently overwrite the v2 labels with old-pipeline
# output and undo the rewrite — with no error, because both "succeed".
#
# Only the deterministic tail runs here. A_block/B_mint/C_assign/D_consolidate
# cost money and need an API key, so they stay manual; E_emit just re-derives
# labels from the registry and assignments already on disk. New raw strings that
# appear since the last mint therefore arrive unassigned and are labelled from
# the raw name, which the diff reports rather than hides.
message("=== Building sponsor labels ===")
sp <- function(f) file.path("helper_scripts", "sponsor_norm_pipeline", f)

# Four steps, each branching on the previous one. The governing rule: a sponsor
# hiccup must never cost the data refresh, but it must never look like success
# either — so this block always leaves rebuild_cache.R exiting 0 and reports
# failure through a sentinel file the deploy script tests for.
st_export <- run_step(sp("1_export_trial_sponsors.R"), label = "1_export")

if (!identical(st_export, 0L)) {
  message("*** SPONSOR NIGHTLY FAILED — 1_export did not produce the raw corpus ***")
} else {
  # Resolves strings the registry has never seen. Exits 0 and makes no API call
  # on a normal night; see its header for the exit codes.
  st_new <- run_step(sp("N_nightly_resolve.R"), label = "N_nightly_resolve")
  if (!identical(st_new, 0L)) {
    message(sprintf(
      "*** SPONSOR NIGHTLY FAILED (exit %s) — see N_nightly_runs.csv ***", st_new))
  }

  # Gate BEFORE writing. A regression here means last night's labels are better
  # than tonight's, so keep them: unresolved strings degrade to their raw name,
  # which is visible, rather than to a wrong canonical, which is not.
  st_gate <- run_step(sp("E_emit.R"), c("--diff-only", "--assert-no-regressions"),
                      label = "E_emit gate")
  if (identical(st_gate, 0L)) {
    run_step(sp("E_emit.R"), label = "E_emit")
  } else {
    message("*** SPONSOR LABELS NOT WRITTEN — regression gate failed; ",
            "keeping the previous data/trial_sponsor_labels.csv ***")
  }
}
message("=== Sponsor labels build complete ===")

# ── Substance normalisation pipeline ─────────────────────────────────────────
# Runs after the cache is on disk so 1_export_trial_substances.R can read it.
message("=== Building substance labels ===")
run_pipeline(
  file.path("helper_scripts", "substance_norm_pipeline", "1_export_trial_substances.R"),
  file.path("helper_scripts", "substance_norm_pipeline", "3_build_substance_labels.R"),
  "Substance normalisation",
  "--write-queue"
)
message("=== Substance labels build complete ===")

message("=== Refreshing cache with latest substance/sponsor labels and PIP helpers ===")
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
  sponsor_labels_path <- file.path(dirname(DB_PATH), "trial_sponsor_labels.csv")
  if (file.exists(sponsor_labels_path)) {
    d <- dplyr::select(d, -dplyr::any_of(c("sponsor_clean", "sponsor_label")))
    slabels <- readr::read_csv(sponsor_labels_path, show_col_types = FALSE,
                               col_types = readr::cols(
                                 `_id`         = readr::col_character(),
                                 sponsor_clean = readr::col_character()))
    slabels <- dplyr::select(slabels, `_id`, sponsor_clean)
    d <- dplyr::left_join(d, slabels, by = "_id")
    d$sponsor_label <- dplyr::coalesce(d$sponsor_clean, d$sponsor_name)
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
