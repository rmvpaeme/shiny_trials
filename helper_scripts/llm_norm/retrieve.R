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
# Character n-gram and acronym channels were written, tested and then dropped
# FOR SPONSORS: IDF token overlap already does the grouping work there, and they
# cost pair-graph time for candidates the other two mostly already found.
#
# They are NOT off for substances, and the reason is worth keeping. A drug name
# is usually a single token, so token_idf has nothing to overlap: 12,610 of the
# 17,272 ChEMBL canonicals are one word. Character n-grams carry that pass
# instead, and measured on the substance vocabulary they work —
# "metotrexate" retrieves "methotrexate", "SODIO ASCORBATO" retrieves
# "ascorbato de sodio". Enable with retrieve(extra_channels = TRUE).
#
# One correction to an earlier note: PLANS/normalisation-v2-handover.md §3.8
# records ch_ngram as returning NA scores. That was measured on the sponsor
# corpus; over the substance index it returns 0 NA of 20 rows. The channel is
# sound, it was simply not earning its cost for organisation names.
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

# ── Substance stoplist ────────────────────────────────────────────────────────
# The sponsor list above is not merely useless for drugs, it is the wrong shape.
# What ruins a substance slate is units and dosage forms, and the failure is not
# hypothetical — with only the sponsor stoplist in place, three real corpus
# strings all retrieved the same wrong molecule at score 1.00:
#
#   Etomedac 20 mg                    -> mg-s-2525 [1.00]
#   Olopatadin Micro Labs 1 mg        -> mg-s-2525 [1.00]
#   Natriumklorid Fresenius Kabi 9 mg -> mg-s-2525 [1.00]
#
# The token "mg" matched a ChEMBL molecule literally named "mg-s-2525", and it
# outranked the correct "olopatadine".
#
# DELIBERATELY ABSENT: chemical words. "acid", "sodium", "chloride", "ethyl",
# "ester" and their kin look generic and are not — they are parts of INNs
# ("docosahexaenoic acid", "sodium ascorbate", "sodium chloride"). Stoplisting
# them would delete the only discriminating token those names have. This list
# holds units, dosage forms, routes, packaging and administration language only.
.SUBSTANCE_GENERIC_BASE <- c(
  # units and dose language
  "mg", "ml", "mcg", "microgram", "micrograms", "mikrogramm", "gram", "grams",
  "kg", "iu", "ui", "mbq", "gbq", "mmol", "nmol", "mol", "molar", "unit",
  "units", "dose", "doses", "dosis", "dosage", "strength", "mgml", "mgkg",
  "percent", "conc",

  # dosage forms
  "tablet", "tablets", "tabletten", "tableta", "tabletas", "comprime",
  "comprimes", "comprimido", "comprimidos", "compressa", "compresse",
  "capsule", "capsules", "kapsel", "kapseln", "capsula", "capsulas",
  "solution", "solutions", "solucion", "solucao", "soluzione", "losung",
  "losungen", "otopina", "roztwor", "solutie",
  "suspension", "suspensie", "sospensione", "emulsion", "dispersion",
  "concentrate", "concentrado", "concentrato", "konzentrat",
  "powder", "powders", "pulver", "polvo", "polvere", "poudre", "proszek",
  "granules", "granulat", "syrup", "sirup", "drops", "gouttes", "tropfen",
  "cream", "ointment", "salbe", "gel", "lotion", "foam", "patch", "patches",
  "pflaster", "implant", "depot", "spray", "aerosol", "inhaler", "inhalation",
  "nebuliser", "nebulizer", "lyophilised", "lyophilized", "lyophilisate",
  "freeze", "dried", "coated", "filmcoated", "film", "release", "modified",
  "prolonged", "extended", "immediate", "gastro", "resistant", "effervescent",
  "sterile", "injectable", "inyectable", "iniettabile",

  # routes and administration
  "injection", "injections", "injektion", "injektionslosung", "iniezione",
  "inyeccion", "injectie", "injecties", "infusion", "infusionslosung", "infusione",
  "infusie", "perfusion", "perfusao", "intravenous", "intravenoso", "iv",
  # Dutch, Nordic and Finnish dosage language. Measured on real slates: without
  # these, "ml oplossing voor injectie" retrieved Aldesleukin, Amoxicillin and
  # Amphotericin B at score 1.00 — a full slate of unrelated drugs for a string
  # that names no substance.
  "oplossing", "oplossingen", "concentraat", "poeder", "voor", "verdunning",
  "druppels", "zalf", "zetpil", "injectievloeistof", "suspensie",
  "opplosning", "injektionsvatska", "injektionsvaetska", "injeksjonsvaeske",
  "tabletter", "koncentrat", "ogondroppar", "ojendraber",
  "liuos", "injektioneste", "jauhe", "tabletti",
  "subcutaneous", "subcutane", "intramuscular", "intrathecal", "intravitreal",
  "oral", "orale", "peroral", "topical", "transdermal", "ophthalmic",
  "nasal", "rectal", "vaginal", "buccal", "sublingual", "administration",

  # packaging and presentation
  "vial", "vials", "ampoule", "ampule", "ampoules", "ampulle", "flacon",
  "syringe", "syringes", "prefilled", "pen", "autoinjector", "cartridge",
  "bag", "bottle", "sachet", "sobre", "blister", "pack", "container",

  # connective and filler language that shows up inside these strings
  "for", "and", "the", "of", "with", "in", "to", "per", "pour", "zur",
  "herstellung", "einer", "een", "van", "de", "del", "della", "di", "da",
  "use", "used", "usp", "ph", "eur", "bp", "type", "form", "product",
  "medicinal", "medicine", "drug", "substance", "active", "ingredient",
  "free", "base", "anhydrous", "hydrate",

  # Manufacturer language. A substance string routinely carries the company that
  # made it — "Olopatadin Micro Labs 1 mg", "Dexamethason 4 mg JENAPHARM",
  # "Natriumklorid Fresenius Kabi 9 mg" — and a corporate suffix is not a
  # molecule.
  #
  # HONEST NOTE ON WHAT THIS DID AND DID NOT DO: adding it changed nothing
  # measurable on a 12-case retrieval probe (11/12 with and without). It is kept
  # because the words are generic by inspection and dropping them shrinks the
  # pair graph, not because it was shown to improve a slate. Do not cite it as
  # the fix for "Olopatadin Micro Labs 1 mg" — that was a channel-ordering
  # problem, fixed in retrieve() instead.
  #
  # Generic corporate words ONLY. Company NAMES stay in: "Fresenius" and
  # "Jenapharm" are as discriminating as any other rare token, and stoplisting
  # names would be an endless list that also swallows real substances.
  "labs", "lab", "laboratories", "laboratoires", "laboratorios", "laboratorio",
  "pharma", "pharms", "pharmaceuticals", "pharmaceutical", "pharmaceutica",
  "pharmazeutika", "arzneimittel", "farma", "farmaceutica", "farmaceutici",
  "healthcare", "health", "generics", "generic", "biotech", "biosciences",
  "gmbh", "ltd", "limited", "inc", "plc", "llc", "bv", "nv", "ag", "sa",
  "spa", "srl", "sas", "sl", "aps", "kgaa", "corp", "corporation", "company",
  "international", "europe", "deutschland", "espana", "italia", "france"
)

