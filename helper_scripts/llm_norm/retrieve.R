# Retrieval for entity normalisation. Makes NO decisions — it proposes
# candidates and the model chooses.
#
# NO JARO-WINKLER. It is not merely weak here, it is structurally wrong: JW
# weights a shared prefix heavily, so "Universität Basel" and
# "Universitätsspital Basel" score near-identical — exactly the
# University != University Hospital rule the pipeline is supposed to enforce.
# The old matcher accepted at JW >= 0.92 and auto-collapsed at >= 0.985, and
# PLANS/normalisation-llm-resolver.md records 87 live false positives from it.
#
# Three channels replace it:
#
#   1 exact       cleaned-form equality — free, high precision
#   2 token_idf   IDF-weighted token overlap — the workhorse
#   3 structured  shared businessKey / email domain / postcode — non-lexical
#
# Character n-gram and acronym channels were written, tested and then dropped:
# IDF token overlap already does the grouping work, and they cost pair-graph
# time for candidates the other two mostly already found. char_ngrams() and
# acronym_of() are kept below because the index builder still uses them for
# diagnostics and they are cheap to re-enable, but no channel calls them.
#
# THE DUAL FOLD. EUCTR ingestion DELETES non-ASCII rather than transliterating:
# "Abteilung für Anästhesie" is stored as "Abteilung fr Ansthesie", and all
# 14,285 distinct EUCTR strings are pure ASCII while CTIS keeps its diacritics.
# Verified: the deleted form appears verbatim in the corpus, the transliterated
# form does not, and normalising both sides by deletion triples cross-register
# collisions where transliteration barely moves them.
#
# So the standard Latin-ASCII fold is the WRONG fold for this corpus. It maps
# CTIS "Universitätsklinikum" to "universitatsklinikum" and EUCTR
# "Universittsklinikum" to "universittsklinikum" — still unequal, which is why
# clean_sponsor_alias() has never joined these pairs. Indexing BOTH folds costs
# one extra column and needs no detector: every string is indexed under its
# transliterated and its deleted form, and a hit on either is a candidate.

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(stringi)
  library(stringr)
  library(tidyr)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

# Tokens too generic to discriminate. IDF already down-weights them; dropping
# them outright also stops them generating pairs in the graph builder, which is
# the expensive part.
#
# The second group was added after measuring the corpus rather than guessing:
# they were the largest posting lists in the token index, above every real
# company name. Leaving them in meant a postings cap had to be low enough to
# exclude them, which also excluded pfizer (159), sanofi (119), roche (97) and
# novartis (87) — scattering the biggest sponsors' variants across dozens of
# blocks. Stoplisting the generics is what lets the cap be high enough to keep
# the company names.
.GENERIC_BASE <- c(
  "university", "universitat", "universite", "universita", "universitario",
  "hospital", "hospitalier", "clinic", "clinical", "klinik", "klinikum",
  "ziekenhuis", "spital", "ospedale", "hopital", "sjukhus", "szpital",
  "medical", "medicine", "medizin", "health", "healthcare", "care",
  "centre", "center", "centro", "zentrum", "institut", "institute", "instituto",
  "research", "recherche", "forschung", "science", "sciences",
  "department", "departement", "abteilung", "afdeling", "servizio", "servicio",
  "trust", "foundation", "fondation", "stichting", "fundacion", "fondazione",
  "group", "groupe", "gruppo", "national", "international", "regional",
  "the", "of", "de", "der", "die", "das", "du", "la", "le", "les", "el",
  "and", "und", "et", "en", "voor", "fur", "fr", "per", "di", "da", "do",
  "ltd", "inc", "gmbh", "plc", "llc", "sa", "bv", "nv", "ag", "as", "spa",
  "co", "kg", "kgaa", "aor", "ab", "oy", "aps", "srl", "sas", "sl", "pte",

  # Measured: the largest posting lists in this corpus, all above every real
  # company name.
  "pharmaceuticals", "pharmaceutical", "therapeutics", "pharma", "pharmaceutica",
  "nhs", "limited", "for", "hospitals", "dr", "prof", "development", "medizinische",
  "universitaire", "universitario", "universitaria", "biosciences", "bioscience",
  "sciences", "laboratories", "laboratoires", "labs", "company", "corporation",
  "services", "solutions", "holdings", "international", "europe", "global",
  "academisch", "academic", "general", "public", "civil", "civils", "regionale",
  "provinciale", "azienda", "sanitaria", "locale", "sygehus", "universitetssjukhuset"
)

