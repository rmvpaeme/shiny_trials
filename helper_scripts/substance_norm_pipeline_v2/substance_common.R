# Shared substance-string helpers for the v2 pipeline.
#
# The cleaning and candidate-ladder functions are ported UNCHANGED from v1's
# normalise_substances.R. They are the part of the old pipeline that worked, and
# every coverage number in PLANS/substance-normalisation-v2.md was measured with
# them. Do not "improve" them without re-measuring: 68.6% of trial-substance
# pairs resolve through this ladder against ChEMBL alone.
#
# The junk filter is NOT ported. See below — v1's is a measured defect.

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(stringi)
})

# ── Cleaning (v1, verbatim) ───────────────────────────────────────────────────

clean_alias <- function(x) {
  x |>
    str_to_lower() |>
    str_replace_all("[  ​‌‍]", " ") |>
    str_replace_all("[®™]", "") |>
    str_replace_all("[‘’]", "'") |>
    str_replace_all("[–—−]", "-") |>
    str_replace_all("\\s+", " ") |>
    str_squish()
}

# Combination separators normalise to "|". A combination product is one
# canonical, not an ambiguous alias — "amoxicillin|clavulanic acid" is a single
# substance label, and the app has displayed it that way since v1.
clean_substance <- function(x) {
  x |>
    clean_alias() |>
    str_replace_all("\\s*/\\s*", "|") |>
    str_replace_all("\\s*;\\s*", "|") |>
    str_replace_all("\\s*\\|\\s*", "|") |>
    str_squish()
}

.dose_pattern <- paste0(
  "\\b\\d+[,.]?\\d*\\s*",
  "(mg|mcg|microgram|micrograms|mikrogramm|g|ml|l|iu|ui|mbq|gbq|%|ppm|mmol|",
  "nmol|molar|units?|i\\.?u\\.?|mg/ml|mg/kg|g/l)\\b"
)

.form_pattern <- paste0(
  "\\b(",
  paste(c(
    "solution", "suspension", "concentrate", "powder",
    "lyophilised", "lyophilized",
    "tablet", "tablets", "capsule", "capsules",
    "hard capsule", "hard capsules",
    "film.?coated", "modified.?release", "prolonged.?release",
    "extended.?release", "immediate.?release",
    "injection", "infusion", "intravenous", "intra.?venous",
    "subcutaneous", "intramuscular", "intrathecal", "intravitreal",
    "oral", "topical", "transdermal", "ophthalmic", "nasal",
    "inhaler", "inhalation", "nebuliser", "nebulizer", "spray",
    "pre.?filled syringe", "prefilled syringe",
    "pen", "autoinjector", "auto.?injector",
    "vial", "ampoule", "ampule", "bag",
    "dispersion", "emulsion", "granules", "patch", "implant", "depot",
    "foam", "rinse", "gel", "cream", "ointment", "lotion", "drops",
    "for injection", "for infusion", "for oral use",
    "for intravenous use"
  ), collapse = "|"),
  ")\\b"
)

# ── Candidate ladder (v1, verbatim) ───────────────────────────────────────────

generate_candidates <- function(raw) {
  x0 <- clean_alias(raw)
  x_no_dose <- str_remove_all(x0, regex(.dose_pattern, ignore_case = TRUE)) |> str_squish()
  x_no_form <- str_remove_all(x_no_dose, regex(.form_pattern, ignore_case = TRUE)) |> str_squish()

  first_token <- str_extract(x_no_form, "^[a-z0-9][a-z0-9\\-]*")
  # A short first token extracted from a longer string is a spurious alias hit
  # waiting to happen ("same" from "same excipients...", "18f" from
  # "18F-DPA-714"). Keep it only when it is specific, or when it IS the string.
  if (!is.na(first_token) && nchar(first_token) < 5 && first_token != x0) {
    first_token <- NA_character_
  }
  unique(stats::na.omit(c(x0, x_no_dose, x_no_form, first_token)))
}

display_substance <- function(x) str_to_sentence(x)

is_placebo <- function(x) str_detect(str_to_lower(coalesce(as.character(x), "")), "\\bplacebo\\b")

