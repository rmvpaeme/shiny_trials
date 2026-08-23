#!/usr/bin/env Rscript
# Pass E — write the labels the app reads, and the queue the reviewer reads.
#
# This is the only script that touches data/trial_sponsor_labels.csv, and it
# writes the same columns app.R already expects (app.R:1919-1934 and
# app.R:1985-2000 select `_id` and sponsor_clean), so the app needs no change.
#
# It also runs the regression diff, which is the decisive gate for the whole
# rewrite: every trial row is compared against the labels the old pipeline
# produced, and each change is classified. `accepted -> unknown` must be zero.
#
# Usage
#   Rscript .../E_emit.R                 # write labels + queue + diff
#   Rscript .../E_emit.R --diff-only     # report the diff, write nothing
#   Rscript .../E_emit.R --baseline=path # compare against a specific old file

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "registry.R"))

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
diff_only <- "--diff-only" %in% args
# --assert-no-regressions turns the gate into an exit code so a caller can branch
# on it. Parsing stdout for "REGRESSION" would be the alternative and is exactly
# the kind of check that rots silently when the wording changes.
assert_clean <- "--assert-no-regressions" %in% args
freeze_baseline <- "--freeze-baseline" %in% args

V2        <- Sys.getenv("SPONSOR_V2_DIR", unset = pp("config", "sponsor_norm_v2"))
# DATA_DIR is honoured for the same reason SPONSOR_V2_DIR is: without it every
# path below is hardcoded to the real data/, so a scratch-directory test of this
# script overwrites the production labels it is supposed to be leaving alone.
# The substance twin has always had this (substance_norm_pipeline_v2/E_emit.R);
# this file did not, which made the regression gate untestable.
DATA_DIR  <- Sys.getenv("DATA_DIR", unset = pp("data"))
REG_PATH  <- file.path(V2, "registry.csv")
ASG_PATH  <- file.path(V2, "assignments.csv")
QUEUE     <- file.path(V2, "E_review_queue.csv")
RAW_PATH  <- file.path(DATA_DIR, "trial_sponsors_raw.csv")
OUT_PATH  <- file.path(DATA_DIR, "trial_sponsor_labels.csv")
LOG_PATH  <- file.path(DATA_DIR, "sponsor_normalisation_log_v2.csv")
# The regression baseline is a FROZEN SNAPSHOT, not the live output file.
#
# It used to default to OUT_PATH — the file this script writes. That is
# self-erasing: the first full run overwrites the old pipeline's labels, and
# every later --diff-only silently compares the new labels against the previous
# NEW labels. It still prints a healthy-looking table (50,208 unchanged, 0
# regressions) while no longer measuring anything, which is the worst way for a
# gate to fail. Observed 2026-08-15, after E_emit had been run for real.
BASE_PATH <- file.path(DATA_DIR, "trial_sponsor_labels_baseline.csv")
BASELINE  <- arg_value("--baseline", BASE_PATH)

if (!file.exists(REG_PATH)) stop("No registry — run B_mint.R and C_assign.R first.", call. = FALSE)

reg <- registry_read(REG_PATH)
asg <- assignments_read(ASG_PATH)
raw <- read_csv(RAW_PATH, show_col_types = FALSE, progress = FALSE)

# Freezing is EXPLICIT. It used to happen automatically from whatever labels
# existed, which is a footgun with a long fuse.
#
# Observed on the server 2026-08-16: the deploy branch resets to origin/main
# every night, and trial_sponsor_labels.csv is tracked on `deploy` but gitignored
# on `main`, so the reset DELETED it. The auto-freeze then had nothing to copy,
# the diff was skipped, and --assert-no-regressions passed vacuously. Worse, on
# the following run the file would exist again — as v2 output — so the freeze
# would have captured v2 as its own baseline and the gate would have compared v2
# to v2 forever while reporting a healthy table.
#
# A baseline is only meaningful if you know what produced it, so it is now
# created deliberately with --freeze-baseline, never inferred.
if (freeze_baseline) {
  if (!file.exists(OUT_PATH)) {
    stop("--freeze-baseline: nothing at ", OUT_PATH, " to freeze.", call. = FALSE)
  }
  file.copy(OUT_PATH, BASE_PATH, overwrite = TRUE)
  message("froze regression baseline -> ", basename(BASE_PATH))
  message("  from ", OUT_PATH)
  message("  Make sure that file is the OLD pipeline's output, not v2's.")
}

