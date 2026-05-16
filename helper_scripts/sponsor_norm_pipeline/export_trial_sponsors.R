# Export per-trial raw sponsor strings for the normalisation pipeline.
#
# Reads trials_cache.rds and writes data/trial_sponsors_raw.csv with columns:
#   _id         — trial identifier
#   raw_sponsor — raw sponsor name string
#   is_commercial — trial-level commercial sponsor flag, when available
#
# One row per trial (trials have one primary sponsor).
# This is the input to build_sponsor_labels.R.
#
# Usage:
#   Rscript helper_scripts/sponsor_norm_pipeline/export_trial_sponsors.R
#
# Environment:
#   CACHE_PATH  override for cache file (default: trials_cache.rds)
#   DATA_DIR    override for output directory (default: data/)

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
})

script_path <- local({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  ofiles <- vapply(sys.frames(), function(frame) {
    if (!is.null(frame$ofile)) frame$ofile else NA_character_
  }, character(1))
  ofiles <- ofiles[!is.na(ofiles)]
  if (length(ofiles)) normalizePath(ofiles[[length(ofiles)]], mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)

cache_path <- Sys.getenv("CACHE_PATH", unset = project_path("trials_cache.rds"))
data_dir   <- Sys.getenv("DATA_DIR",   unset = project_path("data"))
out_path   <- file.path(data_dir, "trial_sponsors_raw.csv")

if (!file.exists(cache_path)) stop("Cache not found: ", cache_path)
if (!dir.exists(data_dir)) dir.create(data_dir, recursive = TRUE)

message("Reading cache: ", cache_path)
cache <- readRDS(cache_path)

extract_sponsor <- function(df) {
  df %>%
    dplyr::mutate(
      raw_sponsor = dplyr::coalesce(
        # EUCTR primary sponsor name
        if ("b1_sponsor.b11_name_of_sponsor" %in% names(df)) {
          .data[["b1_sponsor.b11_name_of_sponsor"]]
        } else NA_character_,
        # CTIS primary sponsor name
        if ("authorizedApplication.authorizedPartI.sponsors.organisation.name" %in% names(df)) {
          .data[["authorizedApplication.authorizedPartI.sponsors.organisation.name"]]
        } else NA_character_,
        # Prepared app cache fallback. Some flattened/cache rows already have a
        # sponsor_name even when the original source-specific field is absent.
        if ("sponsor_name" %in% names(df)) {
          .data[["sponsor_name"]]
        } else NA_character_
      ),
      is_commercial = dplyr::coalesce(
        # CTIS: direct boolean flag
        if ("authorizedApplication.authorizedPartI.sponsors.isCommercial" %in% names(df)) {
          as.logical(.data[["authorizedApplication.authorizedPartI.sponsors.isCommercial"]])
        } else NA,
        if ("authorizedApplication.authorizedPartI.sponsors.commercial" %in% names(df)) {
          as.logical(.data[["authorizedApplication.authorizedPartI.sponsors.commercial"]])
        } else NA,
        # EUCTR: "Commercial organisation" → TRUE, "Non-Commercial organisation" → FALSE
        if ("b1_sponsor.b31_and_b32_status_of_the_sponsor" %in% names(df)) {
          dplyr::case_when(
            grepl("^Non-Commercial", .data[["b1_sponsor.b31_and_b32_status_of_the_sponsor"]],
                  ignore.case = TRUE) ~ FALSE,
            grepl("Commercial", .data[["b1_sponsor.b31_and_b32_status_of_the_sponsor"]],
                  ignore.case = TRUE) ~ TRUE,
            TRUE ~ NA
          )
        } else NA
      )
    ) %>%
    dplyr::select(`_id`, raw_sponsor, is_commercial) %>%
    dplyr::filter(
      !is.na(raw_sponsor),
      nchar(stringr::str_trim(raw_sponsor)) > 0
    )
}

out <- extract_sponsor(cache) %>%
  dplyr::distinct(`_id`, .keep_all = TRUE)

readr::write_csv(out, out_path)
message(sprintf(
  "Wrote %d trial sponsor rows (%d unique sponsors, %d with commercial flag) to %s",
  nrow(out),
  dplyr::n_distinct(out$raw_sponsor),
  sum(!is.na(out$is_commercial)),
  out_path
))
