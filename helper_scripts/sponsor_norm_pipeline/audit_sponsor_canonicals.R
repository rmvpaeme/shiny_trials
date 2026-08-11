# Audit the sponsor canonical vocabulary.
#
# The resolver in 5_llm_resolve.R picks from the canonical list, so the list has
# to be right before any proposals are cached — a canonical merged afterwards
# changes candidates_sha256 and silently invalidates them. This reports the five
# vocabulary checks from PLANS/normalisation-llm-resolver.md and, with
# --fix-self-aliases, closes the self-alias gap.
#
# Checks
#   1. canonicals that collide under clean_sponsor_alias()
#   2. canonicals differing only by a trailing legal suffix
#   3. canonicals backed by exactly one alias
#   4. canonicals with no self-alias (the label maps nothing to itself)
#   5. unapplied rows in the generated merge queue
#
# Why 4 matters: check_alias() matches `alias_clean %in% candidates`, so a
# canonical that never appears as an alias_clean cannot match on the alias tier
# even when the raw sponsor arrives spelled exactly like the label. It falls
# through to containment or fuzzy, or misses entirely.
#
# Usage
#   Rscript helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R
#   Rscript helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R --fix-self-aliases
#
# --fix-self-aliases writes the *safe* subset to sponsor_llm_aliases.csv (the
# hand-maintained seed, which survives an index rebuild — 2_sponsor_alias_index.csv
# is generated and would lose them). An emitted alias that would collide with an
# existing alias pointing somewhere else, or with another emitted alias, is a
# real conflict: it is reported and skipped, never overwritten.

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(readr)
  library(stringr)
  library(tibble)
})

script_path <- tryCatch({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
  } else {
    NA_character_
  }
}, error = function(e) NA_character_)
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)

args           <- commandArgs(trailingOnly = TRUE)
fix_self_alias <- "--fix-self-aliases" %in% args

# Self-aliases must be the WEAKEST tier of evidence, not the strongest.
# check_alias() ranks by `confidence_prior * 100 - candidate_rank`, so at
# confidence 1 a self-alias matching the full raw string (rank 1, score 99)
# beats a curated alias that only matches a stripped candidate (rank 4, score
# 96) — and silently overrides deliberate consolidations like
# "Millennium Pharmaceuticals" -> Takeda. At 0.94 a self-alias scores ~93:
#   * still >= 90, so it is "accepted" when it is the only match — which is the
#     entire point, closing the gap where a raw string arrives spelled exactly
#     like its label and nothing else fires;
#   * loses to any curated confidence-1.0 alias matching at rank <= 6;
#   * below the 0.95 floor for containment and fuzzy targets, so it adds no new
#     containment or fuzzy surface and cannot perturb matches on those tiers.
SELF_ALIAS_CONFIDENCE <- 0.94

# Keys the candidate-hijack guard cannot see, found by running the trial-level
# gate. The guard reasons over raw strings that already resolve; these two were
# `unknown` in the baseline, so they claimed nothing — but they sit on
# multi-sponsor trials where a co-sponsor supplied the trial label. Resolving
# them flips that label to the subsidiary (and to a row with no
# sponsor_parent/sponsor_group), which the gate counts as a changed
# already-matched trial. Three trials, all measured 2026-08-11. Re-derive by
# diffing data/trial_sponsor_labels.csv across a rebuild; do not extend this
# list by guessing.
SELF_ALIAS_EXCLUDE <- c(
  "dainippon sumitomo pharma america",  # trial label was Sumitomo Pharma
  "profibrix"                           # trial label was The Medicines Company
)

SNP        <- project_path("config", "sponsor_norm_pipeline")
INDEX      <- file.path(SNP, "2_sponsor_alias_index.csv")
SEED       <- file.path(SNP, "sponsor_llm_aliases.csv")
REVIEW     <- file.path(SNP, "2_final_sponsor_canonical_review.csv")
CONFLICTS  <- file.path(SNP, "2_self_alias_conflicts.csv")
LOG        <- project_path("data", "sponsor_normalisation_log.csv")

source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = TRUE
)

read_csv_or_empty <- function(path) {
  if (file.exists(path)) readr::read_csv(path, show_col_types = FALSE) else tibble::tibble()
}

index <- read_csv_or_empty(INDEX)
if (nrow(index) == 0L) {
  stop("No alias index at ", INDEX, " — run 2_build_sponsor_index.R first.", call. = FALSE)
}

rule <- function(title) {
  cat("\n", title, "\n", strrep("-", nchar(title)), "\n", sep = "")
}

