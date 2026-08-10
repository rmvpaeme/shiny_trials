# The frozen-decision corpus: every (raw, final) pair the committed config
# still contains. Shared by mine_removals.R and replay.R so both measure the
# same thing.
#
# Every pair here is a decision that was made once and then frozen — mostly by
# an LLM curation pass. The derivation rules are judged against it, which means
# "agree" is "reproduces the decision", NOT "is correct". See the caveat in
# PLANS/normalisation-reproducibility.md.
#
# Reads committed config only: no database, no data/ files, no network.

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(tibble)
})

# Rows carrying registry provenance (EMA, ROR, ChEMBL) are not LLM decisions and
# are not what the derivation layer is trying to replace, so they are excluded.
.llm_sponsor_sources   <- c("llm_curated", "llm_reviewed", "review_queue")
.llm_substance_sources <- c("llm_curated", "llm_reviewed")

load_sponsor_corpus <- function(project_root = ".") {
  config_dir <- file.path(project_root, "config", "sponsor_norm_pipeline")
  source(
    file.path(project_root, "helper_scripts", "sponsor_norm_pipeline",
              "normalise_sponsors.R"),
    local = FALSE
  )

  index <- readr::read_csv(
    file.path(config_dir, "2_sponsor_alias_index.csv"),
    show_col_types = FALSE
  )

  index |>
    dplyr::filter(
      source %in% .llm_sponsor_sources,
      !is.na(alias_clean), !is.na(sponsor_clean),
      nzchar(alias_clean), nzchar(sponsor_clean)
    ) |>
    dplyr::transmute(
      raw        = alias_clean,
      final      = sponsor_clean,
      raw_clean  = clean_sponsor_alias(alias_clean),
      final_clean = clean_sponsor_alias(sponsor_clean),
      source
    ) |>
    dplyr::filter(nzchar(raw_clean), nzchar(final_clean)) |>
    dplyr::distinct(raw_clean, final_clean, .keep_all = TRUE)
}

load_substance_corpus <- function(project_root = ".") {
  config_dir <- file.path(project_root, "config", "substance_norm_pipeline")
  source(
    file.path(project_root, "helper_scripts", "substance_norm_pipeline",
              "normalise_substances.R"),
    local = FALSE
  )

  index <- readr::read_csv(
    file.path(config_dir, "2_substance_alias_index.csv"),
    show_col_types = FALSE
  )
  overrides <- readr::read_csv(
    file.path(config_dir, "substance_llm_overrides.csv"),
    show_col_types = FALSE
  )

  from_index <- index |>
    dplyr::filter(
      source %in% .llm_substance_sources,
      !is.na(alias_clean), !is.na(substance_clean)
    ) |>
    dplyr::transmute(raw = alias_clean, final = substance_clean, source)

  from_overrides <- overrides |>
    dplyr::filter(
      match_status == "accepted",
      !is.na(raw_clean), !is.na(substance_clean)
    ) |>
    dplyr::transmute(raw = raw_clean, final = substance_clean,
                     source = "llm_override")

  dplyr::bind_rows(from_index, from_overrides) |>
    dplyr::transmute(
      raw, final, source,
      raw_clean   = clean_alias(raw),
      final_clean = clean_alias(final)
    ) |>
    dplyr::filter(nzchar(raw_clean), nzchar(final_clean)) |>
    dplyr::distinct(raw_clean, final_clean, .keep_all = TRUE)
}

# ── pair classification ───────────────────────────────────────────────────────
#
# How a (raw, final) pair differs, by token sequence. "removal" and "identical"
# are the mineable pairs — a rule can reproduce them from the input alone.
# "substitution" is entity resolution, where the output shares no material with
# the input, and no rule will ever recover it.

is_subsequence <- function(needle, haystack) {
  if (length(needle) > length(haystack)) return(FALSE)
  i <- 1L
  for (tok in haystack) {
    if (i > length(needle)) break
    if (identical(tok, needle[[i]])) i <- i + 1L
  }
  i > length(needle)
}

classify_pair <- function(raw_tokens, final_tokens) {
  if (identical(raw_tokens, final_tokens)) return("identical")
  if (length(final_tokens) == 0L || length(raw_tokens) == 0L) return("substitution")
  if (is_subsequence(final_tokens, raw_tokens)) return("removal")
  if (is_subsequence(raw_tokens, final_tokens)) return("addition")
  "substitution"
}

classify_pairs <- function(pairs) {
  purrr::map2_chr(
    stringr::str_split(pairs$raw_clean, "\\s+"),
    stringr::str_split(pairs$final_clean, "\\s+"),
    classify_pair
  )
}

# Deterministic held-out split. Hashing the raw string rather than sampling
# means the split does not depend on RNG state or on row order, so the
# held-out numbers in the committed report are reproducible.
#
# The modulus is small enough that every intermediate stays exactly
# representable as a double — an FNV-style 32-bit hash silently loses precision
# in R and returns NA.
held_out_mask <- function(raw_clean, fraction = 0.10) {
  modulus <- 1000003
  digits <- vapply(
    raw_clean,
    function(s) {
      h <- 7
      for (b in utf8ToInt(s)) h <- (h * 31 + b) %% modulus
      h / modulus
    },
    numeric(1),
    USE.NAMES = FALSE
  )
  digits < fraction
}
