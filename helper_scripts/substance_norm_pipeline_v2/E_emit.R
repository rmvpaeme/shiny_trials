#!/usr/bin/env Rscript
# Pass E — write the labels the app reads, and the queue the reviewer reads.
#
# This is the only script that touches data/trial_substance_labels.csv, and it
# writes the shape app.R already expects — `_id` plus substance_label, one row
# per trial, multi-substance joined with " / " (app.R:1811-1839 and
# app.R:2069-2082) — so the app needs no change.
#
# It also runs the regression diff, which is the decisive gate for the rewrite:
# every trial is compared against the labels the v1 pipeline produced, and each
# change is classified. `accepted -> unknown` must be zero.
#
# ONE DELIBERATE DIFFERENCE FROM v1, and it will show in the diff.
# v1 fell back to the RAW strings for any trial with no accepted substance
# (3_build_substance_labels.R:169-181), so the app's substance filter contains
# uncleaned text today. v2 drops that fallback: a trial whose only substance
# strings were dosage language or placeholders now has no label rather than a
# junk one. Those appear as `accepted -> unknown` and are counted SEPARATELY
# from real regressions, because they are the intended change — but they are
# listed, not just totalled, so the claim can be checked.
#
# Usage
#   Rscript .../E_emit.R                 # write labels + queue + diff
#   Rscript .../E_emit.R --diff-only     # report the diff, write nothing
#   Rscript .../E_emit.R --baseline=path # compare against a specific old file
#   Rscript .../E_emit.R --freeze-baseline

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringr)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "registry.R"))
source(pp("helper_scripts", "substance_norm_pipeline_v2", "substance_common.R"))

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
diff_only       <- "--diff-only"            %in% args
assert_clean    <- "--assert-no-regressions" %in% args
freeze_baseline <- "--freeze-baseline"      %in% args

V2       <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
DATA_DIR <- Sys.getenv("DATA_DIR",         unset = pp("data"))

REG_PATH   <- file.path(V2, "registry.csv")
ASG_PATH   <- file.path(V2, "assignments.csv")
QUEUE      <- file.path(V2, "E_review_queue.csv")
NOTSUB_B   <- file.path(V2, "B_not_substance.csv")
NOTSUB_C   <- file.path(V2, "C_not_substance.csv")
RAW_PATH   <- file.path(DATA_DIR, "trial_substances_raw.csv")
REJECT_PATH<- file.path(DATA_DIR, "substance_rejected.csv")
OUT_PATH   <- file.path(DATA_DIR, "trial_substance_labels.csv")
LOG_PATH   <- file.path(DATA_DIR, "substance_normalisation_log_v2.csv")
# A FROZEN SNAPSHOT, never the file this script writes. Defaulting it to OUT_PATH
# is self-erasing: the first real run overwrites v1's labels and every later
# --diff-only compares v2 against v2 while still printing a healthy table. That
# happened on the sponsor side and is the worst way for a gate to fail.
BASE_PATH  <- file.path(DATA_DIR, "trial_substance_labels_baseline.csv")
BASELINE   <- arg_value("--baseline", BASE_PATH)

if (!file.exists(REG_PATH)) stop("No registry — run A_resolve.R first.", call. = FALSE)

reg <- registry_read(REG_PATH)
asg <- assignments_read(ASG_PATH, raw_col = "raw_substance")
raw <- read_csv(RAW_PATH, show_col_types = FALSE, progress = FALSE,
                col_types = cols(`_id` = col_character(), raw_substance = col_character()))

if (freeze_baseline) {
  if (!file.exists(OUT_PATH)) {
    stop("--freeze-baseline: nothing at ", OUT_PATH, " to freeze.", call. = FALSE)
  }
  if (file.exists(BASE_PATH)) {
    stop("--freeze-baseline: ", basename(BASE_PATH), " already exists.\n",
         "  Refusing to overwrite it — a baseline is only meaningful if you know\n",
         "  what produced it, and replacing it with v2 output would make the gate\n",
         "  compare v2 against v2 forever. Delete it by hand if that is really",
         " what you want.", call. = FALSE)
  }
  file.copy(OUT_PATH, BASE_PATH)
  message("froze regression baseline -> ", basename(BASE_PATH))
  message("  from ", OUT_PATH, " — make sure that is the OLD pipeline's output.")
}

baseline <- if (file.exists(BASELINE)) {
  read_csv(BASELINE, show_col_types = FALSE, progress = FALSE)
} else NULL
if (is.null(baseline)) {
  message("No baseline at ", BASELINE, ".")
  message("  Regenerate v1's labels and freeze them:")
  message("    Rscript helper_scripts/substance_norm_pipeline/3_build_substance_labels.R")
  message("    Rscript .../E_emit.R --freeze-baseline")
}

# ── Resolve ───────────────────────────────────────────────────────────────────

labelled <- registry_resolve_labels(
  reg, asg,
  cols = c(substance_clean = "canonical",
           substance_salt  = "salt_form",
           substance_type  = "entity_type")
)

