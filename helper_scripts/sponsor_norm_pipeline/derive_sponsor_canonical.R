# Derive a canonical sponsor label from a raw string, without an LLM.
#
# The alias tables carry ~90% of sponsor coverage and every row in them is a
# frozen LLM decision. A future import brings raw strings the tables have never
# seen. This module resolves the part of that residue that is pure string
# reduction — stripping a legal suffix, an address, a country tail — and
# declines the part that is entity resolution ("1. Frauenklinik der
# LMU-Innenstadt" → "Klinikum Der Universitat Munchen AöR"), because no regex
# produces an output that shares no material with its input.
#
# Measured against the frozen decisions (tests/derivation/replay.R), the rules
# here reproduce ~60% of sponsor decisions exactly or up to capitalisation, with
# a conflict rate near zero.
#
# Requires normalise_sponsors.R to have been sourced first — the patterns are
# deliberately the *same* objects the matcher uses for candidate generation, so
# a change to one cannot silently diverge from the other.
#
#   derive_sponsor_canonical("Acme Pharmaceuticals Ltd, London, UK")
#   #> derived = "Acme Pharmaceuticals", rule_id = "legal_suffix+country_tail"

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(tibble)
})

# ── reduction steps ───────────────────────────────────────────────────────────
#
# Each step takes a cleaned string and returns a cleaned string. A step "fires"
# when it changed the input. Steps run in the order below; rule_id records the
# ones that fired, so every derived label is traceable back to what produced it.

# Trailing conjunctions left behind by suffix removal: stripping "kg" out of
# "boehringer ingelheim pharma gmbh and co kg" exposes "and co", then "and".
.derive_trailing_conjunction_rx <- "\\s+\\b(and|und|et|e|y)$"

.strip_legal_suffix <- function(s) {
  # Repeat: "gmbh and co kg" is three suffixes and a conjunction deep.
  for (i in seq_len(6L)) {
    before <- s
    s <- s |>
      stringr::str_remove(stringr::regex(.legal_suffixes_rx, ignore_case = TRUE)) |>
      stringr::str_remove(stringr::regex(.derive_trailing_conjunction_rx, ignore_case = TRUE)) |>
      stringr::str_squish()
    if (identical(s, before)) break
  }
  s
}

# A department-stripping rule was tried here and rejected by the replay — see
# tests/derivation/report.md. "department" is the single most-removed token in
# the frozen decisions (169 rows), so it looks like the obvious next rule, but
# it is not a string reduction:
#
#   "aalborg university hospital dept of rheumatology" → "Aalborg University
#      Hospital"     — the parent precedes the department, so a suffix strip works
#   "academical medical center department of dermatology" → "Amsterdam UMC"
#      — the parent is not in the string at all
#   "aalst dermatology group" → "Aalst Dermatology Group"
#      — "dermatology" is part of the name, and stripping it renames the sponsor
#
# strip_department_suffix() cannot tell these apart, and scored 9 agreements
# against 59 conflicts. Resolving a department to its institution is entity
# resolution; it belongs in the reviewer app, not in a regex.

# country_tail and address_tail were tried and rejected too, at 37% and 31%
# destructive. The country is not a tail on a sponsor name, it is part of it:
#
#   "biotronik france"      → "BIOTRONIK France"
#   "cancer research uk"    → "Cancer Research UK"
#   "chu de fort-de-france" → "CHU de Fort-de-France"
#
# .country_tail_rx and .address_rx earn their keep in make_sponsor_candidates(),
# where an over-stripped candidate simply matches nothing and costs nothing.
# Used to *produce* a label, the same regexes rename the organisation. That
# asymmetry — a pattern safe for generating candidates being unsafe for
# generating labels — is the main thing this module had to learn.
#
# So one reduction rule ships, plus the case_punct fallback.
.sponsor_reduction_steps <- list(
  legal_suffix = .strip_legal_suffix
)

# How far from the raw string each step moves the result. A derived label is
# never `accepted` regardless (see 3_build_sponsor_labels.R), so these order the
# review queue rather than gate anything.
.sponsor_rule_confidence <- c(
  case_punct   = 0.90,
  legal_suffix = 0.85
)

