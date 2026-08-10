# Derive a canonical substance label from a raw string, without an LLM.
#
# Far less of the substance side is derivable than the sponsor side: ~35% is
# pure string reduction (dose, formulation, salt/hydrate form) and the rest is
# brand → INN, which is a dictionary lookup by nature. No transformation turns
# "Humira" into "adalimumab", so this module declines those rather than guessing.
# That residue is largely already covered by ChEMBL and EPAR, which the pipeline
# queries as reproducible external sources.
#
# Requires normalise_substances.R to have been sourced first — .dose_pattern,
# .form_pattern and sanitise_substance_output() are reused rather than
# re-expressed, so the derivation cannot drift from the matcher.
#
#   derive_substance_canonical("Imatinib mesylate 100 mg film-coated tablet")
#   #> derived = "imatinib", rule_id = "dose_form+salt_form"
#
# Output is lowercase, matching the `substance_clean` convention in
# config/substance_norm_pipeline/. The label builder sentence-cases it.

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(tibble)
  library(purrr)
})

# ── salt/hydrate vocabulary ───────────────────────────────────────────────────

# Mined from canonical_substances.csv rather than hardcoded: every `salt` row
# there already names its free base, so the difference between the two is a salt
# token by construction. This means adding a salt row to that file also teaches
# the derivation layer, with no second list to keep in sync.
mine_salt_tokens <- function(canonical) {
  if (is.null(canonical) || nrow(canonical) == 0L) return(character())
  if (!all(c("substance_clean", "parent_substance") %in% names(canonical))) {
    return(character())
  }

  salts <- canonical |>
    dplyr::filter(
      !is.na(parent_substance),
      !is.na(substance_clean),
      parent_substance != substance_clean
    )
  if (nrow(salts) == 0L) return(character())

  tokens <- purrr::map2(
    stringr::str_split(salts$substance_clean, "\\s+"),
    stringr::str_split(salts$parent_substance, "\\s+"),
    function(full, base) setdiff(full, base)
  )

  unique(unlist(tokens, use.names = FALSE))
}

# Forms that appear in the frozen decisions but have no canonical_substances.csv
# row to mine them from — the counts are their support in that corpus.
# See tests/derivation/mine_removals.R.
.extra_salt_tokens <- c(
  "hydrochloride",    # [119]
  "sodium",           # [46]
  "hcl",              # [22]
  "acetate",          # [20]
  "sulfate", "sulphate",
  "monohydrate", "dihydrate", "trihydrate", "anhydrous",
  "dihydrochloride",
  "chlorhydrate", "cloridrato", "hydrocloride", "sodico",  # non-English spellings
  "potassium", "calcium", "magnesium", "chloride",
  "citrate", "tartrate", "fumarate", "maleate", "malate",
  "succinate", "phosphate", "nitrate", "bromide", "iodide",
  "mesylate", "mesilate", "besylate", "besilate",
  "tosylate", "tosilate", "camsylate", "esylate",
  "pamoate", "palmitate", "stearate", "lactate", "gluconate",
  "carbonate", "bicarbonate", "borate", "salt", "salts",
  "dipotassium", "disodium", "hemihydrate", "hyclate"
)

.salt_prefixes <- "^(as|and|in the form of)\\s+"

# ── reduction steps ───────────────────────────────────────────────────────────