# The dual fold means a string is indexed under BOTH its transliterated and its
# deleted form, so the stoplist has to cover both spellings of its own entries.
# Without this "universitat" is stoplisted but "universitt" — the EUCTR-mangled
# form, and the 6th largest posting list in the corpus — is not.
GENERIC_TOKENS <- unique(c(
  .GENERIC_BASE,
  gsub("[^a-z0-9]", "", stringi::stri_trans_general(.GENERIC_BASE, "Latin-ASCII")),
  gsub("[^\\x01-\\x7F]", "", .GENERIC_BASE, perl = TRUE),
  # The mangled forms of accented generics that appear in the corpus. They
  # cannot be derived from the ASCII base list, because the deletion happened
  # upstream to a spelling this list never contains.
  "universitt", "universittsklinikum", "universittsklinik", "universittsmedizin",
  "fundacin", "investigacin", "hpital", "hpitaux", "sant", "gnrale",
  "klinikum", "kliniken", "spitalul", "szpitala"
))

# ── Folding ───────────────────────────────────────────────────────────────────

.tidy <- function(x) {
  x <- tolower(x)
  x <- gsub("&", " and ", x, fixed = TRUE)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(gsub("[[:space:]]+", " ", x))
}

# Standard fold: accents map to their base letter. Correct for CTIS text and for
# ordinary accent variation.
fold_translit <- function(x) .tidy(stringi::stri_trans_general(x, "Latin-ASCII"))

# Corpus-specific fold: accented characters are DELETED, reproducing what EUCTR
# ingestion did. This is what makes a CTIS string match its EUCTR twin.
fold_delete <- function(x) .tidy(gsub("[^\\x01-\\x7F]", "", x, perl = TRUE))

# Both forms, deduped. Identical for pure-ASCII input, which is most of the
# corpus, so the index only grows for the strings that need it.
fold_forms <- function(x) {
  unique(c(fold_translit(x), fold_delete(x)))
}

# Adjacent content tokens are also emitted concatenated, so a company written
# with an internal space matches the same company written without one:
# "Astra Zeneca AB" and "AstraZeneca AB" share no token otherwise, and scored
# 0.48 — just under the blocking threshold — leaving two AstraZeneca strings
# stranded as singletons while a 40-member AstraZeneca block sat next to them.
# Same class as "Glaxo Smith Kline" vs "GlaxoSmithKline".
#
# Concatenation happens AFTER the stoplist, so "novartis pharma" does not
# produce "novartispharma" (pharma being generic) and the bigrams stay
# discriminative.
tokens_of <- function(folded, drop_generic = TRUE, concat_adjacent = TRUE) {
  t <- strsplit(folded, " ", fixed = TRUE)[[1L]]
  t <- t[nchar(t) >= 2L]
  if (drop_generic) t <- t[!t %in% GENERIC_TOKENS]
  out <- t
  if (concat_adjacent && length(t) >= 2L) {
    out <- c(out, paste0(t[-length(t)], t[-1L]))
  }
  unique(out)
}

char_ngrams <- function(folded, n = 4L) {
  s <- gsub(" ", "", folded, fixed = TRUE)
  if (nchar(s) < n) return(s)
  unique(substring(s, seq_len(nchar(s) - n + 1L), seq_len(nchar(s) - n + 1L) + n - 1L))
}

# Initials of content words: "universitair ziekenhuis gent" -> "uzg". Generic
# words are kept here (unlike token indexing) because they carry the initial:
# dropping "ziekenhuis" would turn UZ Gent into "ug".
acronym_of <- function(folded) {
  w <- strsplit(folded, " ", fixed = TRUE)[[1L]]
  w <- w[nchar(w) >= 2L]
  if (length(w) < 2L) return(character())
  paste(substr(w, 1L, 1L), collapse = "")
}

# ── Index ─────────────────────────────────────────────────────────────────────
# `labels` is the surface-form vocabulary: registry canonicals and every raw
# string already assigned to one. Both folds of each label are indexed.

