# Drop the rows of substance_llm_overrides.csv that change nothing.
#
# Why this matters. The override file is checked at step 2 of the matcher
# (normalise_substances.R, normalise_one) — after the placebo rule but ahead of
# the negative list, canonical_substances.csv, every alias tier and fuzzy
# matching. Its rows therefore outrank everything beneath them, including any
# tier added later. Most are frozen LLM output that the alias index has since
# learned to reproduce on its own, so they sit at the top of the priority order
# shadowing tiers that would give the same answer anyway.
#
# Usage:
#   Rscript helper_scripts/substance_norm_pipeline/prune_substance_overrides.R
#   Rscript helper_scripts/substance_norm_pipeline/prune_substance_overrides.R --apply
#   Rscript .../prune_substance_overrides.R --report=/tmp/prune.csv --no-differential
#
# Without --apply nothing is written; the classification and the gate still run.
#
# Recovery: this script never edits a row, only drops whole rows, and the file
# is version-controlled — so `git checkout config/substance_norm_pipeline/\
# substance_llm_overrides.csv` restores everything. There is deliberately no
# --restore mode: the differential below already puts back anything whose
# removal moves an answer, so a hand-restore path would be dead code guarding a
# case that should not occur.

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(tibble)
  library(purrr)
})

script_path <- local({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  NA_character_
})
project_root <- if (!is.na(script_path)) {
  normalizePath(file.path(dirname(script_path), "..", ".."), mustWork = TRUE)
} else {
  getwd()
}
project_path <- function(...) file.path(project_root, ...)

args        <- commandArgs(trailingOnly = TRUE)
apply_prune <- "--apply" %in% args
skip_diff   <- "--no-differential" %in% args
report_path <- local({
  v <- args[startsWith(args, "--report=")]
  if (length(v) == 0L) {
    file.path(tempdir(), "substance_override_prune_report.csv")
  } else {
    sub("^--report=", "", v[[1]])
  }
})

config_dir     <- Sys.getenv("CONFIG_DIR",
                             unset = project_path("config", "substance_norm_pipeline"))
data_dir       <- Sys.getenv("DATA_DIR", unset = project_path("data"))
overrides_path <- file.path(config_dir, "substance_llm_overrides.csv")
raw_path       <- file.path(data_dir, "trial_substances_raw.csv")

source(project_path("helper_scripts", "substance_norm_pipeline",
                    "normalise_substances.R"), local = FALSE)
# write_csv_atomic() and detect_eol(). The reviewer app writes this same file
# via apply_substance_conflicts(), and writing it any other way would re-quote
# every row and bury the real change in the diff.
source(project_path("curation_app", "R", "store.R"), local = FALSE)

# ── load ──────────────────────────────────────────────────────────────────────

overrides <- readr::read_csv(overrides_path, show_col_types = FALSE)
message(sprintf("Overrides: %d rows, %d distinct keys",
                nrow(overrides), dplyr::n_distinct(overrides$raw_clean)))

cfg <- load_substance_configs(config_dir = config_dir)

# The config as it would be with the override tier gone.
cfg_without <- cfg
cfg_without$overrides <- tibble::tibble()

# ── protected keys ────────────────────────────────────────────────────────────
#
# Two reasons a duplicated key must keep every one of its rows:
#
#   1. check_override() does `filter(raw_clean %in% candidates) |> slice(1)`, so
#      only the FIRST row per key is reachable. Dropping a redundant first row
#      promotes the shadowed second one and changes the answer — the opposite of
#      what a redundancy prune is for.
#   2. The reviewer app's "Substance conflicts" tier
#      (curation_app/R/tiers.R, load_substance_conflicts) is built from exactly
#      these rows: one raw string overridden to two different substances,
#      because the chunked curation appended its corrections instead of
#      replacing what it was fixing. Pruning them would empty a known-wrong-rows
#      queue before a human ever works it.

dup_keys <- overrides |>
  dplyr::count(raw_clean, name = "n") |>
  dplyr::filter(n > 1L) |>
  dplyr::pull(raw_clean)

message(sprintf("Protected: %d rows across %d duplicated keys (reviewer conflicts tier)",
                sum(overrides$raw_clean %in% dup_keys), length(dup_keys)))

# ── classify ──────────────────────────────────────────────────────────────────
#
# What the matcher returns for each key WITH its override is knowable without
# running the matcher: clean_alias() is idempotent, so the override's own
# raw_clean is always in its candidate set and check_override() always fires —
# with one exception, check_placebo(), which runs first. Those rows are
# unreachable and classify as redundant, correctly.
#
# .return() applies sanitise_substance_output() on the way out, so the override
# side has to be sanitised too or the comparison is not like-for-like.

candidate_keys <- setdiff(unique(overrides$raw_clean), dup_keys)

message(sprintf("Re-matching %d candidate keys without the override tier...",
                length(candidate_keys)))
without <- normalise_substances(candidate_keys, configs = cfg_without,
                                allow_fuzzy = TRUE)

effective <- overrides |>
  dplyr::filter(raw_clean %in% candidate_keys) |>
  dplyr::mutate(
    intercepted_by_placebo = stringr::str_detect(
      stringr::str_to_lower(raw_clean), "\\bplacebo\\b"
    ),
    with_label = dplyr::if_else(
      intercepted_by_placebo, "placebo",
      purrr::map_chr(substance_clean, sanitise_substance_output)
    ),
    with_status = dplyr::if_else(intercepted_by_placebo, "accepted", match_status)
  )

