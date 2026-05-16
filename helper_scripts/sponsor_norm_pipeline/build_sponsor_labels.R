# Build per-trial sponsor labels for the Shiny app.
#
# Pipeline:
#   1. Read data/trial_sponsors_raw.csv  (_id + raw_sponsor pairs)
#   2. Normalise unique raw_sponsor values via normalise_sponsors()
#   3. Aggregate per trial → sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, match_status
#   4. Write data/trial_sponsor_labels.csv  (_id + sponsor fields)
#   5. Write data/sponsor_normalisation_log.csv  (for preprocessing.Rmd)
#   6. Optionally write sponsor_review_queue.csv  (--write-queue)
#
# Usage:
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R --write-queue
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R --write-queue --allow-fuzzy
#
# Environment:
#   DATA_DIR    override for data directory (default: data/)
#   CONFIG_DIR  override for config dir (default: config/sponsor_norm_pipeline/)

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(purrr)
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

args        <- commandArgs(trailingOnly = TRUE)
write_queue <- "--write-queue" %in% args
allow_fuzzy <- "--allow-fuzzy" %in% args

data_dir   <- Sys.getenv("DATA_DIR",   unset = project_path("data"))
config_dir <- Sys.getenv("CONFIG_DIR", unset = project_path("config", "sponsor_norm_pipeline"))

raw_path    <- file.path(data_dir, "trial_sponsors_raw.csv")
labels_path <- file.path(data_dir, "trial_sponsor_labels.csv")
log_path    <- file.path(data_dir, "sponsor_normalisation_log.csv")
queue_path  <- file.path(config_dir, "sponsor_review_queue.csv")

# ── load normaliser ────────────────────────────────────────────────────────────

source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = FALSE
)
cfg <- load_sponsor_configs(config_dir = config_dir)

# ── read raw sponsor pairs ─────────────────────────────────────────────────────

if (!file.exists(raw_path)) {
  stop("Input not found: ", raw_path, "\nRun export_trial_sponsors.R first.")
}

raw <- readr::read_csv(raw_path, show_col_types = FALSE,
                       col_types = readr::cols(
                         `_id`         = readr::col_character(),
                         raw_sponsor   = readr::col_character(),
                         is_commercial = readr::col_logical()
                       ))

message(sprintf(
  "Input: %d trial-sponsor rows, %d unique sponsors",
  nrow(raw),
  dplyr::n_distinct(raw$raw_sponsor)
))

# ── normalise unique sponsors ──────────────────────────────────────────────────

unique_sponsors <- unique(raw$raw_sponsor)
unique_sponsors <- unique_sponsors[!is.na(unique_sponsors) & nzchar(trimws(unique_sponsors))]
message(sprintf("Normalising %d unique sponsor strings...", length(unique_sponsors)))

norm <- normalise_sponsors(unique_sponsors, configs = cfg, allow_fuzzy = allow_fuzzy)

message(sprintf(
  "Results: accepted=%d  review=%d  rejected=%d  unknown=%d",
  sum(norm$match_status == "accepted", na.rm = TRUE),
  sum(norm$match_status == "review",   na.rm = TRUE),
  sum(norm$match_status == "rejected", na.rm = TRUE),
  sum(norm$match_status == "unknown",  na.rm = TRUE)
))

# ── build per-trial sponsor labels ─────────────────────────────────────────────

trial_norm <- raw %>%
  dplyr::left_join(
    norm %>% dplyr::select(
      raw_sponsor, sponsor_clean, sponsor_parent, sponsor_group,
      sponsor_type, match_status, match_score, match_source, match_reason,
      suggested_clean
    ),
    by = "raw_sponsor"
  ) %>%
  # Derive sponsor_type from the trial's own commercial flag (authoritative)
  # rather than the alias table's heuristic.
  #   is_commercial == TRUE  → "industry"
  #   is_commercial == FALSE → classify_sponsor_type() on the raw name
  #   is_commercial == NA    → keep alias-table value (fallback)
  dplyr::mutate(
    sponsor_type = dplyr::case_when(
      !is.na(is_commercial) & is_commercial  ~ "industry",
      !is.na(is_commercial) & !is_commercial ~ classify_sponsor_type(raw_sponsor),
      TRUE                                   ~ sponsor_type
    )
  )

# One sponsor per trial: keep accepted and review, drop rejected/unknown from labels
labels <- trial_norm %>%
  dplyr::filter(match_status %in% c("accepted", "review")) %>%
  dplyr::select(
    `_id`, sponsor_clean, sponsor_parent, sponsor_group,
    sponsor_type, match_status
  )

readr::write_csv(labels, labels_path)
message(sprintf("Wrote %d trial sponsor labels to %s", nrow(labels), labels_path))

# ── write sponsor normalisation log for preprocessing.Rmd ─────────────────────

log_rows <- norm %>%
  dplyr::left_join(
    raw %>% dplyr::count(raw_sponsor, name = "n_trials"),
    by = "raw_sponsor"
  ) %>%
  dplyr::arrange(dplyr::desc(n_trials))

readr::write_csv(log_rows, log_path)
message(sprintf("Wrote sponsor normalisation log: %d rows to %s", nrow(log_rows), log_path))

# ── optional: write review queue ──────────────────────────────────────────────

if (write_queue) {
  existing_queue <- if (file.exists(queue_path)) {
    readr::read_csv(queue_path, show_col_types = FALSE)
  } else {
    tibble::tibble(
      raw_sponsor = character(), candidate_sponsor = character(),
      sponsor_type = character(), match_status = character(),
      match_score = numeric(), match_source = character(),
      match_reason = character(), n_trials = integer(),
      decision = character(), canonical_sponsor = character(),
      comment = character()
    )
  }

  occ <- raw %>% dplyr::count(raw_sponsor, name = "n_trials")

  new_queue <- norm %>%
    dplyr::filter(match_status %in% c("review", "unknown")) %>%
    dplyr::left_join(occ, by = "raw_sponsor") %>%
    dplyr::mutate(
      n_trials          = dplyr::coalesce(n_trials, 0L),
      candidate_sponsor = dplyr::coalesce(sponsor_clean, suggested_clean)
    ) %>%
    dplyr::select(
      raw_sponsor, candidate_sponsor, sponsor_type, match_status,
      match_score, match_source, match_reason, n_trials
    )

  # Preserve decisions from existing queue
  existing_decisions <- existing_queue %>%
    dplyr::filter(!is.na(decision) & nzchar(decision)) %>%
    dplyr::select(raw_sponsor, decision, canonical_sponsor, comment)

  queue_out <- new_queue %>%
    dplyr::left_join(existing_decisions, by = "raw_sponsor") %>%
    dplyr::arrange(dplyr::desc(n_trials))

  readr::write_csv(queue_out, queue_path)
  message(sprintf(
    "Wrote review queue: %d rows to %s", nrow(queue_out), queue_path
  ))
}

message("Done.")
