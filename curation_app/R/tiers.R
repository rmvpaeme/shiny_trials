# Tier definitions — each is a backlog of rows needing human verification,
# normalised to a common shape so one review module can drive all of them.
#
# Every tier's load() returns a tibble with at least:
#   row_key   stable identifier used as the ledger key
#   raw       the string as it appears in the source data
#   proposed  the normalisation currently claimed for it
#   impact    trials / occurrences affected (drives review order)
# plus any columns named in `evidence` (shown read-only) and `extra_fields`
# (shown editable).

DOMAIN_SPONSOR   <- "sponsor"
DOMAIN_SUBSTANCE <- "substance"

cfg_path <- function(root, ...) file.path(root, "config", ...)
data_path <- function(root, ...) file.path(root, "data", ...)

read_csv_quiet <- function(path, ...) {
  readr::read_csv(path, show_col_types = FALSE, progress = FALSE, ...)
}

# ── canonical name pools (for the proposed-value dropdown) ────────────────────

# Both pools are large (~8.3k sponsors, ~17.6k substances), so the selectize
# inputs that use them must run with server = TRUE.
canonical_pool <- function(root, domain) {
  if (identical(domain, DOMAIN_SPONSOR)) {
    a <- read_csv_quiet(cfg_path(root, "sponsor_norm_pipeline", "manual_sponsor_aliases.csv"))
    b <- read_csv_quiet(cfg_path(root, "sponsor_norm_pipeline", "sponsor_llm_reviewed.csv"))
    pool <- c(a$sponsor_clean, b$sponsor_clean)
  } else {
    a <- read_csv_quiet(cfg_path(root, "substance_norm_pipeline", "canonical_substances.csv"))
    b <- read_csv_quiet(cfg_path(root, "substance_norm_pipeline", "substance_alias_index.csv"))
    pool <- c(a$substance_clean, b$substance_clean)
  }
  pool <- unique(pool[!is.na(pool) & nzchar(pool)])
  sort(pool)
}

# ── tier loaders ──────────────────────────────────────────────────────────────

load_sponsor_queue <- function(root) {
  p <- cfg_path(root, "sponsor_norm_pipeline", "sponsor_review_queue.csv")
  read_csv_quiet(p) |>
    dplyr::mutate(
      row_key  = raw_sponsor,
      raw      = raw_sponsor,
      proposed = candidate_sponsor,
      impact   = dplyr::coalesce(as.numeric(n_trials), 0)
    ) |>
    dplyr::arrange(dplyr::desc(impact))
}

load_substance_queue <- function(root) {
  p <- cfg_path(root, "substance_norm_pipeline", "substance_review_queue.csv")
  read_csv_quiet(p) |>
    dplyr::mutate(
      row_key  = raw_substance,
      raw      = raw_substance,
      proposed = active_substance_clean,
      impact   = dplyr::coalesce(as.numeric(n_occurrences), 0)
    ) |>
    dplyr::arrange(dplyr::desc(impact))
}

# Aliases the LLM curation pass wrote. These claim confidence_prior 1 and rank
# top of the priority order, but no human has ever checked them.
load_sponsor_aliases <- function(root) {
  p   <- cfg_path(root, "sponsor_norm_pipeline", "manual_sponsor_aliases.csv")
  d   <- read_csv_quiet(p) |> dplyr::filter(source == "llm_curated")
  log_p <- data_path(root, "sponsor_normalisation_log.csv")
  impact <- if (file.exists(log_p)) {
    read_csv_quiet(log_p) |>
      dplyr::mutate(alias_clean = tolower(trimws(raw_sponsor))) |>
      dplyr::group_by(alias_clean) |>
      dplyr::summarise(impact = sum(as.numeric(n_trials), na.rm = TRUE), .groups = "drop")
  } else {
    tibble::tibble(alias_clean = character(), impact = numeric())
  }
  d |>
    dplyr::left_join(impact, by = "alias_clean") |>
    dplyr::mutate(
      row_key  = alias_clean,
      raw      = alias_clean,
      proposed = sponsor_clean,
      impact   = dplyr::coalesce(impact, 0)
    ) |>
    dplyr::arrange(dplyr::desc(impact), raw)
}

load_substance_aliases <- function(root) {
  p <- cfg_path(root, "substance_norm_pipeline", "manual_brand_to_substance.csv")
  d <- read_csv_quiet(p) |> dplyr::filter(source == "llm_curated")
  log_p <- data_path(root, "substance_normalisation_log.csv")
  impact <- if (file.exists(log_p)) {
    read_csv_quiet(log_p) |>
      dplyr::mutate(alias_clean = tolower(trimws(raw_substance))) |>
      dplyr::count(alias_clean, name = "impact")
  } else {
    tibble::tibble(alias_clean = character(), impact = numeric())
  }
  d |>
    dplyr::left_join(impact, by = "alias_clean") |>
    dplyr::mutate(
      row_key  = alias_clean,
      raw      = alias_clean,
      proposed = substance_clean,
      impact   = dplyr::coalesce(impact, 0)
    ) |>
    dplyr::arrange(dplyr::desc(impact), raw)
}