build_index <- function(labels, ids = seq_along(labels), ngram_n = 4L) {
  stopifnot(length(labels) == length(ids))

  forms <- purrr::map(labels, fold_forms)
  df <- tibble::tibble(
    label_id = rep(ids, lengths(forms)),
    label    = rep(labels, lengths(forms)),
    form     = unlist(forms, use.names = FALSE)
  ) |>
    dplyr::distinct(label_id, form, .keep_all = TRUE)

  # Unigrams and concatenated bigrams are indexed separately: bigrams may MATCH
  # but must not count toward a string's own IDF mass. Counting them inflates
  # the score denominator and penalises every pair that does not happen to share
  # one — measured, it pushed singletons from 3,980 to 4,836.
  tl_uni <- purrr::map(df$form, tokens_of, concat_adjacent = FALSE)
  tl_all <- purrr::map(df$form, tokens_of, concat_adjacent = TRUE)
  tok <- dplyr::bind_rows(
    tibble::tibble(label_id = rep(df$label_id, lengths(tl_uni)),
                   token = unlist(tl_uni, use.names = FALSE), is_concat = FALSE),
    tibble::tibble(label_id = rep(df$label_id, lengths(tl_all)),
                   token = unlist(tl_all, use.names = FALSE), is_concat = TRUE)
  ) |>
    dplyr::group_by(label_id, token) |>
    dplyr::summarise(is_concat = all(is_concat), .groups = "drop")

  n_labels <- dplyr::n_distinct(ids)
  idf <- tok |>
    dplyr::count(token, name = "df_count") |>
    dplyr::mutate(idf = log(1 + n_labels / df_count))

  gram <- tibble::tibble(
    label_id = rep(df$label_id, lengths(gl <- purrr::map(df$form, char_ngrams, n = ngram_n))),
    gram     = unlist(gl, use.names = FALSE)
  ) |>
    dplyr::distinct()

  acr <- tibble::tibble(
    label_id = rep(df$label_id, lengths(al <- purrr::map(df$form, acronym_of))),
    acronym  = unlist(al, use.names = FALSE)
  ) |>
    dplyr::distinct()
  # A label whose own form is short is itself an acronym ("uz gent" -> "uzgent")
  acr <- dplyr::bind_rows(acr, df |>
    dplyr::filter(nchar(gsub(" ", "", form)) <= 6L) |>
    dplyr::transmute(label_id, acronym = gsub(" ", "", form))) |>
    dplyr::distinct()

  list(
    forms    = df,
    tokens   = dplyr::left_join(tok, idf, by = "token"),
    idf      = idf,
    grams    = gram,
    acronyms = acr,
    ngram_n  = ngram_n,
    n_labels = n_labels
  )
}

# ── Channels ──────────────────────────────────────────────────────────────────
# Each returns tibble(label_id, score, channel). Scores are per-channel scales,
# not comparable across channels — ranking merges by channel priority first.

ch_exact <- function(query, idx) {
  q <- fold_forms(query)
  idx$forms |>
    dplyr::filter(form %in% q) |>
    dplyr::transmute(label_id, score = 1, channel = "exact") |>
    dplyr::distinct()
}

# The workhorse. Scores by the summed IDF of shared tokens, normalised by the
# query's own IDF mass, so matching two rare tokens beats matching six common
# ones. The old containment_neighbours counted raw token hits, which valued a
# shared "hospital" as highly as a shared "erasmus".
ch_token_idf <- function(query, idx, k = 10L, min_score = 0.15) {
  qt <- unique(unlist(purrr::map(fold_forms(query), tokens_of), use.names = FALSE))
  if (!length(qt)) return(tibble::tibble())
  qi <- idx$idf |> dplyr::filter(token %in% qt)
  if (!nrow(qi)) return(tibble::tibble())
  total <- sum(qi$idf)
  if (total <= 0) return(tibble::tibble())

  idx$tokens |>
    dplyr::filter(token %in% qt) |>
    dplyr::group_by(label_id) |>
    dplyr::summarise(score = sum(idf) / total, .groups = "drop") |>
    dplyr::filter(score >= min_score) |>
    dplyr::slice_max(score, n = k, with_ties = FALSE) |>
    dplyr::mutate(channel = "token_idf")
}