# Same dual-fold treatment as the sponsor list, for the same reason: EUCTR
# deletes accents, so "losung" and "lsung" are different tokens and both occur.
SUBSTANCE_GENERIC_TOKENS <- unique(c(
  .SUBSTANCE_GENERIC_BASE,
  gsub("[^a-z0-9]", "", stringi::stri_trans_general(.SUBSTANCE_GENERIC_BASE, "Latin-ASCII")),
  gsub("[^\\x01-\\x7F]", "", .SUBSTANCE_GENERIC_BASE, perl = TRUE),
  # Mangled forms of accented generics, which cannot be derived from the ASCII
  # base list because the deletion happened upstream to a spelling it never holds.
  "lsung", "lsungen", "injektionslsung", "infusionslsung", "solucin", "solucao",
  "inyeccin", "perfusin", "concentrado", "aplicacin"
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
#
# `generic` is a parameter rather than a read of the global GENERIC_TOKENS
# because a second entity type needs a different list entirely — see
# SUBSTANCE_GENERIC_TOKENS. The default preserves sponsor behaviour exactly.
#
# `drop_numeric` removes pure-digit tokens. Off by default: for organisation
# names a bare number is rare and harmless. On for substances, where a dose
# number is both common and actively misleading — "Etomedac 20 mg" retrieved
# "polifeprosan 20" on the shared token "20".
tokens_of <- function(folded, drop_generic = TRUE, concat_adjacent = TRUE,
                      generic = GENERIC_TOKENS, drop_numeric = FALSE) {
  t <- strsplit(folded, " ", fixed = TRUE)[[1L]]
  t <- t[nchar(t) >= 2L]
  if (drop_generic) t <- t[!t %in% generic]
  if (drop_numeric) t <- t[!grepl("^[0-9]+$", t)]
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

#
# `generic` and `drop_numeric` are stored on the returned index so the channels
# and the pair-graph builder tokenise a query exactly the way the index was
# built. Passing them per call instead was the first version and it is a silent
# corruption waiting to happen: a query tokenised under a different stoplist
# than the index simply fails to match, with no error.
build_index <- function(labels, ids = seq_along(labels), ngram_n = 4L,
                        generic = GENERIC_TOKENS, drop_numeric = FALSE) {
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
  tl_uni <- purrr::map(df$form, tokens_of, concat_adjacent = FALSE,
                       generic = generic, drop_numeric = drop_numeric)
  tl_all <- purrr::map(df$form, tokens_of, concat_adjacent = TRUE,
                       generic = generic, drop_numeric = drop_numeric)
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
    # An empty gram is not a gram. It arises where a label folds to nothing
    # (punctuation only) and would otherwise inflate that label's Jaccard
    # denominator with a term no query can ever match.
    dplyr::filter(!is.na(gram), nzchar(gram)) |>
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

  tok_full <- dplyr::left_join(tok, idf, by = "token")

  # Hashed postings, built once, so a per-query channel is a hash lookup instead
  # of a dplyr filter over the whole index.
  #
  # This is a scale fix, not a tidy-up. The sponsor corpus is 16,594 strings and
  # the filter-per-query cost was invisible there. The substance vocabulary is
  # 124,000 surface forms producing a ~2M-row gram table, and ch_ngram is the
  # PRIMARY channel for drugs, so B_assign issues 13,727 queries against it. At
  # roughly 100ms per dplyr scan that is 20+ minutes of pure filtering before a
  # single request is built. Same arithmetic, different data structure.
  max_id <- if (nrow(df)) max(df$label_id) else 0L

  list(
    forms        = df,
    tokens       = tok_full,
    idf          = idf,
    grams        = gram,
    acronyms     = acr,
    ngram_n      = ngram_n,
    n_labels     = n_labels,
    generic      = generic,
    drop_numeric = drop_numeric,
    max_id       = max_id,
    gram_post    = .postings(gram$gram, gram$label_id),
    gram_n       = .per_label_count(gram$label_id, max_id),
    tok_post     = .postings(tok_full$token, tok_full$label_id),
    tok_idf      = stats::setNames(idf$idf, idf$token)
  )
}

# key -> integer vector of label_ids, in an environment used as a hash map.
#
# Empty keys are dropped. char_ngrams() returns "" for a label whose folded form
# is empty — a string of only punctuation, which this corpus does contain — and
# an environment cannot hold a zero-length name, so list2env() errors out on it.
# An empty key could never match a query anyway.
.postings <- function(keys, ids) {
  keep <- !is.na(keys) & nzchar(keys)
  keys <- keys[keep]; ids <- ids[keep]
  e <- new.env(hash = TRUE, parent = emptyenv(),
               size = max(2L * length(unique(keys)), 29L))
  if (!length(keys)) return(e)
  list2env(split(as.integer(ids), keys), envir = e)
  e
}

.per_label_count <- function(ids, max_id) {
  if (!length(ids) || max_id < 1L) return(integer(0))
  tabulate(as.integer(ids), nbins = max_id)
}

# Sum a per-key weight over that key's postings, returning a vector indexed by
# label_id. `weights` may be NULL for a plain count.
.accumulate <- function(keys, post, max_id, weights = NULL) {
  acc <- numeric(max_id)
  for (i in seq_along(keys)) {
    ids <- post[[keys[[i]]]]
    if (is.null(ids)) next
    acc[ids] <- acc[ids] + if (is.null(weights)) 1 else weights[[i]]
  }
  acc
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
  qt <- unique(unlist(purrr::map(fold_forms(query), tokens_of,
                                 generic = idx$generic %||% GENERIC_TOKENS,
                                 drop_numeric = idx$drop_numeric %||% FALSE),
                      use.names = FALSE))
  if (!length(qt)) return(tibble::tibble())
  qt <- qt[qt %in% names(idx$tok_idf)]
  if (!length(qt)) return(tibble::tibble())
  w <- unname(idx$tok_idf[qt])
  total <- sum(w)
  if (total <= 0) return(tibble::tibble())

  acc <- .accumulate(qt, idx$tok_post, idx$max_id, weights = w)
  hit <- which(acc > 0)
  if (!length(hit)) return(tibble::tibble())
  score <- acc[hit] / total
  keep <- score >= min_score
  if (!any(keep)) return(tibble::tibble())
  hit <- hit[keep]; score <- score[keep]
  ord <- order(score, decreasing = TRUE)[seq_len(min(k, length(score)))]
  tibble::tibble(label_id = hit[ord], score = score[ord], channel = "token_idf")
}

# Replaces JW. Jaccard over character 4-grams: symmetric, no prefix weighting,
# and degrades gracefully on the single-character deletions the EUCTR corruption
# produces (one deleted char breaks at most n grams, not the whole comparison).
ch_ngram <- function(query, idx, k = 10L, threshold = 0.45) {
  qg <- unique(unlist(purrr::map(fold_forms(query), char_ngrams, n = idx$ngram_n),
                      use.names = FALSE))
  if (!length(qg)) return(tibble::tibble())

  shared <- .accumulate(qg, idx$gram_post, idx$max_id)
  hit <- which(shared > 0)
  if (!length(hit)) return(tibble::tibble())
  # Jaccard: shared / (|query| + |target| - shared).
  score <- shared[hit] / (length(qg) + idx$gram_n[hit] - shared[hit])
  keep <- score >= threshold
  if (!any(keep)) return(tibble::tibble())
  hit <- hit[keep]; score <- score[keep]
  ord <- order(score, decreasing = TRUE)[seq_len(min(k, length(score)))]
  tibble::tibble(label_id = hit[ord], score = score[ord], channel = "ngram")
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

#
# `interleave` changes how the slate is FILLED, not what qualifies for it.
#
# Strict rank ordering lets one channel take every slot. Measured on
# "Olopatadin Micro Labs 1 mg": token_idf returned ten hits on the shared words,
# all ranked above ngram, so the slate was tretinoin / fenofibrate / potassium
# chloride and olopatadine — which ngram DID find — never appeared. Raising
# token_idf's floor does not fix this (swept 0.15/0.25/0.35/0.45: 7/7/6/7 of 12,
# i.e. no signal), because the problem is slot allocation, not qualification.
#
# Interleaving takes candidates round-robin across channels in rank order, so
# every channel that found something contributes before any channel contributes
# twice. OFF by default: the sponsor pass has already run, and candidate order
# feeds cands_sha in its cache key, so changing it would invalidate paid work.
#
# `use_ngram` / `use_acronym` split what `extra_channels` used to switch on
# together, mirroring build_pair_graph(). Substances need the n-gram channel and
# must NOT have the acronym one: initials of the words in a product label are
# meaningless for a molecule, and ch_acronym scores every hit 1.0, so under
# interleaving it is guaranteed a slot. Measured — "Forxiga 10 mg film-coated
# tablets" was offered "Perampanel [1.00 acronym]" at rank 3, and 839 strings
# had an acronym hit as their TOP candidate.
retrieve <- function(query, idx, evidence = NULL, k = 10L, extra_channels = FALSE,
                     ngram_threshold = 0.45, interleave = FALSE,
                     use_ngram = extra_channels, use_acronym = extra_channels) {
  hits <- dplyr::bind_rows(
    ch_exact(query, idx),
    ch_structured(query, idx, evidence),
    ch_token_idf(query, idx, k = k),
    # Off by default for sponsors, ON for substances — a single-token drug name
    # gives token_idf nothing to work with. ngram_threshold is 0.45 here and
    # 0.30 for substances: measured, "SODIO ASCORBATO" reaches
    # "sodium ascorbate" at only 0.35, so the sponsor default would drop it.
    if (use_ngram) ch_ngram(query, idx, k = k, threshold = ngram_threshold),
    if (use_acronym) ch_acronym(query, idx, k = k)
  )
  if (!nrow(hits)) return(tibble::tibble(label_id = integer(), label = character(),
                                         score = numeric(), channel = character()))
  hits <- hits |>
    dplyr::mutate(rank = CHANNEL_RANK[channel] %||% 9L) |>
    dplyr::arrange(rank, dplyr::desc(score)) |>
    dplyr::distinct(label_id, .keep_all = TRUE)

  hits <- if (interleave) {
    hits |>
      dplyr::group_by(channel) |>
      dplyr::mutate(slot = dplyr::row_number()) |>
      dplyr::ungroup() |>
      dplyr::arrange(slot, rank, dplyr::desc(score)) |>
      utils::head(k)
  } else {
    utils::head(hits, k)
  }

  hits |>
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

#
# `use_ngram` / `use_acronym` split what `extra_channels` used to turn on
# together. They default to it, so existing callers are unchanged. Substances
# need the n-gram channel and must NOT have the acronym one: initials of the
# words in a drug name carry no meaning, and on the substance corpus that
# channel alone produced 14,328 pairs of pure noise.
#
# `ngram_max_postings` is exposed because the hardcoded 20 makes the channel
# INERT at n = 3: almost every 3-gram occurs in more than 20 labels, so nearly
# all of them are dropped and the channel contributes nothing. That is invisible
# unless you count the pairs per channel, which is why A_block and C_mint both
# print that table.
build_pair_graph <- function(idx, evidence = NULL,
                             ngram_min_shared = 6L,
                             max_postings = MAX_POSTINGS,
                             extra_channels = FALSE,
                             use_ngram = extra_channels,
                             use_acronym = extra_channels,
                             ngram_max_postings = 20L) {
  token_pairs <- scored_token_pairs(idx, max_postings = max_postings)

  # n-gram and acronym pairs are off by default for sponsors: the n-gram index
  # is an order of magnitude denser than the token index and dominates
  # graph-build time, for pairs token overlap has almost always already found.
  empty_pairs <- tibble::tibble(a = integer(), b = integer(), score = numeric(),
                                channel = character())
  acr_pairs <- if (use_acronym) {
    # An explicit score. Without one this channel emitted NA, which then
    # poisoned quantile() in the callers' report and made every
    # `score >= threshold` comparison NA in canopy_blocks(). Acronym is a
    # presence channel, so it is scored like `structured`: the key either
    # matched or it did not.
    pairs_from_postings(idx$acronyms, "acronym", max_postings = max_postings,
                        channel = "acronym") |>
      dplyr::mutate(score = 1)
  } else empty_pairs
  gram_pairs <- if (use_ngram) {
    pairs_from_postings(idx$grams, "gram", max_postings = ngram_max_postings,
                        channel = "ngram") |>
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