baseline <- if (file.exists(BASELINE)) {
  read_csv(BASELINE, show_col_types = FALSE, progress = FALSE)
} else NULL
if (is.null(baseline)) {
  message("No baseline at ", BASELINE, ".")
  message("  Regenerate the old pipeline's labels and freeze them:")
  message("    cp data/trial_sponsor_labels.csv /tmp/v2_labels.csv")
  message("    Rscript LEGACY/sponsor_norm_pipeline/3_build_sponsor_labels.R")
  message("    mv data/trial_sponsor_labels.csv ", basename(BASE_PATH))
  message("    cp /tmp/v2_labels.csv data/trial_sponsor_labels.csv")
}

# ── Resolve ───────────────────────────────────────────────────────────────────

labelled <- registry_resolve_labels(reg, asg)

per_trial <- raw |>
  select(`_id`, raw_sponsor, is_commercial) |>
  left_join(labelled |> select(raw_sponsor, entity_id, sponsor_clean, sponsor_parent,
                               sponsor_type, confidence, decided_by),
            by = "raw_sponsor") |>
  mutate(
    # THREE outcomes, not two. "unknown" means nothing resolved the string;
    # "human_unassigned" means a reviewer looked at it and said the proposal was
    # wrong without supplying a better one. Both end up with no label, but only
    # the first is a fault — see the regression diff below, which is where the
    # distinction actually does work. The two branches this replaces both
    # produced "accepted" and so tested nothing.
    match_status = case_when(
      !is.na(sponsor_clean)   ~ "accepted",
      decided_by %in% "human" ~ "human_unassigned",
      TRUE                    ~ "unknown"
    ),
    # An unresolved string still has to show something in the app, so it falls
    # back to itself rather than a blank cell.
    sponsor_clean = coalesce(sponsor_clean, raw_sponsor),
    # The trial's own commercial flag is authoritative over anything the model
    # inferred from the string — it comes from the registry submission.
    sponsor_type = case_when(
      is_commercial %in% TRUE  ~ "industry",
      is_commercial %in% FALSE & sponsor_type %in% "industry" ~ "academic",
      TRUE ~ sponsor_type
    )
  )

cat(sprintf("\ntrial rows      : %d\n", nrow(per_trial)))
cat(sprintf("  accepted      : %d\n", sum(per_trial$match_status == "accepted")))
cat(sprintf("  human unassign: %d\n", sum(per_trial$match_status == "human_unassigned")))
cat(sprintf("  unknown       : %d\n", sum(per_trial$match_status == "unknown")))
cat(sprintf("distinct labels : %d\n", dplyr::n_distinct(per_trial$sponsor_clean)))

# ── Regression diff ───────────────────────────────────────────────────────────
# Specified at helper_scripts/sponsor_norm_pipeline/README.md:160-168.
# unknown -> accepted is the win. accepted -> unknown must be zero.