load_substance_canonicals <- function(root) {
  p <- cfg_path(root, "substance_norm_pipeline", "canonical_substances.csv")
  read_csv_quiet(p) |>
    dplyr::filter(source == "llm_curated") |>
    dplyr::mutate(
      row_key  = substance_clean,
      raw      = substance_clean,
      proposed = parent_substance,
      impact   = 0
    ) |>
    dplyr::arrange(raw)
}

# Fuzzy matches the queue never shows: singletons dropped by the
# n_occurrences >= 2 filter in build_substance_labels.R. All score 80-84 JW and
# spot-checking suggests most are wrong, so they are worth a low-priority pass.
load_fuzzy_singletons <- function(root) {
  log_p <- data_path(root, "substance_normalisation_log.csv")
  if (!file.exists(log_p)) return(empty_tier_rows())
  queued <- read_csv_quiet(
    cfg_path(root, "substance_norm_pipeline", "substance_review_queue.csv")
  )$raw_substance
  read_csv_quiet(log_p) |>
    dplyr::filter(grepl("^fuzzy", match_source), !raw_substance %in% queued) |>
    dplyr::distinct(raw_substance, active_substance_clean, match_status,
                    match_score, match_source, match_reason) |>
    dplyr::mutate(
      row_key  = raw_substance,
      raw      = raw_substance,
      proposed = active_substance_clean,
      impact   = 0
    ) |>
    dplyr::arrange(match_score, raw)
}

empty_tier_rows <- function() {
  tibble::tibble(row_key = character(), raw = character(),
                 proposed = character(), impact = numeric())
}

# ── tier registry ─────────────────────────────────────────────────────────────

TIERS <- list(
  sponsor_queue = list(
    id = "sponsor_queue", label = "Sponsor queue", domain = DOMAIN_SPONSOR,
    loader = load_sponsor_queue,
    source_file = "config/sponsor_norm_pipeline/sponsor_review_queue.csv",
    evidence = c("match_status", "match_score", "match_source", "match_reason", "n_trials"),
    extra_fields = c("sponsor_type"),
    impact_label = "trials",
    queue = list(key_col = "raw_sponsor", canonical_col = "canonical_sponsor")
  ),
  substance_queue = list(
    id = "substance_queue", label = "Substance queue", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_queue,
    source_file = "config/substance_norm_pipeline/substance_review_queue.csv",
    evidence = c("match_status", "match_score", "match_source", "match_reason", "n_occurrences"),
    extra_fields = character(),
    impact_label = "occurrences",
    queue = list(key_col = "raw_substance", canonical_col = "canonical_substance")
  ),
  sponsor_aliases = list(
    id = "sponsor_aliases", label = "Sponsor LLM aliases", domain = DOMAIN_SPONSOR,
    loader = load_sponsor_aliases,
    source_file = "config/sponsor_norm_pipeline/manual_sponsor_aliases.csv",
    evidence = c("source", "confidence_prior", "sponsor_parent", "sponsor_group"),
    extra_fields = c("sponsor_type", "sponsor_parent", "sponsor_group"),
    impact_label = "trials",
    queue = NULL
  ),
  substance_aliases = list(
    id = "substance_aliases", label = "Substance LLM aliases", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_aliases,
    source_file = "config/substance_norm_pipeline/manual_brand_to_substance.csv",
    evidence = c("source", "alias_type", "confidence_prior"),
    extra_fields = c("alias_type"),
    impact_label = "occurrences",
    queue = NULL
  ),
  substance_canonicals = list(
    id = "substance_canonicals", label = "Substance canonicals", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_canonicals,
    source_file = "config/substance_norm_pipeline/canonical_substances.csv",
    evidence = c("substance_type", "source"),
    extra_fields = c("substance_type"),
    impact_label = "",
    queue = NULL
  ),
  fuzzy_singletons = list(
    id = "fuzzy_singletons", label = "Fuzzy singletons", domain = DOMAIN_SUBSTANCE,
    loader = load_fuzzy_singletons,
    source_file = "data/substance_normalisation_log.csv",
    evidence = c("match_status", "match_score", "match_source", "match_reason"),
    extra_fields = character(),
    impact_label = "",
    queue = NULL
  )
)

# Other aliases pointing at the same canonical — the context that makes a wrong
# canonical obvious, and the piece the CLI curation loop never showed.
sibling_aliases <- function(root, domain, canonical, exclude_alias, limit = 12L) {
  if (is.null(canonical) || is.na(canonical) || !nzchar(canonical)) return(character())
  path <- if (identical(domain, DOMAIN_SPONSOR)) {
    cfg_path(root, "sponsor_norm_pipeline", "sponsor_alias_index.csv")
  } else {
    cfg_path(root, "substance_norm_pipeline", "substance_alias_index.csv")
  }
  if (!file.exists(path)) return(character())
  idx <- read_csv_quiet(path)
  col <- if (identical(domain, DOMAIN_SPONSOR)) "sponsor_clean" else "substance_clean"
  hits <- idx$alias_clean[!is.na(idx[[col]]) & idx[[col]] == canonical]
  hits <- setdiff(unique(hits), exclude_alias)
  utils::head(hits, limit)
}