# Replaces JW. Jaccard over character 4-grams: symmetric, no prefix weighting,
# and degrades gracefully on the single-character deletions the EUCTR corruption
# produces (one deleted char breaks at most n grams, not the whole comparison).
ch_ngram <- function(query, idx, k = 10L, threshold = 0.45) {
  qg <- unique(unlist(purrr::map(fold_forms(query), char_ngrams, n = idx$ngram_n),
                      use.names = FALSE))
  if (!length(qg)) return(tibble::tibble())
  sizes <- idx$grams |> dplyr::count(label_id, name = "n_target")
  idx$grams |>
    dplyr::filter(gram %in% qg) |>
    dplyr::count(label_id, name = "shared") |>
    dplyr::left_join(sizes, by = "label_id") |>
    dplyr::mutate(score = shared / (length(qg) + n_target - shared)) |>
    dplyr::filter(score >= threshold) |>
    dplyr::slice_max(score, n = k, with_ties = FALSE) |>
    dplyr::transmute(label_id, score, channel = "ngram")
}

ch_acronym <- function(query, idx, k = 10L) {
  forms <- fold_forms(query)
  qa <- unique(c(
    unlist(purrr::map(forms, acronym_of), use.names = FALSE),
    gsub(" ", "", forms[nchar(gsub(" ", "", forms)) <= 6L])
  ))
  qa <- qa[nchar(qa) >= 2L]
  if (!length(qa)) return(tibble::tibble())
  idx$acronyms |>
    dplyr::filter(acronym %in% qa) |>
    dplyr::transmute(label_id, score = 1, channel = "acronym") |>
    dplyr::distinct() |>
    utils::head(k)
}

# The only non-lexical channel, and with JW gone the main source of recall for
# strings that share no material with their match — "1. Frauenklinik der
# LMU-Innenstadt" -> "Klinikum Der Universitat Munchen AoR" is unreachable by
# any of the four above. `evidence` maps a raw string to shared keys
# (CTIS businessKey, EUCTR email domain, postcode); two strings under one key
# are near-certainly one organisation whatever they look like.
ch_structured <- function(query, idx, evidence, k = 10L) {
  if (is.null(evidence) || !nrow(evidence)) return(tibble::tibble())
  keys <- evidence$evidence_key[evidence$raw == query]
  if (!length(keys)) return(tibble::tibble())
  evidence |>
    dplyr::filter(evidence_key %in% keys, raw != query) |>
    dplyr::inner_join(idx$forms |> dplyr::distinct(label_id, label),
                      by = c("raw" = "label")) |>
    dplyr::transmute(label_id, score = 1, channel = "structured") |>
    dplyr::distinct() |>
    utils::head(k)
}

# ── Combined retrieval ────────────────────────────────────────────────────────
# Channel priority, not score comparison: exact and structured are evidence,
# token overlap is strong, n-gram and acronym are suggestive. Ranking by a
# blended score would let a 0.9 n-gram outrank a shared businessKey.

CHANNEL_RANK <- c(exact = 1L, structured = 2L, token_idf = 3L, ngram = 4L, acronym = 5L)

retrieve <- function(query, idx, evidence = NULL, k = 10L, extra_channels = FALSE) {
  hits <- dplyr::bind_rows(
    ch_exact(query, idx),
    ch_structured(query, idx, evidence),
    ch_token_idf(query, idx, k = k),
    # Off by default. Kept behind a flag so the per-channel recall report can
    # measure what dropping them actually cost rather than assuming nothing.
    if (extra_channels) ch_ngram(query, idx, k = k),
    if (extra_channels) ch_acronym(query, idx, k = k)
  )
  if (!nrow(hits)) return(tibble::tibble(label_id = integer(), label = character(),
                                         score = numeric(), channel = character()))
  hits |>
    dplyr::mutate(rank = CHANNEL_RANK[channel] %||% 9L) |>
    dplyr::arrange(rank, dplyr::desc(score)) |>
    dplyr::distinct(label_id, .keep_all = TRUE) |>
    utils::head(k) |>
    dplyr::left_join(idx$forms |> dplyr::distinct(label_id, label), by = "label_id") |>
    dplyr::select(label_id, label, score, channel)
}