classified <- effective |>
  dplyr::left_join(
    without |>
      dplyr::select(raw_clean = raw_substance,
                    index_label  = active_substance_clean,
                    index_status = match_status),
    by = "raw_clean"
  ) |>
  dplyr::mutate(
    verdict = dplyr::case_when(
      !is.na(index_label) &
        index_label == with_label &
        index_status == with_status   ~ "redundant",
      is.na(index_label)              ~ "sole_source",
      TRUE                            ~ "conflict"
    )
  )

print(as.data.frame(
  classified |>
    dplyr::count(verdict, sort = TRUE) |>
    dplyr::mutate(share = sprintf("%.1f%%", 100 * n / sum(n)))
), row.names = FALSE)

prune_keys <- classified |>
  dplyr::filter(verdict == "redundant") |>
  dplyr::pull(raw_clean) |>
  unique()

# ── the differential gate ─────────────────────────────────────────────────────
#
# The classification above tests each override against its OWN key. That is not
# enough. check_override() matches `raw_clean %in% candidates`, and candidates
# is generate_candidates(raw) = {x0, x_no_dose, x_no_form, first_token} — so an
# override keyed "imatinib" also fires for the register string
# "imatinib 100 mg". Removing a row can therefore move a string that is not the
# row's own key.
#
# So test on the register itself. Only strings whose candidate set intersects
# the pruned keys can change; everything else is provably unaffected and does
# not need re-normalising, which is what keeps this cheap.
#
# This is a stronger gate than diffing the label file, because labels are
# aggregated per trial (sort(unique(...)) joined with " / ") and two offsetting
# changes inside one trial would cancel out and pass unnoticed.

run_differential <- function(prune_keys) {
  if (!file.exists(raw_path)) {
    warning("No ", raw_path, " — differential gate skipped. Rebuild and diff ",
            "data/trial_substance_labels.csv manually.", call. = FALSE)
    return(prune_keys)
  }

  raw <- readr::read_csv(raw_path, show_col_types = FALSE,
                         col_types = readr::cols(
                           `_id`         = readr::col_character(),
                           raw_substance = readr::col_character()
                         ))
  # The same pre-filter 3_build_substance_labels.R applies before normalising.
  raw <- raw |>
    dplyr::filter(
      !is.na(raw_substance),
      nchar(trimws(raw_substance)) >= 3,
      grepl("[A-Za-z]{3,}", raw_substance),
      !grepl("^[0-9][0-9.,]* *(mg|ml|g|mcg|mL|IU|ui|%|ppm|mBq|GBq|L\\b)",
             raw_substance, ignore.case = TRUE),
      !grepl("^m[Ll][[:space:].,]", raw_substance, ignore.case = TRUE)
    )

  register <- unique(raw$raw_substance)
  register <- register[!is.na(register) & nzchar(trimws(register))]
  cand <- purrr::map(register, generate_candidates)

  repeat {
    affected <- register[purrr::map_lgl(cand, ~ any(.x %in% prune_keys))]
    message(sprintf("Differential: %d of %d register strings can be affected",
                    length(affected), length(register)))
    if (length(affected) == 0L) return(prune_keys)

    cfg_pruned <- cfg
    cfg_pruned$overrides <- overrides |> dplyr::filter(!raw_clean %in% prune_keys)

    before <- normalise_substances(affected, configs = cfg, allow_fuzzy = TRUE)
    after  <- normalise_substances(affected, configs = cfg_pruned, allow_fuzzy = TRUE)

    moved <- which(
      !identical_answer(before$active_substance_clean, after$active_substance_clean) |
        !identical_answer(before$match_status, after$match_status)
    )
    if (length(moved) == 0L) {
      message("Differential: no register string moves. Gate passed.")
      return(prune_keys)
    }

    # Put back every pruned key that the moved strings could have been using.
    moved_strings <- before$raw_substance[moved]
    guilty <- unique(unlist(
      purrr::map(moved_strings, ~ intersect(generate_candidates(.x), prune_keys)),
      use.names = FALSE
    ))
    message(sprintf(
      "Differential: %d strings moved; restoring %d override keys and retrying",
      length(moved_strings), length(guilty)
    ))
    if (length(guilty) == 0L) {
      stop("Strings moved but no pruned key explains it — investigate before ",
           "applying. First: ", moved_strings[[1L]], call. = FALSE)
    }
    prune_keys <- setdiff(prune_keys, guilty)
  }
}

identical_answer <- function(a, b) {
  (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a == b)
}

if (!skip_diff) prune_keys <- run_differential(prune_keys)

# ── result ────────────────────────────────────────────────────────────────────

survivors <- overrides |> dplyr::filter(!raw_clean %in% prune_keys)

message(sprintf(
  "\nPrune: %d rows -> %d survivors (%d dropped, %.1f%%)",
  nrow(overrides), nrow(survivors), nrow(overrides) - nrow(survivors),
  100 * (1 - nrow(survivors) / nrow(overrides))
))

classified |>
  dplyr::mutate(pruned = raw_clean %in% prune_keys) |>
  dplyr::select(raw_clean, substance_clean, reason, with_label, with_status,
                index_label, index_status, verdict, pruned) |>
  readr::write_csv(report_path)
message(sprintf("Classification written to %s", report_path))

if (!apply_prune) {
  message("\nDry run. Re-run with --apply to rewrite the CSV.")
  quit(status = 0L)
}

write_csv_atomic(
  survivors, overrides_path,
  eol = detect_eol(overrides_path),
  quote = "all"   # as apply_substance_conflicts() writes it
)
message(sprintf("Rewrote %s with %d rows.", basename(overrides_path), nrow(survivors)))
message("Now rebuild: data/trial_substance_labels.csv must come out byte-identical.")