# ── Junk filter ───────────────────────────────────────────────────────────────
#
# NOT a port. v1's is_exploratory_substance() (3_build_substance_labels.R:67-82)
# rejects any string CONTAINING a dosage-form word, and measured against real
# corpus strings that is backwards on exactly the cases that matter:
#
#   Pembrolizumab concentrate for solution for infusion  -> REJECTED by v1
#   Humira 40 mg solution for injection                  -> REJECTED by v1
#   Methotrexat 10mg Tabletten                           -> REJECTED by v1
#   Rx Abemaciclib Ramiven 50 mg film coated tablets     -> REJECTED by v1
#   Not yet assigned                                     -> KEPT by v1
#   California                                           -> KEPT by v1
#
# Four real drugs discarded; a placeholder and an influenza strain name kept.
#
# The correct question is not "does this string mention a dosage form" but
# "is there anything left once the dosage language is removed". So the filter
# strips dose, form and route words — reusing the same patterns the candidate
# ladder already applies — and rejects only what has no substance content left.
# "Pembrolizumab concentrate for solution for infusion" reduces to
# "pembrolizumab" and survives; "mL concentrate for solution for infusion"
# reduces to nothing and does not.
#
# This filter is deliberately CONSERVATIVE. Anything it cannot confidently call
# junk goes to the model, which has an explicit not_a_substance answer. A string
# wrongly kept costs one cheap request; a string wrongly rejected is silently
# gone, and nothing downstream will ever ask about it again.

.PLACEHOLDER <- paste0(
  "^(n/?a|none|unknown|dose|other|others|nil|null|missing|test|blank)$|",
  "not available|not applicable|not yet available|not yet assigned|",
  "not assigned|not established|not yet established|not known|not specified|",
  "not disclosed|to be determined|to be confirmed|\\bno data\\b|",
  "no ha sido asignado|non attribu|nicht zugewiesen"
)

# Unit and packaging words the form pattern does not carry, so that a string
# made only of these reduces to nothing.
.UNIT_ONLY <- paste0(
  "\\b(mg|ml|mcg|kg|iu|ui|mbq|gbq|mmol|nmol|g|l|dose|doses|unit|units|",
  "each|per|and|or|the|of|for|with|in|to|a|an|no|not|yet|available|assigned|",
  "solution|solutions|solucion|soluci|losung|lsung|solutie|otopina|roztwor|",
  "konzentrat|herstellung|einer|zur|pour|perfusion|perfusao|diluer|",
  "injektionslosung|injektionslsung|infusionslosung|infusionslsung|",
  "iniettabile|inyectable|injectable|polvo|polvere|poudre|pulver|proszek|",
  "comprimido|comprimidos|comprime|comprimes|tabletten|tableta|tabletas|",
  "kapsel|kapseln|capsula|capsulas|recubiertos|pelicula|pelcula|",
  "sobre|flacon|ampulle|use|oral|orale|film|coated|rx|",
  # Dutch, Nordic and Finnish. Added after reading real slates: without them
  # "ml oplossing voor injectie" (26 trials) survived the filter and then
  # retrieved Aldesleukin, Amoxicillin and Amphotericin B at score 1.00 — a full
  # slate of unrelated drugs for a string that names no substance at all.
  "oplossing|oplossingen|concentraat|injectie|injecties|infusie|poeder|voor|",
  "verdunning|druppels|zalf|zetpil|injectievloeistof|suspensie|",
  "losning|lsning|opplosning|injektionsvatska|injektionsvaetska|",
  "injeksjonsvaeske|pulver|tabletter|koncentrat|ogondroppar|ojendraber|",
  "liuos|injektioneste|jauhe|tabletti|kuiva|aine)\\b"
)