# One row per canonical, carrying the metadata the emitted self-alias should
# inherit. first_non_na keeps parent/group/type consistent with what the index
# already claims for that label rather than inventing NA.
first_non_na <- function(x) {
  x <- x[!is.na(x) & x != "NA" & nzchar(x)]
  if (length(x) == 0L) NA_character_ else x[[1L]]
}

canonicals <- index |>
  dplyr::filter(!is.na(sponsor_clean), nzchar(sponsor_clean)) |>
  dplyr::group_by(sponsor_clean) |>
  dplyr::summarise(
    n_aliases      = dplyr::n(),
    sponsor_parent = first_non_na(as.character(sponsor_parent)),
    sponsor_group  = first_non_na(as.character(sponsor_group)),
    sponsor_type   = first_non_na(as.character(sponsor_type)),
    .groups        = "drop"
  ) |>
  dplyr::mutate(self_key = clean_sponsor_alias(sponsor_clean))

cat(sprintf(
  "Alias index: %d rows, %d distinct canonicals\n",
  nrow(index), nrow(canonicals)
))

# ── 1. Collide under clean_sponsor_alias() ────────────────────────────────────

collisions <- canonicals |>
  dplyr::group_by(self_key) |>
  dplyr::filter(dplyr::n_distinct(sponsor_clean) > 1L) |>
  dplyr::summarise(
    labels = paste(sort(unique(sponsor_clean)), collapse = " | "),
    .groups = "drop"
  )

rule(sprintf("1. Collide under clean_sponsor_alias(): %d group(s)", nrow(collisions)))
if (nrow(collisions) > 0L) {
  purrr::walk(collisions$labels, ~ cat("  ", .x, "\n", sep = ""))
}

# ── 2. Differ only by a trailing legal suffix ─────────────────────────────────

strip_legal <- function(x) {
  clean_sponsor_alias(x) |>
    stringr::str_remove_all(stringr::regex(.legal_suffixes_rx, ignore_case = TRUE)) |>
    stringr::str_squish()
}

legal_pairs <- canonicals |>
  dplyr::mutate(legal_key = strip_legal(sponsor_clean)) |>
  dplyr::filter(nzchar(legal_key)) |>
  dplyr::group_by(legal_key) |>
  dplyr::filter(dplyr::n_distinct(self_key) > 1L) |>
  dplyr::summarise(
    labels = paste(sort(unique(sponsor_clean)), collapse = " | "),
    .groups = "drop"
  )

rule(sprintf("2. Differ only by a trailing legal suffix: %d group(s)", nrow(legal_pairs)))
if (nrow(legal_pairs) > 0L) {
  purrr::walk(legal_pairs$labels, ~ cat("  ", .x, "\n", sep = ""))
}

# ── 3. Backed by exactly one alias ────────────────────────────────────────────

single_alias <- canonicals |> dplyr::filter(n_aliases == 1L)
rule(sprintf(
  "3. Backed by exactly one alias: %d of %d (%.0f%%)",
  nrow(single_alias), nrow(canonicals), 100 * nrow(single_alias) / nrow(canonicals)
))

# ── 4. No self-alias ──────────────────────────────────────────────────────────

self_aliased <- index |>
  dplyr::filter(!is.na(alias_clean), !is.na(sponsor_clean)) |>
  dplyr::mutate(is_self = clean_sponsor_alias(alias_clean) == clean_sponsor_alias(sponsor_clean)) |>
  dplyr::filter(is_self) |>
  dplyr::distinct(sponsor_clean) |>
  dplyr::pull(sponsor_clean)

missing_self <- canonicals |> dplyr::filter(!sponsor_clean %in% self_aliased)
rule(sprintf(
  "4. No self-alias: %d of %d (%.0f%%)",
  nrow(missing_self), nrow(canonicals), 100 * nrow(missing_self) / nrow(canonicals)
))

# ── 5. Unapplied rows in the merge queue ──────────────────────────────────────

review <- read_csv_or_empty(REVIEW)
rule("5. Merge queue")
if (nrow(review) == 0L) {
  cat("  no queue at ", REVIEW, "\n", sep = "")
} else {
  unapplied <- review |> dplyr::filter(!applied)
  cat(sprintf("  %d of %d rows unapplied\n", nrow(unapplied), nrow(review)))
  unapplied |>
    dplyr::count(confidence_bucket, blocked_reason, name = "n") |>
    dplyr::arrange(dplyr::desc(n)) |>
    purrr::pwalk(function(confidence_bucket, blocked_reason, n) {
      cat(sprintf(
        "    %-8s %5d  %s\n", confidence_bucket, n,
        dplyr::coalesce(blocked_reason, "(no blocked_reason)")
      ))
    })
}