.strip_dose_form <- function(s) {
  # sanitise_substance_output() is the matcher's own output cleaner; reusing it
  # keeps derived labels formatted exactly like matched ones.
  out <- sanitise_substance_output(s)

  # Bare quantities .dose_pattern misses because they carry no unit: a leading
  # strength ("0.1 bupivacaine", "1 lidocaine") or a trailing one
  # ("imatinib 100").
  out <- stringr::str_remove(
    out, "^\\s*\\d+[,.]?\\d*\\s*%?\\s+(?=[[:alpha:]])"
  ) |>
    stringr::str_squish()

  # A trailing number is only a strength if what precedes it is a word. In a
  # research code — "amg 706" → motesanib, "isis 301012" → mipomersen — the
  # number IS the identity, and stripping it leaves "amg", which then fuzzy-
  # matches anything. Requiring a 5+ character final token keeps those intact;
  # dropping this guard put dose_form at 1,551 conflicts.
  trimmed <- stringr::str_remove(out, "\\s+\\d+[,.]?\\d*\\s*%?$") |>
    stringr::str_squish()
  last_token <- utils::tail(stringr::str_split(trimmed, "\\s+")[[1L]], 1L)
  if (nzchar(trimmed) && stringr::str_detect(last_token, "^[[:alpha:]]{5,}$")) {
    out <- trimmed
  }

  out
}

.strip_salt_form <- function(s, salt_tokens) {
  if (length(salt_tokens) == 0L) return(s)
  for (i in seq_len(4L)) {
    before <- s
    toks <- stringr::str_split(s, "\\s+")[[1L]]
    if (length(toks) <= 1L) break
    if (!tolower(utils::tail(toks, 1L)) %in% salt_tokens) break

    remainder <- paste(utils::head(toks, -1L), collapse = " ")
    # Some substances ARE a salt: "sodium chloride", "potassium citrate". Both
    # tokens are in the vocabulary, so stripping the tail leaves a counter-ion
    # masquerading as an INN. If what survives is itself nothing but salt
    # vocabulary, the string was never a salt form of something else.
    remainder_toks <- tolower(stringr::str_split(remainder, "\\s+")[[1L]])
    if (all(remainder_toks %in% salt_tokens)) break

    s <- remainder
    # "imatinib as mesylate" leaves a dangling connective once the salt is gone.
    s <- stringr::str_remove(s, "\\s+\\b(as|and|in|the|form|of)$") |>
      stringr::str_squish()
    if (identical(s, before)) break
  }
  s
}

# Stray leading and trailing punctuation only: "-aescin" → "aescin".
#
# Stripping the radiolabel off a PET tracer was tried and rejected — the replay
# put it at 5 agreements against 42 conflicts, because "18f-altanserin" and
# "11c-raclopride" ARE the substance names the tables hold; the isotope is part
# of the tracer's identity, not a prefix on a parent compound. Chemical locants
# ("5-fluorouracil", "3,4-methylenedioxy…") are left alone for the same reason:
# the handful the tables do drop are recorded as explicit overrides.
.strip_prefix_junk <- function(s) {
  s |>
    stringr::str_remove("^[^[:alnum:]]+") |>
    stringr::str_remove("[^[:alnum:])]+$") |>
    stringr::str_squish()
}

# salt_form is NOT in the pipeline. It was built, measured at 25% destructive,
# and cut — because it contradicts the convention the tables actually use.
# canonical_substances.csv gives a salt its own row and points `parent_substance`
# at the free base, so `acalabrutinib maleate` stays the canonical label and
# `acalabrutinib` is recorded alongside it. Deriving the base as the *label*
# therefore disagrees with the table on every salt it already knows, and
# .attach_parent() in normalise_substances.R already supplies the base for the
# ones it does. mine_salt_tokens() and .strip_salt_form() are kept because the
# vocabulary is useful and correct; the reduction is what was wrong.
.substance_reduction_steps <- function(salt_tokens) {
  list(
    prefix_trim = .strip_prefix_junk,
    dose_form   = .strip_dose_form
  )
}

.substance_rule_confidence <- c(
  case_punct  = 0.90,
  prefix_trim = 0.88,
  dose_form   = 0.85,
  salt_form   = 0.80
)

.min_derived_substance_chars <- 3L

# A derived substance must look like a substance name, not like a sentence
# fragment or a leftover formulation phrase.
.substance_reject_rx <- paste0(
  "^(",
  paste(c(
    "and", "or", "the", "of", "for", "with", "plus", "other", "same",
    "study", "drug", "product", "treatment", "arm", "group", "dose",
    "unknown", "not", "n/a", "na", "none", "control", "comparator"
  ), collapse = "|"),
  ")$"
)