# Returns the reason a string is junk, or NA if it is not.
junk_reason <- function(x) {
  s   <- coalesce(as.character(x), "")
  # Accents are folded BEFORE matching, not after. Matching first leaves
  # "Infusionslösung" unmatched against the ASCII "infusionslosung" in the word
  # list, so "ml Konzentrat zur Herstellung einer Infusionslösung" — pure
  # packaging language, 100 trials — survived as though it named a substance.
  key <- str_squish(str_to_lower(stringi::stri_trans_general(s, "Latin-ASCII")))

  # What survives stripping dose, form, route and unit language.
  #
  # DIGITS ARE KEPT. An earlier version stripped them here and also demanded a
  # run of three letters, which discarded every investigational compound code in
  # the corpus — PF-06480605, KT-621, K201, PF-07868489 are Pfizer and Kyorin
  # compounds, not junk. v1 had the same defect (grepl("[A-Za-z]{3,}", ...)).
  # For a code name the digits ARE the content, so the test below accepts
  # "letters AND digits" as substance content in its own right.
  residual <- key |>
    str_remove_all(regex(.dose_pattern, ignore_case = TRUE)) |>
    str_remove_all(regex(.form_pattern, ignore_case = TRUE)) |>
    str_remove_all(regex(.UNIT_ONLY,    ignore_case = TRUE)) |>
    str_remove_all("[^[:alnum:] ]") |>
    str_squish()

  # A word of 3+ letters, or any letter-plus-digit combination (a code name).
  has_content <- str_detect(residual, "[a-z]{3,}") |
    (str_detect(residual, "[a-z]") & str_detect(residual, "[0-9]"))

  case_when(
    nchar(str_trim(s)) < 3                                   ~ "shorter than 3 characters",
    str_detect(key, regex(.PLACEHOLDER, ignore_case = TRUE)) ~ "placeholder text, not a substance",
    !has_content ~ "only dose/form/unit language remains after stripping",
    TRUE                                                     ~ NA_character_
  )
}

is_junk_string <- function(x) !is.na(junk_reason(x))


# ── Re-join minted canonicals to the registry ─────────────────────────────────
# Shared by C_mint --materialise and tests/substance_v2_idempotence.R.
#
# A minted canonical is frequently a substance the reference registry already
# knows under a different name (Paracetamol / Acetaminophen), or one whose entity
# has since been merged away by D_consolidate (Calcium folinate -> Leucovorin
# calcium -> Leucovorin). Mapping it onto the surviving canonical BEFORE
# materialising is what makes the pass idempotent; without it a re-run mints
# duplicates. It lives here rather than inline in C_mint so the idempotence test
# exercises the same code the pipeline runs.
substance_fold <- function(x) {
  tolower(stringr::str_squish(stringi::stri_trans_general(as.character(x), "Latin-ASCII")))
}

rejoin_minted_canonicals <- function(clusters, reg, alias_path = NULL, verbose = TRUE) {
  live <- reg |> dplyr::filter(is.na(merged_into))
  if (!nrow(live) || !nrow(clusters)) return(clusters)

  # Resolve through merge chains over EVERY registry row, live rows winning ties
  # — the same rule registry_from_clusters() uses.
  term <- tibble::tibble(
    canonical = reg$canonical,
    entity_id = resolve_entity(reg, reg$entity_id),
    is_live   = is.na(reg$merged_into)
  ) |>
    dplyr::filter(!is.na(canonical), nzchar(canonical), !is.na(entity_id)) |>
    dplyr::arrange(dplyr::desc(is_live))
  surviving <- stats::setNames(live$canonical, live$entity_id)
  term$survivor <- unname(surviving[term$entity_id])
  term <- term |> dplyr::filter(!is.na(survivor)) |>
    dplyr::distinct(canonical, .keep_all = TRUE)
  by_canon <- stats::setNames(term$survivor, substance_fold(term$canonical))

  by_alias <- character()
  if (!is.null(alias_path) && file.exists(alias_path)) {
    a <- readr::read_csv(alias_path, show_col_types = FALSE, progress = FALSE) |>
      dplyr::mutate(entity_id = resolve_entity(reg, entity_id)) |>
      dplyr::filter(entity_id %in% live$entity_id) |>
      dplyr::mutate(k = substance_fold(alias)) |>
      dplyr::group_by(k) |>
      dplyr::filter(dplyr::n_distinct(entity_id) == 1L) |>   # unambiguous only
      dplyr::slice(1) |> dplyr::ungroup() |>
      dplyr::left_join(live |> dplyr::select(entity_id, canonical), by = "entity_id")
    by_alias <- stats::setNames(a$canonical, a$k)
  }

  k <- substance_fold(clusters$canonical)
  resolved <- ifelse(clusters$canonical %in% live$canonical, clusters$canonical,
                     dplyr::coalesce(unname(by_canon[k]), unname(by_alias[k]),
                                     clusters$canonical))
  n <- sum(resolved != clusters$canonical, na.rm = TRUE)
  if (verbose && n) {
    ex <- which(resolved != clusters$canonical)[seq_len(min(6L, n))]
    message(sprintf("re-joined %d minted canonical(s) to an existing registry entity:", n))
    for (i in ex) message(sprintf("    %-38s -> %s", clusters$canonical[[i]], resolved[[i]]))
  }
  clusters$canonical <- resolved
  clusters
}