# ── Emit the safe self-alias subset ───────────────────────────────────────────

# Every alias_clean already in the index, with the canonical it points at. An
# emitted row whose key is already taken by a *different* canonical is a
# conflict, not a no-op — the existing mapping wins and we report the clash.
existing <- index |>
  dplyr::filter(!is.na(alias_clean)) |>
  dplyr::mutate(alias_clean = clean_sponsor_alias(alias_clean)) |>
  dplyr::group_by(alias_clean) |>
  dplyr::summarise(
    existing_targets = paste(sort(unique(sponsor_clean)), collapse = " | "),
    .groups = "drop"
  )

# A self-alias is only safe if the label does not ALREADY resolve to some other
# canonical. Key-collision checks alone are not enough: check_alias() scores
# `confidence_prior * 100 - candidate_rank`, so a self-alias matching the full
# string (rank 1) outranks a curated alias that only matches a stripped
# candidate. Emitting blindly therefore defeats deliberate consolidations —
# measured on 2026-08-11, it rewrote 66 already-matched trials, e.g.
# "Sanofi Pasteur SA" reverting from the curated parent `Sanofi` to itself.
# So run each label through the current matcher and skip any that already lands
# somewhere else. Those are findings about the vocabulary, not noise.
cat("\nResolving ", nrow(missing_self), " labels through the current matcher",
    " (this takes a minute)...\n", sep = "")
cfg <- load_sponsor_configs(SNP)
resolved <- purrr::map_dfr(missing_self$sponsor_clean, function(lbl) {
  r <- normalise_one(lbl, cfg, allow_fuzzy = TRUE)
  tibble::tibble(
    resolves_to     = as.character(r$sponsor_clean[[1L]]),
    resolves_source = as.character(r$match_source[[1L]]),
    resolves_status = as.character(r$match_status[[1L]])
  )
})

# Checking the label alone is not enough. check_alias() matches against
# make_sponsor_candidates(raw) — the STRIPPED forms of each raw string — so a
# self-alias hijacks any already-matched raw string that generates its key as a
# candidate, even though the label itself resolves fine. Measured, this is what
# every remaining regression was: the one-token label "medac" is the first-word
# candidate of "Medac Gesellschaft fuer klinische Spezialprapaerate mbH", and
# "millennium pharmaceuticals" is a stripped form of "Millennium
# Pharmaceuticals, a wholly owned subsidiary of Takeda". So build the candidate
# -> current-canonical map over every already-matched raw string and refuse any
# self-alias key that appears in it pointing somewhere else.
claimed <- tibble::tibble(cand = character(), claimed_by = character())
if (file.exists(LOG)) {
  cat("Mapping generated candidates of already-matched raw strings...\n")
  matched <- readr::read_csv(LOG, show_col_types = FALSE) |>
    dplyr::filter(
      !is.na(sponsor_clean), nzchar(sponsor_clean),
      !match_status %in% c("unknown", "rejected")
    ) |>
    dplyr::distinct(raw_sponsor, sponsor_clean)

  # One tibble at the end, not one per raw string: map_dfr over ~15k rows binds
  # 15k single-row frames and dominates the runtime of the whole audit.
  cand_lists <- purrr::map(matched$raw_sponsor, function(raw) {
    unique(c(clean_sponsor_alias(raw), make_sponsor_candidates(raw)))
  })
  claimed <- tibble::tibble(
    cand       = unlist(cand_lists, use.names = FALSE),
    claimed_by = rep(matched$sponsor_clean, lengths(cand_lists))
  ) |>
    dplyr::filter(!is.na(cand), nzchar(cand)) |>
    dplyr::group_by(cand) |>
    dplyr::summarise(
      claimed_by = paste(sort(unique(claimed_by)), collapse = " | "),
      .groups = "drop"
    )
} else {
  message("No normalisation log at ", LOG,
          " — skipping the candidate-hijack check. Run 3_build_sponsor_labels.R",
          " first for a complete audit.")
}