# ── Pair graph ────────────────────────────────────────────────────────────────
# Pass A needs all-pairs candidates over the whole corpus, not query-time
# lookup. Generated from the inverted indexes with a postings cap: a token in
# more than MAX_POSTINGS strings would emit O(n^2) pairs and, by its own IDF,
# is not discriminative enough to be worth any of them.

MAX_POSTINGS <- 500L

# Scored pairs from the token index. Each shared token contributes its IDF, so
# a pair's weight is the IDF mass the two strings hold in common; normalising by
# the smaller string's total mass makes it a containment score, which is what
# "Novartis" vs "Novartis Pharma Services AG" needs (the short string is fully
# contained, so it should score ~1 despite the length difference).
scored_token_pairs <- function(idx, max_postings = MAX_POSTINGS) {
  counts <- idx$tokens |> dplyr::count(token, name = "n")
  keep   <- counts$token[counts$n >= 2L & counts$n <= max_postings]
  if (!length(keep)) {
    return(tibble::tibble(a = integer(), b = integer(), score = numeric(),
                          channel = character()))
  }

  mass <- idx$tokens |>
    dplyr::filter(!is_concat) |>
    dplyr::group_by(label_id) |>
    dplyr::summarise(total_idf = sum(idf), .groups = "drop")

  co <- idx$tokens |>
    dplyr::filter(token %in% keep) |>
    dplyr::group_by(token) |>
    dplyr::group_modify(~ {
      v <- sort(unique(.x$label_id))
      if (length(v) < 2L) return(tibble::tibble(a = integer(), b = integer()))
      cb <- utils::combn(v, 2L)
      tibble::tibble(a = cb[1L, ], b = cb[2L, ])
    }) |>
    dplyr::ungroup() |>
    dplyr::left_join(idx$idf, by = "token")

  co |>
    dplyr::group_by(a, b) |>
    dplyr::summarise(shared_idf = sum(idf), .groups = "drop") |>
    dplyr::left_join(mass |> dplyr::rename(a = label_id, mass_a = total_idf), by = "a") |>
    dplyr::left_join(mass |> dplyr::rename(b = label_id, mass_b = total_idf), by = "b") |>
    dplyr::mutate(score = shared_idf / pmax(pmin(mass_a, mass_b), 1e-9)) |>
    dplyr::transmute(a, b, score = pmin(score, 1), channel = "token_idf")
}

pairs_from_postings <- function(idx_tbl, key_col, label_col = "label_id",
                                max_postings = MAX_POSTINGS, channel = "token_idf") {
  counts <- idx_tbl |> dplyr::count(.data[[key_col]], name = "n")
  keep   <- counts[[key_col]][counts$n >= 2L & counts$n <= max_postings]
  if (!length(keep)) return(tibble::tibble(a = integer(), b = integer(), channel = character()))

  idx_tbl |>
    dplyr::filter(.data[[key_col]] %in% keep) |>
    dplyr::group_by(.data[[key_col]]) |>
    dplyr::group_modify(~ {
      v <- sort(unique(.x[[label_col]]))
      if (length(v) < 2L) return(tibble::tibble(a = integer(), b = integer()))
      cb <- utils::combn(v, 2L)
      tibble::tibble(a = cb[1L, ], b = cb[2L, ])
    }) |>
    dplyr::ungroup() |>
    dplyr::transmute(a, b, channel = channel) |>
    dplyr::distinct()
}