# Every string a pass has positively judged NOT to be a substance. These are
# excluded from labels rather than left unlabelled-by-accident, so the log can
# distinguish "we decided this is not a drug" from "nothing reached it".
read_ns <- function(p) {
  if (!file.exists(p)) return(character())
  x <- read_csv(p, show_col_types = FALSE, progress = FALSE)
  if ("raw_substance" %in% names(x)) x$raw_substance else character()
}
not_substance <- unique(c(read_ns(NOTSUB_B), read_ns(NOTSUB_C), read_ns(REJECT_PATH)))
message(sprintf("strings judged not-a-substance: %d", length(not_substance)))

per_pair <- raw |>
  filter(!is.na(raw_substance), nzchar(trimws(raw_substance))) |>
  left_join(labelled |> select(raw_substance, entity_id, substance_clean,
                               substance_salt, substance_type, confidence, decided_by),
            by = "raw_substance") |>
  mutate(
    # "human_unassigned" is a reviewer saying the proposal was wrong without
    # supplying a better one. It joins "rejected" as a SECOND intended way for a
    # pair to end up with no label — see the regression diff, which already has
    # to distinguish an intended drop from a fault and now has two of them.
    match_status = case_when(
      !is.na(substance_clean)            ~ "accepted",
      raw_substance %in% not_substance   ~ "rejected",
      decided_by %in% "human"            ~ "human_unassigned",
      TRUE                               ~ "unknown"
    ),
    # Display casing matches v1 exactly, so the diff measures resolution changes
    # rather than capitalisation ones.
    substance_clean = if_else(match_status == "accepted",
                              display_substance(substance_clean), NA_character_)
  )

cat(sprintf("\ntrial-substance pairs : %d\n", nrow(per_pair)))
cat(sprintf("  accepted            : %d\n", sum(per_pair$match_status == "accepted")))
cat(sprintf("  rejected (not a drug): %d\n", sum(per_pair$match_status == "rejected")))
cat(sprintf("  human unassign      : %d\n", sum(per_pair$match_status == "human_unassigned")))
cat(sprintf("  unknown             : %d\n", sum(per_pair$match_status == "unknown")))
cat(sprintf("distinct substances   : %d\n",
            dplyr::n_distinct(per_pair$substance_clean[per_pair$match_status == "accepted"])))

# ── Per-trial labels ──────────────────────────────────────────────────────────
# Sorted, unique, " / "-joined — the shape app.R's extract_choices() splits on.

per_trial <- per_pair |>
  filter(match_status == "accepted", !is.na(substance_clean),
         nzchar(str_trim(substance_clean))) |>
  group_by(`_id`) |>
  summarise(substance_label = paste(sort(unique(substance_clean)), collapse = " / "),
            .groups = "drop")

cat(sprintf("trials with a label   : %d of %d\n",
            nrow(per_trial), dplyr::n_distinct(raw$`_id`)))

# ── Regression diff ───────────────────────────────────────────────────────────

