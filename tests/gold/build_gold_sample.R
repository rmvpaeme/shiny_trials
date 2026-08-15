#!/usr/bin/env Rscript
# Build the frozen blind gold standard for sponsor normalisation.
#
# This is the baseline every later pipeline version is measured against, so it
# is built and frozen BEFORE any pipeline run and must never be tuned against.
#
# Two properties make the number trustworthy, and both are structural rather
# than procedural:
#
#   Blind      — reviewer-facing files carry the raw string and its registry
#                context only. No canonical, no candidate, no confidence, no
#                stratum. An adjudicator cannot anchor on a prediction they
#                cannot see.
#   Sealed     — every stratum assignment lives in the sampling key, which is
#                read at scoring time and never shown. Per-stratum accuracy is
#                therefore computable without ever having leaked the stratum.
#
# Nothing here reads pipeline output. n_trials is counted from the raw export,
# register and country come from the trial id, and the type prior is a local
# rule set deliberately duplicated from (rather than shared with) the matcher:
# a benchmark that imports the thing it grades outlives nothing.
#
# Usage
#   Rscript tests/gold/build_gold_sample.R              # write fixtures
#   Rscript tests/gold/build_gold_sample.R --dry-run    # report strata, write nothing
#   Rscript tests/gold/build_gold_sample.R --force      # overwrite frozen fixtures
#
# Refusing to overwrite without --force is the point: a fixture that silently
# changes is a benchmark that silently lies.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(stringi)
  library(openssl)
})

# ── Pinned identity ───────────────────────────────────────────────────────────
# SEED is what makes the sample reproducible; changing it draws a different
# benchmark and invalidates every score ever taken against the old one.

SEED         <- 20260811L
VERSION      <- "v1"
N_TOTAL      <- 1000L
N_ROUND1     <- 400L
READJ_FRAC   <- 0.15
TRAP_CAP     <- 70L   # max cases drawn per adversarial family
CELL_FLOOR   <- 10L   # min cases per non-empty ordinary stratum, population permitting

args    <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args
force   <- "--force"   %in% args