.derived_substance_is_usable <- function(s) {
  if (is.na(s) || !nzchar(s)) return(FALSE)
  if (nchar(s) < .min_derived_substance_chars) return(FALSE)
  if (!stringr::str_detect(s, "[[:alpha:]]{3,}")) return(FALSE)
  if (stringr::str_detect(s, stringr::regex(.substance_reject_rx, ignore_case = TRUE))) {
    return(FALSE)
  }
  # Long free-text phrases are descriptions, not substance names.
  stringr::str_count(s, "\\s+") <= 4L
}

.derive_substance_result <- function(derived = NA_character_,
                                     rule_id = NA_character_,
                                     confidence = NA_real_) {
  tibble::tibble(
    derived    = as.character(derived),
    rule_id    = as.character(rule_id),
    confidence = as.numeric(confidence)
  )
}

# ── single-rule application, for the replay harness ───────────────────────────

derive_substance_rule <- function(raw, rule_id, salt_tokens) {
  s0 <- clean_alias(raw)
  if (is.na(s0) || !nzchar(s0)) return(.derive_substance_result())

  steps <- .substance_reduction_steps(salt_tokens)
  s <- if (identical(rule_id, "case_punct")) {
    # See the note in derive_sponsor_rule(): case_punct's domain is strings no
    # reduction touches, so replaying it elsewhere would measure a rule the
    # pipeline never reaches.
    if (any(purrr::map_lgl(steps, ~ !identical(.x(s0), s0)))) {
      return(.derive_substance_result())
    }
    s0
  } else {
    step <- steps[[rule_id]]
    if (is.null(step)) stop("Unknown substance rule: ", rule_id)
    step(s0)
  }

  if (!.derived_substance_is_usable(s)) return(.derive_substance_result())
  if (!identical(rule_id, "case_punct") && identical(s, s0)) {
    return(.derive_substance_result())
  }

  .derive_substance_result(
    derived    = s,
    rule_id    = rule_id,
    confidence = unname(.substance_rule_confidence[[rule_id]])
  )
}

# ── the derivation pipeline ───────────────────────────────────────────────────

derive_substance_canonical_one <- function(raw, salt_tokens) {
  s0 <- clean_alias(raw)
  if (is.na(s0) || !nzchar(s0)) return(.derive_substance_result())

  # Combination products are several substances, not one; the matcher keeps them
  # as "a|b" and derivation has no basis for choosing between them.
  if (stringr::str_detect(s0, "[|/;+]")) return(.derive_substance_result())

  steps <- .substance_reduction_steps(salt_tokens)
  s <- s0
  fired <- character()
  for (rule_id in names(steps)) {
    candidate <- steps[[rule_id]](s)
    if (identical(candidate, s)) next
    if (!.derived_substance_is_usable(candidate)) next
    s <- candidate
    fired <- c(fired, rule_id)
  }

  if (!.derived_substance_is_usable(s)) return(.derive_substance_result())

  rule_id <- if (length(fired) == 0L) "case_punct" else paste(fired, collapse = "+")
  confidence <- if (length(fired) == 0L) {
    .substance_rule_confidence[["case_punct"]]
  } else {
    min(.substance_rule_confidence[fired])
  }

  .derive_substance_result(
    derived    = s,
    rule_id    = rule_id,
    confidence = unname(confidence)
  )
}

# Vectorised entry point. `canonical` is canonical_substances.csv, used to mine
# the salt vocabulary; pass it once so the mining runs once per build.
derive_substance_canonical <- function(raw_vec, canonical = NULL) {
  raw_vec <- as.character(raw_vec)
  if (length(raw_vec) == 0L) return(.derive_substance_result()[0L, ])

  salt_tokens <- unique(c(mine_salt_tokens(canonical), .extra_salt_tokens))
  purrr::map_dfr(raw_vec, derive_substance_canonical_one, salt_tokens = salt_tokens)
}