if (!is.null(baseline) && all(c("_id", "substance_label") %in% names(baseline))) {
  old <- baseline |>
    select(`_id`, old_label = substance_label) |>
    distinct(`_id`, .keep_all = TRUE)

  # A TRIAL THAT IS NO LONGER IN THE CORPUS CANNOT HAVE REGRESSED.
  #
  # A EudraCT trial has one record per country and which one is retained depends
  # on the database state, so a baseline frozen from an earlier snapshot names
  # trials this corpus does not contain — "2004-000015-25-LT" where the current
  # export has "-GB". Counting those as regressions reported 6,112 failures of
  # which 5,438 were the same trial under another country code, and it would
  # recur on the server every night, since the nightly re-exports the corpus.
  #
  # Dropping them is not weakening the gate: the gate asks "did a trial we can
  # still see lose its label", and a trial that is gone is not evidence either
  # way. Everything still present is compared exactly as before.
  n_before <- nrow(old)
  old <- old |> filter(`_id` %in% raw$`_id`)
  if (nrow(old) < n_before) {
    message(sprintf("baseline: %d of %d trials are not in the current corpus and are not compared",
                    n_before - nrow(old), n_before))
  }

  # Trials whose v1 label came ONLY from the raw fallback: v1 labelled them, v2
  # deliberately does not. Identified rather than assumed — a trial qualifies
  # when none of its raw strings resolved AND every one of them is a string some
  # pass positively judged not to be a substance.
  #
  # A reviewer unassigning a string is the SECOND intended way to lose a label,
  # and it is classified the same way: by what every one of the trial's raw
  # strings ended up as, not by assumption. A trial qualifies when none of them
  # resolved, all of them are intended drops, and at least one is a human's.
  # Mixed cases (one string human-unassigned, another genuinely unresolved) fall
  # through to REGRESSION on purpose — a real fault is still present.
  drop_class <- per_pair |>
    group_by(`_id`) |>
    summarise(none_accepted = !any(match_status == "accepted"),
              all_rejected  = all(match_status == "rejected"),
              all_intended  = all(match_status %in% c("rejected", "human_unassigned")),
              any_human     = any(match_status == "human_unassigned"),
              .groups = "drop")
  fallback_ids <- drop_class |> filter(none_accepted, all_rejected) |> pull(`_id`)
  human_ids    <- drop_class |> filter(none_accepted, all_intended, any_human) |> pull(`_id`)

  d <- old |>
    left_join(per_trial, by = "_id") |>
    mutate(
      new_label = substance_label,
      change = case_when(
        !is.na(new_label) & !is.na(old_label) & old_label == new_label ~ "unchanged",
        is.na(old_label) & !is.na(new_label)          ~ "unknown -> accepted",
        is.na(new_label) & `_id` %in% fallback_ids    ~ "dropped: v1 raw fallback (intended)",
        is.na(new_label) & `_id` %in% human_ids       ~ "human unassign (intended)",
        is.na(new_label)                              ~ "REGRESSION: -> unknown",
        TRUE                                          ~ "label changed"
      ))

  cat("\n=== regression diff vs baseline ===\n")
  print(as.data.frame(d |> count(change, sort = TRUE)))

  reg_rows <- d |> filter(change == "REGRESSION: -> unknown")
  if (nrow(reg_rows)) {
    cat(sprintf("\n%d REGRESSIONS — these must be zero before switching the app over:\n",
                nrow(reg_rows)))
    ex <- reg_rows |>
      left_join(raw |> distinct(`_id`, .keep_all = TRUE), by = "_id") |>
      select(`_id`, old_label, raw_substance)
    print(as.data.frame(head(ex, 20)))
  }

  fb <- d |> filter(change == "dropped: v1 raw fallback (intended)")
  if (nrow(fb)) {
    cat(sprintf("\n%d trial(s) lost a v1 raw-fallback label. READ A SAMPLE — if a real\n",
                nrow(fb)))
    cat("substance name appears here, the not-a-substance judgement was wrong:\n")
    print(as.data.frame(fb |> select(`_id`, old_label) |> head(15)))
  }

  # Same reasoning as the block above, for the human class. Not asserted on, so
  # this print is the only place a mistaken reject becomes visible.
  hu <- d |> filter(change == "human unassign (intended)")
  if (nrow(hu)) {
    cat(sprintf("\n%d trial(s) lost a label because a reviewer unassigned a string.\n",
                nrow(hu)))
    cat("READ THIS — a mistaken reject is visible here and in no other output:\n")
    print(as.data.frame(hu |> select(`_id`, old_label) |> head(15)))
  }

  if (assert_clean && nrow(reg_rows)) {
    message(sprintf("--assert-no-regressions: %d accepted -> unknown regression(s).",
                    nrow(reg_rows)))
    quit(save = "no", status = 1L)
  }

  changed <- d |> filter(change == "label changed") |>
    count(old_label, new_label, name = "trials") |>
    arrange(desc(trials))
  if (nrow(changed)) {
    cat("\ntop label changes by trial count — this is what a user of the app sees:\n")
    print(as.data.frame(head(changed, 25)))
  }
} else {
  cat("\nNo comparable baseline found; skipping the regression diff.\n")
  # Exit 2 = COULD NOT MEASURE, distinct from exit 1 = measured a regression.
  # A gate that cannot run must say so, or it manufactures confidence.
  if (assert_clean) {
    cat("--assert-no-regressions: cannot assert without a baseline.\n")
    quit(save = "no", status = 2L)
  }
}

if (diff_only) { cat("\n--diff-only: nothing written.\n"); quit(save = "no", status = 0L) }

# ── Write ─────────────────────────────────────────────────────────────────────

write_csv(per_trial, OUT_PATH, na = "", eol = "\n")
cat(sprintf("\nwrote %s (%d trials)\n", basename(OUT_PATH), nrow(per_trial)))

log <- per_pair |>
  group_by(raw_substance) |>
  summarise(
    substance_clean = dplyr::first(substance_clean),
    substance_salt  = dplyr::first(substance_salt),
    substance_type  = dplyr::first(substance_type),
    match_status    = dplyr::first(match_status),
    confidence      = dplyr::first(confidence),
    decided_by      = dplyr::first(decided_by),
    n_trials        = dplyr::n(),
    .groups = "drop"
  ) |>
  arrange(desc(n_trials))
write_csv(log, LOG_PATH, na = "", eol = "\n")
cat(sprintf("wrote %s (%d distinct strings)\n", basename(LOG_PATH), nrow(log)))

# ── Reviewer queue ────────────────────────────────────────────────────────────

impact <- log |> select(raw_substance, n_trials)
queue <- route_for_review(asg, impact, raw_col = "raw_substance") |>
  left_join(reg |> select(entity_id, canonical), by = "entity_id") |>
  transmute(raw_substance, proposed = canonical, confidence, n_trials,
            review_reason, reason, channel, model_id)
write_csv(queue, QUEUE, na = "", eol = "\n")
cat(sprintf("wrote %s (%d rows for review)\n", basename(QUEUE), nrow(queue)))
cat(sprintf("  that is %.1f%% of assignments, carrying %d trial pairs\n",
            100 * nrow(queue) / max(nrow(asg), 1L), sum(queue$n_trials, na.rm = TRUE)))
cat("\nReview in the curation app; accepted decisions pin against later re-runs.\n")
