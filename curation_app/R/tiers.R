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
  alias_type   = c("llm_brand", "epar_brand", "combination_brand", "inn",
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

# ── impact ────────────────────────────────────────────────────────────────────
#
# Joining a raw string to an alias_clean needs the pipeline's own cleaner, not
# tolower(trimws(x)). clean_sponsor_alias() also transliterates to ASCII,
# normalises quotes and dashes, expands "&", and turns punctuation into spaces —
# so a naive join silently misses every sponsor with a comma, period or accent.
# "Incyte Corp." (54 trials) and "Lilly S.A." (37) look like zero-impact rows
# under the naive key, which would wrongly drop them below the review threshold.

.normaliser_loaded <- new.env(parent = emptyenv())

load_normaliser <- function(root, domain) {
  if (isTRUE(.normaliser_loaded[[domain]])) return(invisible(TRUE))
  f <- if (identical(domain, DOMAIN_SPONSOR)) {
    file.path(root, "helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R")
  } else {
    file.path(root, "helper_scripts", "substance_norm_pipeline", "normalise_substances.R")
  }
  if (file.exists(f)) {
    suppressMessages(source(f, local = FALSE))
    .normaliser_loaded[[domain]] <- TRUE
  }
  invisible(TRUE)
}

impact_key <- function(root, domain, x) {
  load_normaliser(root, domain)
  fn <- if (identical(domain, DOMAIN_SPONSOR)) "clean_sponsor_alias" else "clean_alias"
  if (exists(fn, mode = "function")) {
    get(fn, mode = "function")(x)
  } else {
    tolower(trimws(x))  # only if the normaliser is unavailable
  }
}

# Trials (sponsor) or occurrences (substance) per cleaned alias.
impact_table <- function(root, domain) {
  if (identical(domain, DOMAIN_SPONSOR)) {
    p <- data_path(root, "sponsor_normalisation_log.csv")
    if (!file.exists(p)) return(tibble::tibble(alias_clean = character(), impact = numeric()))
    read_csv_quiet(p) |>
      dplyr::mutate(alias_clean = impact_key(root, domain, raw_sponsor)) |>
      dplyr::group_by(alias_clean) |>
      dplyr::summarise(impact = sum(as.numeric(n_trials), na.rm = TRUE), .groups = "drop")
  } else {
    p <- data_path(root, "substance_normalisation_log.csv")
    if (!file.exists(p)) return(tibble::tibble(alias_clean = character(), impact = numeric()))
    read_csv_quiet(p) |>
      dplyr::mutate(alias_clean = impact_key(root, domain, raw_substance)) |>
      dplyr::count(alias_clean, name = "impact")
  }
}

# ── canonical name pools (for the proposed-value dropdown) ────────────────────

# Both pools are large (~8.3k sponsors, ~17.6k substances), so the selectize
# inputs that use them must run with server = TRUE.
canonical_pool <- function(root, domain) {
  if (identical(domain, DOMAIN_SPONSOR)) {
    a <- read_csv_quiet(cfg_path(root, "sponsor_norm_pipeline", "sponsor_llm_aliases.csv"))
    b <- read_csv_quiet(cfg_path(root, "sponsor_norm_pipeline", "sponsor_llm_reviewed.csv"))
    pool <- c(a$sponsor_clean, b$sponsor_clean)
  } else {
    a <- read_csv_quiet(cfg_path(root, "substance_norm_pipeline", "canonical_substances.csv"))
    b <- read_csv_quiet(cfg_path(root, "substance_norm_pipeline", "2_substance_alias_index.csv"))
    pool <- c(a$substance_clean, b$substance_clean)
  }
  pool <- unique(pool[!is.na(pool) & nzchar(pool)])
  sort(pool)
}

# ── tier loaders ──────────────────────────────────────────────────────────────

load_sponsor_queue <- function(root) {
  p <- cfg_path(root, "sponsor_norm_pipeline", "3_sponsor_review_queue.csv")
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
  p <- cfg_path(root, "substance_norm_pipeline", "3_substance_review_queue.csv")
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
  p <- cfg_path(root, "sponsor_norm_pipeline", "sponsor_llm_aliases.csv")
  read_csv_quiet(p) |>
    dplyr::filter(source == "llm_curated") |>
    dplyr::left_join(impact_table(root, DOMAIN_SPONSOR), by = "alias_clean") |>
    dplyr::mutate(
      row_key  = alias_clean,
      raw      = alias_clean,
      proposed = sponsor_clean,
      impact   = dplyr::coalesce(impact, 0)
    ) |>
    dplyr::arrange(dplyr::desc(impact), raw)
}

load_substance_aliases <- function(root) {
  p <- cfg_path(root, "substance_norm_pipeline", "substance_llm_brands.csv")
  read_csv_quiet(p) |>
    dplyr::filter(source == "llm_curated") |>
    dplyr::left_join(impact_table(root, DOMAIN_SUBSTANCE), by = "alias_clean") |>
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
# n_occurrences >= 2 filter in 3_build_substance_labels.R. All score 80-84 JW and
# spot-checking suggests most are wrong, so they are worth a low-priority pass.
load_fuzzy_singletons <- function(root) {
  log_p <- data_path(root, "substance_normalisation_log.csv")
  if (!file.exists(log_p)) return(empty_tier_rows())
  queued <- read_csv_quiet(
    cfg_path(root, "substance_norm_pipeline", "3_substance_review_queue.csv")
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

# ── llm_reviewed tiers ────────────────────────────────────────────────────────
#
# 24,302 rows between them — far too many to review row by row, and most of it
# would be wasted effort: 4,428 sponsor rows (37%) resolve zero trials, and
# another 4,866 resolve exactly one. Rows with >= 3 trials are 1,509 of the
# sponsor tier but carry 61% of its impact, so that is the default threshold.
#
# The sub-threshold rows are not abandoned, they are *sampled* — see
# audit_sample() below. A clean sample is what makes the tail provably not
# worth reviewing; without one, "we skipped 9,000 rows" has no error bar.

load_sponsor_llm_reviewed <- function(root) {
  p <- cfg_path(root, "sponsor_norm_pipeline", "sponsor_llm_reviewed.csv")
  if (!file.exists(p)) return(empty_tier_rows())
  read_csv_quiet(p) |>
    dplyr::left_join(impact_table(root, DOMAIN_SPONSOR), by = "alias_clean") |>
    dplyr::mutate(impact = dplyr::coalesce(impact, 0),
                  row_key = alias_clean, raw = alias_clean, proposed = sponsor_clean) |>
    dplyr::arrange(dplyr::desc(impact), raw)
}

load_substance_llm_reviewed <- function(root) {
  p <- cfg_path(root, "substance_norm_pipeline", "substance_llm_reviewed.csv")
  if (!file.exists(p)) return(empty_tier_rows())
  read_csv_quiet(p) |>
    dplyr::left_join(impact_table(root, DOMAIN_SUBSTANCE), by = "alias_clean") |>
    dplyr::mutate(impact = dplyr::coalesce(impact, 0),
                  row_key = alias_clean, raw = alias_clean, proposed = substance_clean) |>
    dplyr::arrange(dplyr::desc(impact), raw)
}

# A fixed, seeded random sample of the rows the impact threshold excludes.
# Seeded on the tier id so the same rows come back every session and across
# reviewers — an audit whose sample moves is not an audit.
AUDIT_SIZE <- 200L

audit_sample <- function(rows, tier_id, min_impact, n = AUDIT_SIZE) {
  tail_rows <- rows[rows$impact < min_impact, , drop = FALSE]
  if (!nrow(tail_rows)) return(tail_rows[0, , drop = FALSE])
  seed <- sum(utf8ToInt(tier_id)) * 7919L
  withr_seed <- .Random.seed
  set.seed(seed)
  on.exit({ if (!is.null(withr_seed)) .Random.seed <<- withr_seed }, add = TRUE)
  idx <- sample.int(nrow(tail_rows), min(n, nrow(tail_rows)))
  tail_rows[sort(idx), , drop = FALSE]
}

# Wilson interval — the normal approximation misbehaves when the observed error
# rate is near 0, which is the outcome an audit is most likely to produce.
wilson_ci <- function(k, n, conf = 0.95) {
  if (n == 0) return(c(NA_real_, NA_real_))
  z <- stats::qnorm(1 - (1 - conf) / 2)
  p <- k / n
  d <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / d
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / d
  c(max(0, centre - half), min(1, centre + half))
}

# ── conflict tiers ────────────────────────────────────────────────────────────
#
# These two hold rows that are already known to be wrong, rather than merely
# unverified, which makes them the highest-value review targets in the app.

# Articles, prepositions and legal/structural suffixes only. Entity-type words
# (university, hospital, institute) are deliberately NOT stripped — they
# distinguish real entities, and removing them merges a university with its
# teaching hospital.
FRAGMENT_STOPWORDS <- c(
  "the", "of", "de", "di", "del", "della", "des", "du", "da", "el", "la", "le",
  "les", "het", "der", "den", "a", "and", "fur",
  "nhs", "trust", "foundation", "gmbh", "ag", "sa", "as", "ab", "bv", "nv",
  "srl", "spa", "inc", "ltd", "limited", "llc", "plc", "corp", "co",
  "irccs", "aor", "ev", "asbl", "vzw", "aps", "oy", "ehf"
)

fragment_key <- function(x) {
  y <- tolower(iconv(x, to = "ASCII//TRANSLIT", sub = ""))
  y <- gsub("[^a-z0-9 ]", " ", y)
  vapply(strsplit(trimws(gsub(" +", " ", y)), " "), function(t) {
    paste(sort(unique(setdiff(t, FRAGMENT_STOPWORDS))), collapse = " ")
  }, character(1))
}

# Canonicals that differ only by casing, punctuation, an article or a legal
# suffix — the same entity under several spellings, splitting its trial count.
load_sponsor_fragments <- function(root) {
  rev_p <- cfg_path(root, "sponsor_norm_pipeline", "sponsor_llm_reviewed.csv")
  if (!file.exists(rev_p)) return(empty_tier_rows())

  cw <- read_csv_quiet(rev_p) |>
    dplyr::left_join(impact_table(root, DOMAIN_SPONSOR), by = "alias_clean") |>
    dplyr::mutate(trials = dplyr::coalesce(impact, 0)) |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(trials = sum(trials), .groups = "drop") |>
    dplyr::filter(trials > 0) |>
    dplyr::mutate(fkey = fragment_key(sponsor_clean)) |>
    dplyr::filter(nzchar(fkey))

  cw |>
    dplyr::group_by(fkey) |>
    dplyr::filter(dplyr::n() > 1) |>
    dplyr::arrange(dplyr::desc(trials), .by_group = TRUE) |>
    dplyr::summarise(
      variants   = paste(sprintf("%s (%d)", sponsor_clean, as.integer(trials)),
                         collapse = "  |  "),
      n_variants = dplyr::n(),
      # Default to the highest-impact spelling; the reviewer can pick another.
      proposed   = dplyr::first(sponsor_clean),
      losing     = paste(sponsor_clean[-1], collapse = "|"),
      impact     = sum(trials),
      .groups    = "drop"
    ) |>
    dplyr::mutate(row_key = fkey, raw = variants) |>
    dplyr::arrange(dplyr::desc(impact))
}

# One raw string overridden to two different substances. The chunked LLM
# curation appended its corrections instead of replacing the original rows, so
# both the mistake and its fix are on file and the earlier one wins.
load_substance_conflicts <- function(root) {
  ov_p <- cfg_path(root, "substance_norm_pipeline", "substance_llm_overrides.csv")
  rv_p <- cfg_path(root, "substance_norm_pipeline", "substance_llm_reviewed.csv")
  if (!file.exists(ov_p)) return(empty_tier_rows())

  ov <- read_csv_quiet(ov_p) |>
    dplyr::select(alias = raw_clean, target = substance_clean, reason)
  rv <- if (file.exists(rv_p)) {
    read_csv_quiet(rv_p) |>
      dplyr::select(alias = alias_clean, target = substance_clean) |>
      dplyr::mutate(reason = NA_character_)
  } else {
    ov[0, ]
  }
  both <- dplyr::bind_rows(ov, rv) |> dplyr::distinct(alias, target, .keep_all = TRUE)

  uses <- impact_table(root, DOMAIN_SUBSTANCE) |>
    dplyr::rename(alias = alias_clean)

  both |>
    dplyr::group_by(alias) |>
    dplyr::filter(dplyr::n_distinct(target) > 1) |>
    dplyr::summarise(
      candidates = paste(unique(target), collapse = "  |  "),
      chunks     = paste(unique(stats::na.omit(reason)), collapse = "  |  "),
      # Whichever currently wins is only first-in-file, not a judgement.
      proposed   = dplyr::first(target),
      .groups    = "drop"
    ) |>
    dplyr::left_join(uses, by = "alias") |>
    dplyr::mutate(impact = dplyr::coalesce(impact, 0L),
                  row_key = alias, raw = alias) |>
    dplyr::arrange(dplyr::desc(impact))
}

# ── tier registry ─────────────────────────────────────────────────────────────

TIERS <- list(
  # Conflict tiers first — these are known-wrong rows, not merely unverified.
  sponsor_fragments = list(
    id = "sponsor_fragments", label = "Sponsor fragments", domain = DOMAIN_SPONSOR,
    loader = load_sponsor_fragments,
    source_file = "config/sponsor_norm_pipeline/final_sponsor_canonical_map.csv",
    evidence = c("variants", "n_variants"),
    extra_fields = character(),
    impact_label = "trials",
    queue = NULL
  ),
  substance_conflicts = list(
    id = "substance_conflicts", label = "Substance conflicts", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_conflicts,
    source_file = "config/substance_norm_pipeline/substance_llm_overrides.csv",
    evidence = c("candidates", "chunks"),
    extra_fields = character(),
    impact_label = "occurrences",
    queue = NULL
  ),
  sponsor_llm_reviewed = list(
    id = "sponsor_llm_reviewed", label = "Sponsor LLM-reviewed", domain = DOMAIN_SPONSOR,
    loader = load_sponsor_llm_reviewed,
    source_file = "config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv",
    evidence = c("source", "confidence_prior", "sponsor_parent", "sponsor_group"),
    extra_fields = c("sponsor_type", "sponsor_parent", "sponsor_group"),
    impact_label = "trials",
    min_impact = 3,     # 1,509 rows carrying 61% of the tier's impact
    auditable = TRUE,
    queue = NULL
  ),
  substance_llm_reviewed = list(
    id = "substance_llm_reviewed", label = "Substance LLM-reviewed", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_llm_reviewed,
    source_file = "config/substance_norm_pipeline/substance_llm_reviewed.csv",
    evidence = c("source", "alias_type", "confidence_prior"),
    extra_fields = c("alias_type"),
    impact_label = "occurrences",
    min_impact = 3,
    auditable = TRUE,
    queue = NULL
  ),
  sponsor_queue = list(
    id = "sponsor_queue", label = "Sponsor queue", domain = DOMAIN_SPONSOR,
    loader = load_sponsor_queue,
    source_file = "config/sponsor_norm_pipeline/3_sponsor_review_queue.csv",
    evidence = c("match_status", "match_score", "match_source", "match_reason", "n_trials"),
    extra_fields = c("sponsor_type"),
    impact_label = "trials",
    queue = list(key_col = "raw_sponsor", canonical_col = "canonical_sponsor")
  ),
  substance_queue = list(
    id = "substance_queue", label = "Substance queue", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_queue,
    source_file = "config/substance_norm_pipeline/3_substance_review_queue.csv",
    evidence = c("match_status", "match_score", "match_source", "match_reason", "n_occurrences"),
    extra_fields = character(),
    impact_label = "occurrences",
    queue = list(key_col = "raw_substance", canonical_col = "canonical_substance")
  ),
  sponsor_aliases = list(
    id = "sponsor_aliases", label = "Sponsor LLM aliases", domain = DOMAIN_SPONSOR,
    loader = load_sponsor_aliases,
    source_file = "config/sponsor_norm_pipeline/sponsor_llm_aliases.csv",
    evidence = c("source", "confidence_prior", "sponsor_parent", "sponsor_group"),
    extra_fields = c("sponsor_type", "sponsor_parent", "sponsor_group"),
    impact_label = "trials",
    queue = NULL
  ),
  substance_aliases = list(
    id = "substance_aliases", label = "Substance LLM aliases", domain = DOMAIN_SUBSTANCE,
    loader = load_substance_aliases,
    source_file = "config/substance_norm_pipeline/substance_llm_brands.csv",
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
    cfg_path(root, "sponsor_norm_pipeline", "2_sponsor_alias_index.csv")
  } else {
    cfg_path(root, "substance_norm_pipeline", "2_substance_alias_index.csv")
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
                          file = "config/sponsor_norm_pipeline/sponsor_llm_aliases.csv"),
      llm_reviewed = list(tier = "sponsor_llm_reviewed",
                          file = "config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv"),
      NULL)
  } else {
    switch(source,
      llm_curated    = ,
      manual         = list(tier = "substance_aliases",
                            file = "config/substance_norm_pipeline/substance_llm_brands.csv"),
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