build_pair_graph <- function(idx, evidence = NULL,
                             ngram_min_shared = 6L,
                             max_postings = MAX_POSTINGS,
                             extra_channels = FALSE) {
  token_pairs <- scored_token_pairs(idx, max_postings = max_postings)

  # n-gram and acronym pairs are off by default: the n-gram index is an order of
  # magnitude denser than the token index and dominates graph-build time, for
  # pairs token overlap has almost always already produced. Enable to measure.
  empty_pairs <- tibble::tibble(a = integer(), b = integer(), score = numeric(),
                                channel = character())
  acr_pairs <- if (extra_channels) {
    pairs_from_postings(idx$acronyms, "acronym", max_postings = max_postings,
                        channel = "acronym")
  } else empty_pairs
  gram_pairs <- if (extra_channels) {
    pairs_from_postings(idx$grams, "gram", max_postings = 20L, channel = "ngram") |>
      dplyr::count(a, b, name = "shared") |>
      dplyr::filter(shared >= ngram_min_shared) |>
      dplyr::transmute(a, b, score = 0.7, channel = "ngram")
  } else empty_pairs

  struct_pairs <- if (!is.null(evidence) && nrow(evidence)) {
    ev <- evidence |>
      dplyr::inner_join(idx$forms |> dplyr::distinct(label_id, label),
                        by = c("raw" = "label")) |>
      dplyr::select(evidence_key, label_id)
    pairs_from_postings(ev, "evidence_key", max_postings = max_postings,
                        channel = "structured") |>
      dplyr::mutate(score = 1)
  } else {
    tibble::tibble(a = integer(), b = integer(), channel = character())
  }

  dplyr::bind_rows(token_pairs, acr_pairs, gram_pairs, struct_pairs) |>
    dplyr::filter(a != b) |>
    dplyr::group_by(a, b) |>
    dplyr::slice_max(score, n = 1L, with_ties = FALSE) |>
    dplyr::ungroup()
}

# ── Blocking ──────────────────────────────────────────────────────────────────
# Greedy canopy, NOT connected components.
#
# Connected components was tried first and failed badly: transitive closure
# (A~B, B~C => one block) collapsed 11,838 of 16,594 strings into a single
# component, and chunking that produced blocks like
# "Novartis / AstraZeneca / Novo Nordisk / Roche / AP-HP" — the highest-impact
# strings with nothing whatever in common. A block like that asks the model to
# cluster 40 unrelated organisations and costs a request to learn nothing.
#
# Canopy never chains. Each block is seeded by one string and admits only
# strings similar TO THE SEED above a threshold, so membership is a direct
# statement about the seed rather than a path through the graph. Seeds are taken
# in descending trial impact, so the highest-value strings get the cleanest
# blocks.
canopy_blocks <- function(pairs, n_nodes, weights = NULL,
                          threshold = 0.5, max_block = 40L) {
  if (is.null(weights)) weights <- rep(1, n_nodes)
  strong <- pairs[pairs$score >= threshold, , drop = FALSE]

  # Adjacency as a lookup keyed by node, built once.
  adj <- dplyr::bind_rows(
    strong |> dplyr::transmute(from = a, to = b, score),
    strong |> dplyr::transmute(from = b, to = a, score)
  ) |>
    dplyr::arrange(from, dplyr::desc(score))
  adj_split <- split(adj, adj$from)

  block <- rep(NA_integer_, n_nodes)
  order_seeds <- order(-weights)
  nb <- 0L
  for (seed in order_seeds) {
    if (!is.na(block[[seed]])) next
    nb <- nb + 1L
    block[[seed]] <- nb
    nbrs <- adj_split[[as.character(seed)]]
    if (!is.null(nbrs) && nrow(nbrs)) {
      cand <- nbrs$to[is.na(block[nbrs$to])]
      if (length(cand) > max_block - 1L) cand <- cand[seq_len(max_block - 1L)]
      block[cand] <- nb
    }
  }
  block
}

# Connected components. Retained because pass D's merge sweep genuinely wants
# transitive closure over a much sparser, higher-confidence graph — the property
# that makes it wrong for blocking is what makes it right there.
# Union-find rather than a graph package: the project rule is not to add a
# dependency without asking.
components_of <- function(pairs, n_nodes) {
  parent <- seq_len(n_nodes)
  # `<<-` inside find() reaches this function's `parent`; the same operator in
  # the loop below would reach past it to the global environment, so the union
  # step uses a plain assignment.
  find <- function(i) {
    while (parent[i] != i) {
      parent[i] <<- parent[parent[i]]   # path compression
      i <- parent[i]
    }
    i
  }
  for (r in seq_len(nrow(pairs))) {
    ra <- find(pairs$a[[r]])
    rb <- find(pairs$b[[r]])
    if (ra != rb) parent[rb] <- ra
  }
  vapply(seq_len(n_nodes), find, integer(1))
}
