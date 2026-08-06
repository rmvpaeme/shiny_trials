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

# Controlled vocabularies for the classification fields. Taken from the values
# actually present in the config, so a reviewer picks from the existing
# vocabulary instead of inventing a synonym by typing. `create = FALSE` on
# these inputs is the point — free text here is how "hospital" and "Hospital"
# end up as different types.
FIELD_CHOICES <- list(
  sponsor_type = c("industry", "hospital", "academic", "cooperative_group",
                   "foundation", "public_body", "charity", "person", "unknown"),
  alias_type   = c("manual_brand", "epar_brand", "combination_brand", "inn",
                   "salt_hydrate_resolution", "chembl_conflict_resolved"),
  substance_type = c("inn", "salt")
)

# sponsor_parent / sponsor_group are canonical sponsor names, not a fixed
# vocabulary, so they stay selectize-over-the-canonical-pool instead.
POOL_FIELDS <- c("sponsor_parent", "sponsor_group")

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
# The alias indexes are large (13k sponsor / 111k substance rows) and the
# sibling lookup runs on every row change, so parse each one once per session.
.alias_index_cache <- new.env(parent = emptyenv())

alias_index <- function(root, domain) {
  if (!is.null(.alias_index_cache[[domain]])) return(.alias_index_cache[[domain]])
  path <- if (identical(domain, DOMAIN_SPONSOR)) {
    cfg_path(root, "sponsor_norm_pipeline", "sponsor_alias_index.csv")
  } else {
    cfg_path(root, "substance_norm_pipeline", "substance_alias_index.csv")
  }
  col <- if (identical(domain, DOMAIN_SPONSOR)) "sponsor_clean" else "substance_clean"
  idx <- if (file.exists(path)) {
    read_csv_quiet(path) |>
      dplyr::select(alias_clean, canonical = dplyr::all_of(col), source)
  } else {
    tibble::tibble(alias_clean = character(), canonical = character(),
                   source = character())
  }
  .alias_index_cache[[domain]] <- idx
  idx
}

# ── trial references ──────────────────────────────────────────────────────────
#
# Which registered trials a raw string actually came from. This is what settles
# an ambiguous name: "UCL" appears on four trials, all of them -GB, so it is
# University College London and not Université catholique de Louvain (-BE).
#
# `_id` is a EudraCT number plus a country code for EUCTR (2012-005394-31-GB),
# or a CTIS trial number ending in digits (2022-500007-52-00). URL shapes are
# the same ones app.R:3721-3724 uses.

.raw_pairs_cache <- new.env(parent = emptyenv())

raw_pairs <- function(root, domain) {
  if (!is.null(.raw_pairs_cache[[domain]])) return(.raw_pairs_cache[[domain]])
  file <- if (identical(domain, DOMAIN_SPONSOR)) "trial_sponsors_raw.csv" else "trial_substances_raw.csv"
  col  <- if (identical(domain, DOMAIN_SPONSOR)) "raw_sponsor" else "raw_substance"
  path <- data_path(root, file)
  out <- if (file.exists(path)) {
    read_csv_quiet(path) |>
      dplyr::select(id = `_id`, raw_value = dplyr::all_of(col)) |>
      dplyr::distinct() |>
      dplyr::mutate(raw_key = tolower(trimws(raw_value)))
  } else {
    tibble::tibble(id = character(), raw_value = character(), raw_key = character())
  }
  .raw_pairs_cache[[domain]] <- out
  out
}

is_ctis_id <- function(id) !grepl("[A-Z]{2,3}$", id)

trial_url <- function(id) {
  ct <- sub("-[A-Z]{2,3}$", "", id)
  ifelse(
    is_ctis_id(id),
    paste0("https://euclinicaltrials.eu/ctis-public/view/", id),
    paste0("https://www.clinicaltrialsregister.eu/ctr-search/trial/", ct, "/",
           sub("^.*-([A-Z]{2,3})$", "\\1", id))
  )
}

# Alias tiers carry a cleaned alias rather than the raw string, so match on the
# raw value first and fall back to its lowercased form.
# Returns every matching trial. The caller caps how many links it renders, but
# the country summary must be computed over the full set — truncating first
# would make a sponsor spanning 12 countries look like it spans 2.
trial_references <- function(root, domain, raw_value) {
  if (is.null(raw_value) || is.na(raw_value) || !nzchar(raw_value)) {
    return(tibble::tibble(id = character(), register = character(),
                          country = character(), url = character()))
  }
  pairs <- raw_pairs(root, domain)
  hits  <- pairs[pairs$raw_value == raw_value, , drop = FALSE]
  if (!nrow(hits)) {
    hits <- pairs[pairs$raw_key == tolower(trimws(raw_value)), , drop = FALSE]
  }
  if (!nrow(hits)) {
    return(tibble::tibble(id = character(), register = character(),
                          country = character(), url = character()))
  }
  hits |>
    dplyr::distinct(id) |>
    dplyr::mutate(
      register = ifelse(is_ctis_id(id), "CTIS", "EUCTR"),
      country  = ifelse(is_ctis_id(id), NA_character_,
                        sub("^.*-([A-Z]{2,3})$", "\\1", id)),
      url      = trial_url(id)
    ) |>
    dplyr::arrange(country, id)
}

# Which file a sibling alias actually lives in, so it can be edited in place.
# Aliases from the generated tiers (EPAR, CTIS businessKey, email domain,
# ChEMBL) have no hand-editable home — they are re-derived on every rebuild, so
# detaching one there would be silently undone. Those stay read-only.
alias_home <- function(domain, source) {
  if (is.null(source) || is.na(source)) return(NULL)
  if (identical(domain, DOMAIN_SPONSOR)) {
    switch(source,
      llm_curated  = ,
      manual       = list(tier = "sponsor_aliases",
                          file = "config/sponsor_norm_pipeline/manual_sponsor_aliases.csv"),
      llm_reviewed = list(tier = "sponsor_llm_reviewed",
                          file = "config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv"),
      NULL)
  } else {
    switch(source,
      llm_curated    = ,
      manual         = list(tier = "substance_aliases",
                            file = "config/substance_norm_pipeline/manual_brand_to_substance.csv"),
      llm_reviewed   = ,
      reviewed_queue = list(tier = "substance_llm_reviewed",
                            file = "config/substance_norm_pipeline/substance_llm_reviewed.csv"),
      NULL)
  }
}

sibling_aliases <- function(root, domain, canonical, exclude_alias, limit = 12L) {
  empty <- tibble::tibble(alias_clean = character(), source = character(),
                          tier = character(), editable = logical())
  if (is.null(canonical) || is.na(canonical) || !nzchar(canonical)) return(empty)
  idx  <- alias_index(root, domain)
  hits <- idx[!is.na(idx$canonical) & idx$canonical == canonical &
                idx$alias_clean != exclude_alias, , drop = FALSE]
  if (!nrow(hits)) return(empty)
  hits |>
    dplyr::distinct(alias_clean, source) |>
    dplyr::mutate(
      tier = vapply(source, function(s) {
        h <- alias_home(domain, s)
        if (is.null(h)) NA_character_ else h$tier
      }, character(1)),
      editable = !is.na(tier)
    ) |>
    dplyr::arrange(!editable, alias_clean) |>
    utils::head(limit)
}