# The derived label must still name an organisation. Reducing "Ministry of
# Health, France" to "Ministry" is worse than declining.
.min_derived_chars  <- 4L
.derive_stopwords <- c(
  "the", "of", "and", "de", "der", "das", "die", "le", "la", "les",
  "hospital", "university", "clinic", "centre", "center", "institute",
  "department", "research", "group", "trust", "foundation", "pharma",
  "pharmaceuticals", "medical", "health", "ministry", "unknown"
)

.derive_result <- function(derived = NA_character_,
                           rule_id = NA_character_,
                           confidence = NA_real_) {
  tibble::tibble(
    derived    = as.character(derived),
    rule_id    = as.character(rule_id),
    confidence = as.numeric(confidence)
  )
}

# ── single-rule application, for the replay harness ───────────────────────────

# Apply exactly one named reduction step. Used by tests/derivation/replay.R to
# report per-rule agree/conflict rates; the derivation itself uses the pipeline
# below, which composes them.
derive_sponsor_rule <- function(raw, rule_id) {
  s0 <- clean_sponsor_alias(raw)
  if (is.na(s0) || !nzchar(s0)) return(.derive_result())

  s <- if (identical(rule_id, "case_punct")) {
    # case_punct is "the cleaned raw string is already the answer". Its domain is
    # therefore strings no reduction touches — on anything with a legal suffix
    # still attached it is not declining to answer, it is answering wrongly, and
    # replaying it there would measure a rule nothing ever applies.
    if (any(purrr::map_lgl(
      .sponsor_reduction_steps, ~ !identical(.x(s0), s0)
    ))) {
      return(.derive_result())
    }
    s0
  } else {
    step <- .sponsor_reduction_steps[[rule_id]]
    if (is.null(step)) stop("Unknown sponsor rule: ", rule_id)
    step(s0)
  }

  if (!.derived_is_usable(s)) return(.derive_result())
  if (!identical(rule_id, "case_punct") && identical(s, s0)) {
    return(.derive_result())  # the rule declined: nothing to remove
  }

  .derive_result(
    derived    = .title_case_sponsor(s),
    rule_id    = rule_id,
    confidence = unname(.sponsor_rule_confidence[[rule_id]])
  )
}

.derived_is_usable <- function(s) {
  if (is.na(s) || !nzchar(s)) return(FALSE)
  if (nchar(s) < .min_derived_chars) return(FALSE)
  toks <- stringr::str_split(s, "\\s+")[[1L]]
  # Every token being a generic word means the specific name was stripped away.
  any(!toks %in% .derive_stopwords)
}

.title_case_sponsor <- function(s) {
  # str_to_title is what suggest_sponsor_clean() already uses, so derived labels
  # look like the rest of the table. It cannot know that "89bio" is lowercase-b
  # or "4TEEN4" is all-caps — which is exactly why derived rows go to `review`
  # and not to `accepted`.
  stringr::str_to_title(s)
}

# ── the derivation pipeline ───────────────────────────────────────────────────

derive_sponsor_canonical_one <- function(raw) {
  s0 <- clean_sponsor_alias(raw)
  if (is.na(s0) || !nzchar(s0)) return(.derive_result())

  # A combined multi-entity string ("X / Y") is preserved verbatim by the
  # matcher; reducing it here would silently collapse the entities.
  if (isTRUE(sponsor_is_cross_entity_combined_one(s0))) return(.derive_result())

  s <- s0
  fired <- character()
  for (rule_id in names(.sponsor_reduction_steps)) {
    candidate <- .sponsor_reduction_steps[[rule_id]](s)
    if (identical(candidate, s)) next
    if (!.derived_is_usable(candidate)) next   # too aggressive — keep the last good form
    s <- candidate
    fired <- c(fired, rule_id)
  }

  if (!.derived_is_usable(s)) return(.derive_result())

  rule_id <- if (length(fired) == 0L) "case_punct" else paste(fired, collapse = "+")
  confidence <- if (length(fired) == 0L) {
    .sponsor_rule_confidence[["case_punct"]]
  } else {
    min(.sponsor_rule_confidence[fired])
  }

  .derive_result(
    derived    = .title_case_sponsor(s),
    rule_id    = rule_id,
    confidence = unname(confidence)
  )
}

# Vectorised entry point. One row per input, in input order; `derived` is NA
# where no rule applies.
derive_sponsor_canonical <- function(raw_vec) {
  raw_vec <- as.character(raw_vec)
  if (length(raw_vec) == 0L) return(.derive_result()[0L, ])
  purrr::map_dfr(raw_vec, derive_sponsor_canonical_one)
}
