# Export per-trial raw substance strings for the normalisation pipeline.
#
# Reads trials_cache.rds and writes data/trial_substances_raw.csv with columns:
#   _id           — trial identifier
#   raw_substance — individual substance string (split on " / ")
#
# One row per trial-substance pair (after splitting multi-substance strings).
# This is the input to build_substance_labels.R.
#
# Usage:
#   Rscript helper_scripts/substance_norm_pipeline/export_trial_substances.R
#
# Environment:
#   CACHE_PATH  override for cache file (default: trials_cache.rds)
#   DATA_DIR    override for output directory (default: data/)

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(tidyr)
})

script_path <- local({
  cmd_args <- commandArgs(FALSE)
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
out_path   <- file.path(data_dir, "trial_substances_raw.csv")

if (!file.exists(cache_path)) stop("Cache not found: ", cache_path)
if (!dir.exists(data_dir)) dir.create(data_dir, recursive = TRUE)

message("Reading cache: ", cache_path)
cache <- readRDS(cache_path)

out <- cache %>%
  transmute(
    `_id`,
    raw_substance = dplyr::if_else(
      !is.na(DIMP_inn_name) & nchar(stringr::str_trim(DIMP_inn_name)) > 0,
      DIMP_inn_name,
      DIMP_product_name
    )
  ) %>%
  filter(!is.na(raw_substance), nchar(stringr::str_trim(raw_substance)) > 0) %>%
  tidyr::separate_rows(raw_substance, sep = " / ") %>%
  filter(nchar(stringr::str_trim(raw_substance)) > 0) %>%
  distinct(`_id`, raw_substance)

readr::write_csv(out, out_path)
message(sprintf(
  "Wrote %d trial-substance pairs (%d unique substances, %d trials) to %s",
  nrow(out),
  dplyr::n_distinct(out$raw_substance),
  dplyr::n_distinct(out$`_id`),
  out_path
))