script_path <- local({
  a <- commandArgs(FALSE)
  hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
fixture_dir  <- file.path(script_dir, "fixtures")
raw_path     <- file.path(project_root, "data", "trial_sponsors_raw.csv")

if (!file.exists(raw_path)) {
  stop("Missing ", raw_path, " — run 1_export_trial_sponsors.R first.", call. = FALSE)
}

# ── Local type prior ──────────────────────────────────────────────────────────
# Stratification only, and it lives in the sealed key. Deliberately crude: its
# job is to stop the sample being 90% industry, not to be right.

type_prior <- function(x) {
  s <- tolower(x)
  dplyr::case_when(
    str_detect(s, "\\b(ltd|inc|gmbh|s\\.?a\\.?|b\\.?v\\.?|a/s|plc|llc|pharma|pharmaceutical|biotech|therapeutic|laboratoires|s\\.?p\\.?a\\.?)\\b") ~ "industry",
    str_detect(s, "hospital|klinik|clinic|ziekenhuis|spital|ospedale|h(ô|o)pital|hospitalier|sjukhus|szpital|nemocnice") ~ "hospital",
    str_detect(s, "universit|hochschule|univerz|uniwersytet|school of medicine|college") ~ "academic",
    str_detect(s, "\\b(group|groupe|gruppo|intergroup|consortium|network|collaborative|cooperative)\\b") ~ "cooperative_group",
    str_detect(s, "foundation|fondation|stichting|fundaci|fondazione|stiftung|trust|charity") ~ "foundation",
    str_detect(s, "institut|centre|center|centro|zentrum|agency|ministry|national|council") ~ "public_body",
    TRUE ~ "other"
  )
}

# ── Registry text corruption ──────────────────────────────────────────────────
# EUCTR ingestion DELETES non-ASCII characters rather than transliterating them:
# "Abteilung für Anästhesie" is stored as "Abteilung fr Ansthesie". Verified —
# the deleted form appears verbatim in the corpus while the transliterated form
# ("Abteilung fur Anasthesie") does not, and all 14,285 distinct EUCTR strings
# are pure ASCII while CTIS keeps its diacritics.
#
# This matters here only for stratification: mangled strings are a distinct
# failure mode and a headline accuracy number should not hide them. The
# retrieval fix needs no detector at all — indexing both the transliterated and
# the deleted fold form catches every case, flagged or not.
#
# Stem matching is deliberate. A consonant-run heuristic was tried and rejected:
# it fires on GmbH, KGaA and GlaxoSmithKline, flagging 10.8% of CTIS (which is
# not corrupted at all). This list is high-precision and a LOWER BOUND — real
# prevalence is somewhat above the ~4.7% it detects.

MANGLED_STEMS <- c(
  "universitt", "abteilung fr", "ansthesie", "mnchen", "kln", "zrich", "wrzburg",
  "dsseldorf", "gttingen", "tbingen", "nrnberg", "hpital", "kbenhavn", "linkping",
  "jyvskyl", "mnster", "pdiatri", "charit", "klinik fr", "institut fr", "hmatologie",
  "onkologie fr", "universittsklinik", "frderung", "gesundheitsfrderung"
)
looks_mangled <- function(x) {
  s <- tolower(x)
  Reduce(`|`, lapply(MANGLED_STEMS, function(k) grepl(k, s, fixed = TRUE)))
}

# ── Adversarial families ──────────────────────────────────────────────────────
# Drawn from the four project rules in the pipeline README. These are the cases
# a headline accuracy number is most likely to hide, so they are sampled
# deliberately rather than left to chance. First match wins.

trap_family <- function(x) {
  s <- tolower(x)
  uni  <- str_detect(s, "universit|hochschule|univerz")
  hosp <- str_detect(s, "hospital|klinik|clinic|ziekenhuis|spital|ospedale|h(ô|o)pital|hospitalier")
  dplyr::case_when(
    str_detect(s, "merck|msd|sharp\\s*&?\\s*dohme")                                  ~ "merck_family",
    uni & hosp                                                                        ~ "uni_vs_hospital",
    str_detect(s, "\\b(department|departement|abteilung|afdeling|servizio|servicio|dept|unit(à|a)|klinik f(ü|u)r|service de)\\b") ~ "department",
    str_detect(x, " / | \\+ ") | str_detect(s, "\\b(and|und|et|en)\\b.*\\b(hospital|universit|institut|centre|center)\\b") ~ "combined",
    str_detect(x, "^(dr|prof|mr|ms|mrs)\\.?\\s") | str_detect(x, "^[A-Z][a-z]+ [A-Z][a-z]+$") ~ "person_like",
    TRUE                                                                              ~ "none"
  )
}

# ── Load and derive ───────────────────────────────────────────────────────────
# Every derived column comes from the export or the string itself.

raw <- read_csv(raw_path, show_col_types = FALSE, progress = FALSE)

raw <- raw |>
  mutate(
    suffix   = sub(".*-", "", .data[["_id"]]),
    register = case_when(
      grepl("^[A-Za-z]{2}$", suffix) ~ "EUCTR",
      suffix == "00"                 ~ "CTIS",
      TRUE                           ~ "OTHER"
    )
  )

strings <- raw |>
  filter(!is.na(raw_sponsor), nzchar(trimws(raw_sponsor))) |>
  group_by(raw_sponsor) |>
  summarise(
    n_trials  = n(),
    registers = paste(sort(unique(register)), collapse = "+"),
    countries = paste(sort(unique(suffix[register == "EUCTR"])), collapse = ","),
    .groups   = "drop"
  ) |>
  arrange(desc(n_trials), raw_sponsor)   # deterministic order before any sampling

strings <- strings |>
  mutate(
    case_id   = substr(as.character(openssl::sha256(raw_sponsor)), 1L, 16L),
    rank      = row_number(),
    band      = case_when(rank <= 500L ~ "head", rank <= 4000L ~ "mid", TRUE ~ "tail"),
    reg_str   = case_when(
      registers == "EUCTR" ~ "EUCTR",
      registers == "CTIS"  ~ "CTIS",
      registers == "OTHER" ~ "OTHER",
      TRUE                 ~ "MIXED"
    ),
    # Three text conditions worth measuring separately: intact diacritics (CTIS
    # only), diacritics deleted by EUCTR ingestion, and plain ASCII.
    text_form = case_when(
      stri_detect_regex(raw_sponsor, "[^\\u0001-\\u007F]") ~ "diacritics_intact",
      looks_mangled(raw_sponsor)                            ~ "diacritics_deleted",
      TRUE                                                  ~ "ascii"
    ),
    type_prior = type_prior(raw_sponsor),
    trap       = trap_family(raw_sponsor)
  )

stopifnot(!any(duplicated(strings$case_id)))

# ── Allocation ────────────────────────────────────────────────────────────────
# Two stages. Adversarial families are drawn first and capped, because they are
# rare enough that proportional allocation would miss them entirely. The rest
# is sqrt-proportional over band x register x text_form: sqrt oversamples small
# cells relative to their share, which is what a per-stratum accuracy report
# needs and what proportional allocation fails to give.

set.seed(SEED)

sample_n_from <- function(df, k) {
  k <- min(k, nrow(df))
  if (k <= 0L) return(df[0L, , drop = FALSE])
  df[sort(sample.int(nrow(df), k)), , drop = FALSE]
}

trap_pool <- strings |> filter(trap != "none")
trap_pick <- trap_pool |>
  group_split(trap) |>
  lapply(function(g) sample_n_from(g, TRAP_CAP)) |>
  bind_rows()

remaining_budget <- N_TOTAL - nrow(trap_pick)
ordinary_pool <- strings |> filter(!case_id %in% trap_pick$case_id)

cells <- ordinary_pool |>
  count(band, reg_str, text_form, name = "pop") |>
  mutate(
    weight = sqrt(pop),
    alloc  = pmax(pmin(pop, CELL_FLOOR), round(weight / sum(weight) * remaining_budget))
  )

# Rounding and the floor both perturb the total, so walk it back to the budget
# one case at a time: trim the largest cell, top up the smallest. Bounded by
# the floor below and the cell population above, and it terminates because
# every iteration moves the total one step toward the budget or finds no legal
# move and stops.
adjust_to_budget <- function(cells, budget) {
  repeat {
    drift <- sum(cells$alloc) - budget
    if (drift == 0L) break
    step <- if (drift > 0L) -1L else 1L
    floor_by_cell <- pmin(cells$pop, CELL_FLOOR)
    movable <- if (step < 0L) cells$alloc > floor_by_cell else cells$alloc < cells$pop
    if (!any(movable)) break
    idx <- which(movable)
    j <- if (step < 0L) idx[which.max(cells$alloc[idx])] else idx[which.min(cells$alloc[idx])]
    cells$alloc[[j]] <- cells$alloc[[j]] + step
  }
  cells
}
cells <- adjust_to_budget(cells, remaining_budget)

ordinary_pick <- ordinary_pool |>
  inner_join(cells |> select(band, reg_str, text_form, alloc), by = c("band", "reg_str", "text_form")) |>
  group_split(band, reg_str, text_form) |>
  lapply(function(g) sample_n_from(g, g$alloc[[1L]])) |>
  bind_rows() |>
  select(-alloc)

gold <- bind_rows(trap_pick, ordinary_pick) |> arrange(case_id)

# ── Split ─────────────────────────────────────────────────────────────────────
# Stratified 400/600 within every stratum, so the held-out set is
# distributionally identical to the adjudicated one. A held-out gate only means
# something if the two halves are comparable.

gold <- gold |>
  group_by(band, reg_str, text_form, trap) |>
  mutate(
    .u    = runif(n()),
    split = if_else(rank(.u, ties.method = "first") <= ceiling(n() * N_ROUND1 / N_TOTAL),
                    "round1", "heldout")
  ) |>
  ungroup() |>
  select(-.u)

readj_ids <- gold |>
  filter(split == "round1") |>
  group_by(band, reg_str, text_form) |>
  group_split() |>
  lapply(function(g) sample_n_from(g, max(1L, round(nrow(g) * READJ_FRAC)))) |>
  bind_rows() |>
  pull(case_id)

gold <- gold |> mutate(readjudicate = case_id %in% readj_ids)

# ── Report ────────────────────────────────────────────────────────────────────

cat(sprintf("seed %d | population %d distinct strings | sampled %d\n",
            SEED, nrow(strings), nrow(gold)))
cat(sprintf("  round1 %d | heldout %d | re-adjudication subsample %d\n",
            sum(gold$split == "round1"), sum(gold$split == "heldout"), sum(gold$readjudicate)))
cat("\nadversarial families (population -> sampled):\n")
print(as.data.frame(
  full_join(count(trap_pool, trap, name = "pop"), count(trap_pick, trap, name = "sampled"), by = "trap")
))
cat("\nband x register x text_form (population -> sampled):\n")
print(as.data.frame(
  full_join(cells |> select(band, reg_str, text_form, pop),
            count(ordinary_pick, band, reg_str, text_form, name = "sampled"),
            by = c("band", "reg_str", "text_form")) |>
    arrange(band, reg_str, text_form)
))
cat("\ntype prior in sample:\n"); print(table(gold$type_prior))

if (dry_run) {
  cat("\n--dry-run: no fixtures written.\n")
  quit(status = 0L)
}

# ── Freeze ────────────────────────────────────────────────────────────────────

dir.create(fixture_dir, recursive = TRUE, showWarnings = FALSE)
p <- function(name) file.path(fixture_dir, sprintf("sponsor_gold_%s_%s.csv", VERSION, name))

existing <- Filter(file.exists, c(p("cases_round1"), p("cases_heldout"), p("sampling_key"),
                                  p("adjudication"), p("readjudication"), p("manifest")))
if (length(existing) && !force) {
  stop("Frozen fixtures already exist:\n  ", paste(basename(existing), collapse = "\n  "),
       "\nRe-running would silently move the benchmark. Pass --force if that is genuinely intended.",
       call. = FALSE)
}

# Stable bytes: fixed column order, "\n" endings, quote only where needed. The
# manifest hash is meaningless if serialisation drifts between R versions.
write_frozen <- function(d, path) {
  write_csv(d, path, na = "", eol = "\n", quote = "needed")
  path
}

# Reviewer-facing. Registry context is fair (it helps disambiguate); anything
# derived from a model or a rule is not.
blind_cols <- function(d) d |> select(case_id, raw_sponsor, n_trials, registers, countries)

cases_round1  <- gold |> filter(split == "round1")  |> blind_cols()
cases_heldout <- gold |> filter(split == "heldout") |> blind_cols()

adjudication <- cases_round1 |>
  mutate(
    expected_canonical = NA_character_,  # the organisation, as it should appear in the app
    expected_parent    = NA_character_,  # empty unless the org rolls up to a group
    expected_type      = NA_character_,  # industry|academic|hospital|cooperative_group|foundation|public_body|charity|network|individual|unknown
    language_iso       = NA_character_,  # ISO 639-1, or "und" when undetermined
    verdict            = NA_character_,  # resolvable|unresolvable|not_an_organisation
    adjudicator        = NA_character_,
    notes              = NA_character_
  )

readjudication <- adjudication |> filter(case_id %in% readj_ids)

sampling_key <- gold |>
  select(case_id, rank, n_trials, band, reg_str, text_form, type_prior, trap, split, readjudicate)

written <- c(
  write_frozen(cases_round1,   p("cases_round1")),
  write_frozen(cases_heldout,  p("cases_heldout")),
  write_frozen(adjudication,   p("adjudication")),
  write_frozen(readjudication, p("readjudication")),
  write_frozen(sampling_key,   p("sampling_key"))
)

manifest <- tibble::tibble(
  file    = basename(written),
  sha256  = vapply(written, function(f) {
    con <- file(f, "rb"); on.exit(close(con), add = TRUE)
    as.character(openssl::sha256(con))
  }, character(1)),
  n_rows  = vapply(written, function(f) nrow(read_csv(f, show_col_types = FALSE, progress = FALSE)), integer(1)),
  seed    = SEED,
  built   = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
)
write_frozen(manifest, p("manifest"))

cat("\nfrozen:\n")
for (i in seq_len(nrow(manifest))) {
  cat(sprintf("  %-40s %s  %d rows\n", manifest$file[[i]], substr(manifest$sha256[[i]], 1L, 12L), manifest$n_rows[[i]]))
}
cat(sprintf("  %-40s (manifest)\n", basename(p("manifest"))))
cat("\nAdjudicate: ", basename(p("adjudication")), "\n", sep = "")
cat("Do NOT open the sampling key while adjudicating — it carries the strata.\n")