if (!is.null(baseline) && all(c("_id", "sponsor_clean") %in% names(baseline))) {
  old <- baseline |>
    select(`_id`, old_clean = sponsor_clean,
           old_status = any_of("match_status")) |>
    distinct(`_id`, .keep_all = TRUE)
  if (!"old_status" %in% names(old)) old$old_status <- NA_character_

  d <- per_trial |>
    distinct(`_id`, .keep_all = TRUE) |>
    inner_join(old, by = "_id") |>
    # ORDER MATTERS: human_unassigned must be tested BEFORE the unknown branch.
    # A reviewer rejecting a proposal sets entity_id = NA, which lands here with
    # no label — indistinguishable from a pipeline failure unless the reviewer's
    # own decision is what separates them. Classified as a regression it exits 1
    # under --assert-no-regressions, and rebuild_cache.R then keeps yesterday's
    # labels FOREVER, reported as a pipeline fault. One reviewer rejecting one
    # string would freeze sponsor labels permanently.
    mutate(change = case_when(
      old_clean == sponsor_clean                              ~ "unchanged",
      old_status %in% "unknown" & match_status == "accepted"  ~ "unknown -> accepted",
      match_status == "human_unassigned"                      ~ "human unassign (intended)",
      match_status == "unknown"                               ~ "REGRESSION: -> unknown",
      TRUE                                                    ~ "label changed"
    ))

  cat("\n=== regression diff vs baseline ===\n")
  print(as.data.frame(d |> count(change, sort = TRUE)))

  reg_rows <- d |> filter(change == "REGRESSION: -> unknown")
  if (nrow(reg_rows)) {
    cat(sprintf("\n%d REGRESSIONS — these must be zero before switching the app over:\n",
                nrow(reg_rows)))
    print(as.data.frame(reg_rows |> select(`_id`, old_clean, raw_sponsor) |> head(15)))
  }

  # Print these, do not merely count them. The class above is deliberately NOT
  # asserted on, so a mistaken reject of a 400-trial sponsor would otherwise pass
  # in total silence — the same "gate stops measuring" failure documented at the
  # baseline comment above. A reviewer's error shows up here and nowhere else.
  hu_rows <- d |> filter(change == "human unassign (intended)")
  if (nrow(hu_rows)) {
    cat(sprintf("\n%d trial(s) lost a label because a reviewer unassigned the string.\n",
                nrow(hu_rows)))
    cat("READ THIS — a mistaken reject is visible here and in no other output:\n")
    print(as.data.frame(hu_rows |> count(raw_sponsor, old_clean, name = "trials") |>
                          arrange(desc(trials)) |> head(15)))
  }
  # Assert ONLY on this class. `label changed` is 18,105 against the frozen v1
  # baseline and grows as new strings resolve, so asserting on it would fail
  # every night for the wrong reason.
  # Exit 1 = measured a regression. Distinct from exit 2 below, which means the
  # gate could not measure at all — the caller must be able to tell those apart,
  # because one should block the write and the other should not.
  if (assert_clean && nrow(reg_rows)) {
    message(sprintf("--assert-no-regressions: %d accepted -> unknown regression(s).",
                    nrow(reg_rows)))
    quit(save = "no", status = 1L)
  }

  changed <- d |> filter(change == "label changed") |>
    count(raw_sponsor, old_clean, sponsor_clean, name = "trials") |>
    arrange(desc(trials))
  if (nrow(changed)) {
    cat("\ntop label changes by trial count — hand-check these:\n")
    print(as.data.frame(head(changed, 25)))
  }
} else {
  cat("\nNo comparable baseline found; skipping the regression diff.\n")
  # Exit 2 = COULD NOT MEASURE. Distinct from exit 1 (measured a regression).
  #
  # Silence here is how a gate rots: it previously returned 0, so
  # --assert-no-regressions reported success while comparing against nothing at
  # all. A gate that cannot run must say so, or it is worse than no gate —
  # it manufactures confidence.
  #
  # The caller decides what to do: rebuild_cache.R still writes labels on a 2
  # (better to ship good labels than none while a one-off setup step is
  # outstanding) but raises the sentinel, so the deploy exits non-zero and
  # somebody fixes the baseline.
  if (assert_clean) {
    cat("--assert-no-regressions: cannot assert without a baseline.\n")
    cat("  Create one from the OLD pipeline's output:\n")
    cat("    Rscript LEGACY/sponsor_norm_pipeline/3_build_sponsor_labels.R\n")
    cat("    Rscript .../E_emit.R --freeze-baseline\n")
    quit(save = "no", status = 2L)
  }
}

if (diff_only) { cat("\n--diff-only: nothing written.\n"); quit(save = "no", status = 0L) }

# ── Write ─────────────────────────────────────────────────────────────────────

out <- per_trial |>
  select(`_id`, raw_sponsor, sponsor_clean, sponsor_parent, sponsor_type, match_status)
write_csv(out, OUT_PATH, na = "", eol = "\n")
cat(sprintf("\nwrote %s (%d rows)\n", basename(OUT_PATH), nrow(out)))

log <- per_trial |>
  group_by(raw_sponsor) |>
  summarise(
    sponsor_clean = dplyr::first(sponsor_clean),
    sponsor_parent = dplyr::first(sponsor_parent),
    sponsor_type = dplyr::first(sponsor_type),
    match_status = dplyr::first(match_status),
    confidence = dplyr::first(confidence),
    decided_by = dplyr::first(decided_by),
    n_trials = dplyr::n(),
    .groups = "drop"
  ) |>
  arrange(desc(n_trials))
write_csv(log, LOG_PATH, na = "", eol = "\n")
cat(sprintf("wrote %s (%d distinct strings)\n", basename(LOG_PATH), nrow(log)))

# ── Reviewer queue ────────────────────────────────────────────────────────────

impact <- log |> select(raw_sponsor, n_trials)
queue <- route_for_review(asg, impact) |>
  left_join(reg |> select(entity_id, canonical), by = "entity_id") |>
  transmute(
    raw_sponsor,
    proposed = canonical,
    confidence,
    n_trials,
    review_reason,
    reason,
    channel,
    model_id
  )
write_csv(queue, QUEUE, na = "", eol = "\n")
cat(sprintf("wrote %s (%d rows for review)\n", basename(QUEUE), nrow(queue)))
cat(sprintf("  that is %.1f%% of assignments, carrying %d trial rows\n",
            100 * nrow(queue) / max(nrow(asg), 1L), sum(queue$n_trials, na.rm = TRUE)))
cat("\nReview in the curation app; accepted decisions pin against later re-runs.\n")