emitted <- missing_self |>
  dplyr::bind_cols(resolved) |>
  dplyr::transmute(
    alias_clean      = self_key,
    sponsor_clean,
    sponsor_parent,
    sponsor_group,
    sponsor_type,
    source           = "self_alias",
    confidence_prior = SELF_ALIAS_CONFIDENCE,
    alias_type       = "self",
    resolves_to, resolves_source, resolves_status
  ) |>
  dplyr::filter(nzchar(alias_clean)) |>
  dplyr::left_join(existing, by = "alias_clean") |>
  dplyr::left_join(claimed, by = c("alias_clean" = "cand")) |>
  # Two distinct canonicals cleaning to the same key would each claim it.
  dplyr::group_by(alias_clean) |>
  dplyr::mutate(n_claimants = dplyr::n_distinct(sponsor_clean)) |>
  dplyr::ungroup() |>
  dplyr::mutate(
    conflict = dplyr::case_when(
      alias_clean %in% SELF_ALIAS_EXCLUDE ~
        "measured to change a multi-sponsor trial's label (SELF_ALIAS_EXCLUDE)",
      n_claimants > 1L ~ "two canonicals clean to the same alias key",
      !is.na(existing_targets) & existing_targets != sponsor_clean ~
        paste0("alias key already maps to: ", existing_targets),
      !is.na(claimed_by) & claimed_by != sponsor_clean ~
        paste0("key is a candidate of a matched raw string for: ", claimed_by),
      !is.na(resolves_to) & resolves_to != sponsor_clean ~
        paste0("label already resolves to: ", resolves_to),
      TRUE ~ NA_character_
    )
  )

conflicts <- emitted |> dplyr::filter(!is.na(conflict))
safe      <- emitted |>
  dplyr::filter(is.na(conflict)) |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
    sponsor_type, source, confidence_prior, alias_type
  )

rule(sprintf(
  "Self-alias emission: %d safe, %d conflict(s)", nrow(safe), nrow(conflicts)
))
if (nrow(conflicts) > 0L) {
  # The two kinds need opposite responses, so split them rather than reporting
  # one undifferentiated pile. A label that currently lands via the fuzzy tier
  # is a Jaro-Winkler false positive the self-alias would FIX
  # ("Abalos Therapeutics" -> "Alba Therapeutics"); one that lands via the
  # alias/containment/family tiers is a deliberate consolidation the
  # self-alias would BREAK ("Almirall Hermal" -> "Almirall"). Both are held
  # back here — fixing the first kind changes already-matched trials, which is
  # a decision for a human, not for this script.
  conflicts <- conflicts |>
    dplyr::mutate(
      triage = dplyr::case_when(
        stringr::str_detect(conflict, "SELF_ALIAS_EXCLUDE") ~
          "measured to change a multi-sponsor trial's label",
        stringr::str_detect(conflict, "^key is a candidate") ~
          "would hijack an already-matched raw string",
        stringr::str_starts(dplyr::coalesce(resolves_source, ""), "fuzzy") ~
          "fuzzy false positive — self-alias would fix",
        stringr::str_detect(conflict, "^alias key") ~
          "alias key taken by another canonical",
        TRUE ~ "deliberate mapping — self-alias would override"
      )
    )
  conflicts |>
    dplyr::count(triage, name = "n") |>
    dplyr::arrange(dplyr::desc(n)) |>
    purrr::pwalk(function(triage, n) cat(sprintf("  %5d  %s\n", n, triage)))

  readr::write_csv(
    conflicts |>
      dplyr::select(
        alias_clean, sponsor_clean, resolves_to, resolves_source,
        resolves_status, triage, conflict
      ) |>
      dplyr::arrange(triage, alias_clean),
    CONFLICTS, na = "NA"
  )
  cat("  wrote ", basename(CONFLICTS), " for review\n", sep = "")
}

if (!fix_self_alias) {
  cat("\nDry run. Re-run with --fix-self-aliases to append the safe subset to\n")
  cat("  ", SEED, "\n", sep = "")
  quit(save = "no", status = 0L)
}

if (nrow(safe) == 0L) {
  cat("\nNothing to write.\n")
  quit(save = "no", status = 0L)
}

seed <- read_csv_or_empty(SEED)
seed_cols <- names(seed)
stopifnot(all(names(safe) %in% seed_cols))

# Re-check against the seed itself: the index is a superset, but be explicit so
# a rerun is a no-op rather than a duplicate-row generator.
already <- seed |>
  dplyr::mutate(alias_clean = clean_sponsor_alias(alias_clean)) |>
  dplyr::pull(alias_clean)
to_write <- safe |> dplyr::filter(!alias_clean %in% already)

out <- dplyr::bind_rows(seed, to_write[, seed_cols]) |>
  dplyr::arrange(alias_clean)

tmp <- paste0(SEED, ".tmp")
readr::write_csv(out, tmp, na = "NA")
invisible(file.rename(tmp, SEED))

cat(sprintf(
  "\nAppended %d self-alias rows to %s (%d -> %d rows)\n",
  nrow(to_write), basename(SEED), nrow(seed), nrow(out)
))
cat("Next: rebuild the index and labels, then check the gate:\n")
cat("  Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-ror --no-location\n")
cat("  Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R\n")
