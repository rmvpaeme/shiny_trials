# Build per-trial substance labels for the product_search dropdown.
#
# Pipeline:
#   1. Read data/trial_substances_raw.csv  (_id + raw_substance pairs)
#   2. Normalise unique raw_substance values via normalise_substances()
#   3. Filter to exploratory substances (is_exploratory_substance())
#   4. Aggregate per trial → substance_label (sorted, " / "-joined)
#   5. Write data/trial_substance_labels.csv  (_id + substance_label)
#   6. Write data/substance_normalisation_log.csv  (for preprocessing.Rmd)
#   7. Optionally write substance_review_queue.csv  (--write-queue)
#
# Usage:
#   Rscript helper_scripts/substance_norm_pipeline/build_substance_labels.R
#   Rscript helper_scripts/substance_norm_pipeline/build_substance_labels.R --write-queue
#
# Environment:
#   DATA_DIR    override for data directory (default: data/)
#   CONFIG_DIR  override for config dir (default: config/substance_norm_pipeline/)

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(tidyr)
  library(purrr)
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

args        <- commandArgs(trailingOnly = TRUE)
write_queue <- "--write-queue" %in% args

data_dir   <- Sys.getenv("DATA_DIR",   unset = project_path("data"))
config_dir <- Sys.getenv("CONFIG_DIR", unset = project_path("config", "substance_norm_pipeline"))

raw_path    <- file.path(data_dir, "trial_substances_raw.csv")
labels_path <- file.path(data_dir, "trial_substance_labels.csv")
log_path    <- file.path(data_dir, "substance_normalisation_log.csv")
queue_path  <- file.path(config_dir, "substance_review_queue.csv")

# ── load normaliser ────────────────────────────────────────────────────────────

source(project_path("helper_scripts", "substance_norm_pipeline", "normalise_substances.R"),
       local = FALSE)
cfg <- load_substance_configs(config_dir = config_dir)

is_exploratory_substance <- function(x) {
  key <- stringr::str_to_lower(dplyr::coalesce(as.character(x), ""))
  nchar(key) >= 3 &
    stringr::str_detect(key, "[[:alpha:]]") &
    !stringr::str_detect(key, stringr::regex(
      paste0(
        "^\\d+[,.]?\\d*\\s*%?\\s*(w|w/v|v/v)?$|^dose$|^the placebo|\\bplacebo\\b|",
        "not yet established|not available|not applicable|^na$|^n/a$|^none$|",
        "^ml\\b|^mg\\b|micrograms?|concentrate|solution|solución|solucion|",
        "injectable|inyectable|injection|infusion|injektionslösung|iniettabile|",
        "comprimidos|recubiertos|pel[ií]cula|capsules?|tablets?|poudre|polvere|",
        "polvo|solvant|solvente|sodium chloride|nacl|magnesium stearate|kwikpen"
      ),
      ignore_case = TRUE
    ))
}

# ── read raw substance pairs ───────────────────────────────────────────────────

if (!file.exists(raw_path)) {
  stop("Input not found: ", raw_path,
       "\nRun export_trial_substances.R first.")
}

raw <- readr::read_csv(raw_path, show_col_types = FALSE,
                        col_types = readr::cols(
                          `_id`          = readr::col_character(),
                          raw_substance  = readr::col_character()
                        ))

message(sprintf("Input: %d trial-substance pairs, %d unique substances, %d trials",
                nrow(raw),
                dplyr::n_distinct(raw$raw_substance),
                dplyr::n_distinct(raw$`_id`)))

# ── normalise unique substances ────────────────────────────────────────────────

unique_subs <- unique(raw$raw_substance)
unique_subs <- unique_subs[!is.na(unique_subs) & nzchar(trimws(unique_subs))]
message(sprintf("Normalising %d unique substance strings...", length(unique_subs)))

norm <- normalise_substances(unique_subs, configs = cfg)
norm <- norm %>%
  mutate(
    active_substance_clean = stringr::str_to_sentence(active_substance_clean),
    exploratory            = is_exploratory_substance(active_substance_clean)
  )

message(sprintf(
  "Results: accepted=%d  review=%d  rejected=%d  unknown=%d",
  sum(norm$match_status == "accepted", na.rm = TRUE),
  sum(norm$match_status == "review",   na.rm = TRUE),
  sum(norm$match_status == "rejected", na.rm = TRUE),
  sum(norm$match_status == "unknown",  na.rm = TRUE)
))

# ── build per-trial substance labels ──────────────────────────────────────────

# Join normalised result back to trial-substance pairs
trial_norm <- raw %>%
  left_join(norm %>% select(raw_substance, active_substance_clean,
                             match_status, match_score, match_source, match_reason,
                             exploratory),
            by = "raw_substance")

# Aggregate per trial: sorted unique exploratory accepted/review substances
labels <- trial_norm %>%
  filter(
    exploratory,
    match_status %in% c("accepted", "review"),
    !is.na(active_substance_clean),
    nchar(stringr::str_trim(active_substance_clean)) > 0
  ) %>%
  group_by(`_id`) %>%
  summarise(
    substance_label = paste(sort(unique(active_substance_clean)), collapse = " / "),
    .groups = "drop"
  )

readr::write_csv(labels, labels_path)
message(sprintf("Wrote %d trial substance labels to %s", nrow(labels), labels_path))

# ── write substance normalisation log for preprocessing.Rmd ──────────────────

log_rows <- trial_norm %>%
  filter(!is.na(active_substance_clean), exploratory) %>%
  select(`_id`, raw_substance, active_substance_clean, match_status,
         match_score, match_source, match_reason)

readr::write_csv(log_rows, log_path)
message(sprintf("Wrote substance normalisation log: %d rows to %s", nrow(log_rows), log_path))

# ── optional: write review queue ──────────────────────────────────────────────

if (write_queue) {
  existing_queue <- if (file.exists(queue_path)) {
    readr::read_csv(queue_path, show_col_types = FALSE)
  } else {
    tibble::tibble(
      raw_substance = character(), active_substance_clean = character(),
      match_status = character(), match_score = numeric(),
      match_source = character(), match_reason = character(),
      n_occurrences = integer(), decision = character(),
      canonical_substance = character(), comment = character()
    )
  }

  # Count occurrences per raw_substance
  occ <- raw %>% count(raw_substance, name = "n_occurrences")

  new_queue <- norm %>%
    filter(match_status %in% c("review", "unknown")) %>%
    left_join(occ, by = "raw_substance") %>%
    mutate(n_occurrences = coalesce(n_occurrences, 0L)) %>%
    select(raw_substance, active_substance_clean, match_status,
           match_score, match_source, match_reason, n_occurrences)

  # Preserve decisions from existing queue
  existing_decisions <- existing_queue %>%
    filter(!is.na(decision) & nzchar(decision)) %>%
    select(raw_substance, decision, canonical_substance, comment)

  queue_out <- new_queue %>%
    left_join(existing_decisions, by = "raw_substance") %>%
    arrange(desc(n_occurrences))

  readr::write_csv(queue_out, queue_path)
  message(sprintf("Wrote review queue: %d rows to %s", nrow(queue_out), queue_path))
}

message("Done.")
