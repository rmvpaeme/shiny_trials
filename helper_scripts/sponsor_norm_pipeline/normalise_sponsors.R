suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(stringi)
  library(purrr)
  library(readr)
  library(tibble)
  library(stringdist)
})

# ── Cleaning helpers ──────────────────────────────────────────────────────────

clean_sponsor_alias <- function(x) {
  x |>
    stringi::stri_trans_general("Latin-ASCII") |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[ ​‌‍]", " ") |>
    stringr::str_replace_all("[‘’`']", "'") |>
    stringr::str_replace_all("[–—−]", "-") |>
    stringr::str_replace_all("&", " and ") |>
    stringr::str_replace_all("[.,;:(){}\\[\\]]", " ") |>
    stringr::str_replace_all("\\s+", " ") |>
    stringr::str_squish()
}

# ── Candidate generator ───────────────────────────────────────────────────────

.legal_suffixes_rx <- paste0(
  "\\s+\\b(",
  paste(c(
    "inc", "incorporated", "corp", "corporation", "company", "co",
    "ltd", "limited", "llc", "plc", "ag", "gmbh", "kg", "kgaa",
    "bv", "b\\.v", "nv", "n\\.v", "sa", "s\\.a", "sas", "srl",
    "spa", "a/s", "ab", "oy", "pte", "kk", "a\\.?ö\\.?r"
  ), collapse = "|"),
  ")$"
)

.address_rx <- paste0(
  "\\b(",
  paste(c(
    "\\d{3,}", "street", "strasse", "road", "avenue", "ave",
    "boulevard", "blvd", "drive", "new york", "\\bny\\b", "\\busa\\b",
    "united states", "\\buk\\b", "germany", "france", "belgium",
    "netherlands", "switzerland", "austria"
  ), collapse = "|"),
  ")\\b"
)

.country_tail_rx <- paste0(
  "\\b(",
  paste(c(
    "the netherlands", "netherlands", "nederland", "belgium", "france",
    "germany", "united kingdom", "uk", "united states", "usa",
    "switzerland", "austria", "spain", "italy", "denmark", "sweden",
    "norway", "finland"
  ), collapse = "|"),
  ")$"
)

.rd_rx <- paste0(
  "\\b(",
  paste(c(
    "international", "pharmaceuticals", "biologicals", "biosciences",
    "sciences", "therapeutics", "oncology", "diagnostics",
    "europe", "north america", "global"
  ), collapse = "|"),
  ")\\b"
)

.department_rx <- paste0(
  "\\b(",
  paste(c(
    "department", "dept", "departement", "department of", "dept of",
    "service", "division", "unit", "section", "clinic", "klinik",
    "laboratory", "laboratories", "lab", "abteilung", "afdeling",
    "heilkunde", "dermatology", "neurology", "endocrinology",
    "pharmacy", "pharmacology", "toxicology"
  ), collapse = "|"),
  ")\\b"
)

.institution_anchor_rx <- paste0(
  "\\b(",
  paste(c(
    "university", "universiteit", "universitair", "universitair[e]?",
    "universityhospital", "universitetshospital", "universitetshospitalet",
    "medical", "medisch", "medische", "hospital", "hospitals",
    "sygehus", "sygehuset", "sjukhus", "sjukhuset", "ziekenhuis",
    "centre", "center", "centrum", "klinikum", "clinic", "umc",
    "chu", "chru", "institute", "institut", "istituto", "ospedale",
    "policlinico", "stichting"
  ), collapse = "|"),
  ")\\b"
)

is_department_label <- function(x) {
  stringr::str_detect(
    clean_sponsor_alias(dplyr::coalesce(as.character(x), "")),
    stringr::regex(.department_rx, ignore_case = TRUE)
  )
}

strip_department_suffix <- function(x) {
  s <- clean_sponsor_alias(x)
  out <- stringr::str_remove(s, stringr::regex(
    paste0("\\s+", .department_rx, "\\b.*$"),
    ignore_case = TRUE
  ))
  out <- stringr::str_squish(out)
  dplyr::if_else(nchar(out) >= 3L & out != s, out, NA_character_)
}

expand_institution_parent_candidates <- function(x) {
  base <- clean_sponsor_alias(x)
  base <- base |>
    stringr::str_remove_all(stringr::regex(.address_rx, ignore_case = TRUE)) |>
    stringr::str_remove(stringr::regex(paste0("\\s+", .country_tail_rx), ignore_case = TRUE)) |>
    stringr::str_remove(stringr::regex("^\\s*(the\\s+)?")) |>
    stringr::str_squish()

  if (is.na(base) || !nzchar(base)) return(character())

  centre_variants <- unique(c(
    base,
    stringr::str_replace_all(base, "\\bcenter\\b", "centre"),
    stringr::str_replace_all(base, "\\bcentre\\b", "center")
  ))

  st_variants <- unique(c(
    centre_variants,
    stringr::str_replace_all(centre_variants, "\\bsint\\b", "st"),
    stringr::str_replace_all(centre_variants, "\\bsaint\\b", "st")
  ))

  umc_variants <- character()
  for (candidate in st_variants) {
    umc_variants <- c(
      umc_variants,
      stringr::str_replace(
        candidate,
        "^university medical cent(?:er|re)\\s+(.+)$",
        "umc \\1"
      ),
      stringr::str_replace(
        candidate,
        "^universitair medisch centrum\\s+(.+)$",
        "umc \\1"
      ),
      stringr::str_replace(
        candidate,
        "^(.+)\\s+universitair medisch centrum$",
        "\\1 umc"
      )
    )
  }

  # Many medical-centre aliases are maintained at the compact UMC level
  # rather than with department/city suffixes.
  compact_umc <- purrr::map_chr(
    stringr::str_match(st_variants, "^([a-z0-9-]+)\\s+umc\\b")[, 2],
    ~ if (!is.na(.x)) paste(.x, "umc") else NA_character_
  )

  unique(stats::na.omit(c(st_variants, umc_variants, compact_umc)))
}

department_parent_candidates <- function(raw) {
  raw_chr <- dplyr::coalesce(as.character(raw), "")
  parts <- unlist(stringr::str_split(raw_chr, "\\s*[,;/]\\s*"))
  parts <- clean_sponsor_alias(parts)
  parts <- parts[
    nchar(parts) >= 3L &
      stringr::str_detect(parts, stringr::regex(.institution_anchor_rx, ignore_case = TRUE))
  ]

  clean <- clean_sponsor_alias(raw_chr)
  suffix_stripped <- strip_department_suffix(raw_chr)

  # Handles "Dept of X, Example UMC" after comma splitting, and also cases
  # without punctuation such as "Afdeling heelkunde Universitair Medisch...".
  anchor_tail <- stringr::str_match(clean, stringr::regex(
    paste0(".*?(", .institution_anchor_rx, ".*)$"),
    ignore_case = TRUE
  ))[, 2]

  parents <- unique(stats::na.omit(c(parts, suffix_stripped, anchor_tail)))
  unique(stats::na.omit(c(
    parents,
    unlist(purrr::map(parents, expand_institution_parent_candidates), use.names = FALSE)
  )))
}

# ── Entity-family helpers ─────────────────────────────────────────────────────

.entity_concept_patterns <- tibble::tribble(
  ~concept, ~pattern,
  "medical_center", "\\bumc\\b|\\bamc\\b|\\buniversity medical cent(?:er|re)\\b|\\buniversityhospital\\b|\\buniversityhospitals\\b|\\buniversitair medisch centrum\\b|\\buniversitair medische centrum\\b|\\buniversitair medisch\\b|\\buniversitetshospital\\b|\\buniversitetshospitalet\\b|\\buniversitetssjukhus\\b|\\buniversitaetsklinikum\\b|\\buniversitatsklinikum\\b|\\buniversitaetskliniken\\b|\\buniversitatskliniken\\b|\\buniversitaetsmedizin\\b|\\buniversitatsmedizin\\b|\\bcentre hospitalier universitaire\\b|\\bcentro hospitalar universitario\\b|\\bazienda ospedalier[ao] universitari[ao]\\b|\\bpoliclinico universitario\\b|\\bhospital universitari[ao]\\b|\\bhopital universitaire\\b|\\bchu\\b|\\bchru\\b",
  "university", "\\buniversity\\b|\\buniversities\\b|\\buniversiteit\\b|\\buniversitair(?:e)?\\b|\\buniversite\\b|\\buniversidad\\b|\\buniversidade\\b|\\buniversitat\\b|\\buniversita\\b|\\buniversitt\\b|\\buniversitaet\\b|\\buniversitat\\b|\\buniversitats\\b|\\buniversitets\\b|\\buniv\\b",
  "hospital", "\\bhospital\\b|\\bhospitals\\b|\\bsygehus\\b|\\bsygehuset\\b|\\bsjukhus\\b|\\bsjukhuset\\b|\\bziekenhuis\\b|\\bkrankenhaus\\b|\\bklinikum\\b|\\bkliniken\\b|\\bospedale\\b|\\bhopital\\b|\\bhpital\\b|\\bhopitaux\\b|\\bpoliclinico\\b|\\bclinique\\b|\\bcliniques\\b|\\bclinic\\b|\\bclinica\\b|\\bkliniek\\b",
  "medical", "\\bmedical\\b|\\bmedicine\\b|\\bmedisch\\b|\\bmedische\\b|\\bmedicin\\b|\\bmedicina\\b|\\bmedecine\\b",
  "center", "\\bcenters?\\b|\\bcentres?\\b|\\bcentrum\\b|\\bcentro\\b|\\bcentre\\b",
  "foundation", "\\bfoundation\\b|\\bfondation\\b|\\bfondazione\\b|\\bfundacion\\b|\\bfundacao\\b|\\bstichting\\b",
  "department", "\\bdepartment\\b|\\bdept\\b|\\bdepartement\\b|\\bdivision\\b|\\bunit\\b|\\bsection\\b|\\bservice\\b|\\bafdeling\\b|\\babteilung\\b|\\bklinik\\b|\\bclinic\\b|\\blaborator(?:y|ies)\\b|\\blab\\b",
  "research", "\\bresearch\\b|\\brecherche\\b|\\binvestigacion\\b|\\binvestigacao\\b|\\bforschung\\b|\\bscience\\b|\\bsciences\\b",
  "trust", "\\btrust\\b|\\bnhs\\b|\\bfoundation trust\\b",
  "institute", "\\binstitute\\b|\\binstitut\\b|\\bistituto\\b|\\binstituto\\b|\\binstitutet\\b"
)

.entity_concept_tokens <- unique(.entity_concept_patterns$concept)

.entity_generic_tokens <- c(
  "the", "of", "for", "and", "in", "at", "de", "di", "del", "della", "der",
  "den", "het", "la", "le", "les", "el", "da", "do", "dos", "das", "og",
  .entity_concept_tokens,
  "university", "universities", "universiteit", "universitair", "universitaire",
  "universite", "universidad", "universidade", "universitat", "universita",
  "universitt", "universitaet", "universitats", "universitets",
  "medical", "medisch", "medische", "medicine", "medicin", "medicina",
  "hospital", "hospitals", "sygehus", "sygehuset", "sjukhus", "sjukhuset",
  "ziekenhuis", "krankenhaus", "klinikum", "kliniken", "ospedale", "hopital",
  "hpital", "hopitaux", "centre", "center", "centrum", "centro", "clinic",
  "clinique", "cliniques", "clinica", "kliniek", "klinik", "umc", "amc",
  "institute", "institut", "istituto", "instituto", "institutet",
  "research", "science", "sciences", "department", "dept", "departement",
  "division", "unit", "section", "laboratory", "laboratories", "lab",
  "service", "services", "stichting", "foundation", "fundacion", "fundacao",
  "fondation", "fondazione", "group", "groupe", "trust", "nhs", "st", "aor",
  "ag", "gmbh", "bv", "nv", "ltd", "limited", "inc", "corp", "corporation",
  "company", "co"
)

normalise_entity_text <- function(x) {
  clean_sponsor_alias(x) |>
    stringr::str_replace_all("\\bsint\\b|\\bsaint\\b", "st") |>
    stringr::str_replace_all("\\bcenters?\\b", "centre") |>
    stringr::str_replace_all("\\bcentres?\\b", "centre") |>
    stringr::str_replace_all("\\bcentrum\\b", "centre") |>
    stringr::str_squish()
}

entity_concepts <- function(x) {
  s <- normalise_entity_text(x)
  if (is.na(s) || !nzchar(s)) return(character())
  concepts <- .entity_concept_patterns$concept[
    stringr::str_detect(s, stringr::regex(.entity_concept_patterns$pattern, ignore_case = TRUE))
  ]
  unique(concepts)
}

entity_concept_text <- function(x) {
  s <- normalise_entity_text(x)
  if (is.na(s) || !nzchar(s)) return(NA_character_)
  out <- s
  for (i in seq_len(nrow(.entity_concept_patterns))) {
    out <- stringr::str_replace_all(
      out,
      stringr::regex(.entity_concept_patterns$pattern[[i]], ignore_case = TRUE),
      paste0(" ", .entity_concept_patterns$concept[[i]], " ")
    )
  }
  stringr::str_squish(out)
}

entity_anchor_key_one <- function(x) {
  s <- entity_concept_text(x)
  if (is.na(s) || !nzchar(s)) return(NA_character_)

  s <- s |>
    stringr::str_remove_all(stringr::regex(.address_rx, ignore_case = TRUE)) |>
    stringr::str_remove(stringr::regex(paste0("\\s+", .country_tail_rx), ignore_case = TRUE)) |>
    stringr::str_remove_all(stringr::regex(.legal_suffixes_rx, ignore_case = TRUE)) |>
    stringr::str_replace_all("[^a-z0-9]+", " ") |>
    stringr::str_squish()

  if (!nzchar(s)) return(NA_character_)
  toks <- stringr::str_split(s, "\\s+")[[1L]]
  toks <- toks[nchar(toks) >= 3L & !toks %in% .entity_generic_tokens]
  if (length(toks) == 0L) return(NA_character_)
  paste(unique(toks), collapse = " ")
}

entity_class_key_one <- function(x) {
  concepts <- entity_concepts(x)
  entity_class_from_concepts(concepts)
}

entity_class_from_concepts <- function(concepts) {
  if (length(concepts) == 0L) return(NA_character_)
  classes <- c()
  if ("medical_center" %in% concepts) classes <- c(classes, "hospital", "university")
  if (all(c("medical", "center") %in% concepts)) classes <- c(classes, "hospital", "university")
  if ("hospital" %in% concepts) classes <- c(classes, "hospital")
  if ("university" %in% concepts) classes <- c(classes, "university")
  if ("clinic" %in% concepts) classes <- c(classes, "hospital")
  if ("foundation" %in% concepts) classes <- c(classes, "foundation")
  if ("trust" %in% concepts) classes <- c(classes, "trust")
  if ("institute" %in% concepts) classes <- c(classes, "institute")
  if (length(classes) == 0L) classes <- concepts
  paste(sort(unique(classes)), collapse = "|")
}

entity_family_from_anchor_class <- function(anchor, class_key) {
  if (is.na(anchor) || !nzchar(anchor)) return(NA_character_)
  classes <- strsplit(dplyr::coalesce(class_key, ""), "\\|", fixed = FALSE)[[1L]]
  family_class <- dplyr::case_when(
    "hospital" %in% classes ~ "hospital",
    "foundation" %in% classes ~ "foundation",
    "trust" %in% classes ~ "trust",
    "institute" %in% classes ~ "institute",
    "university" %in% classes ~ "university",
    TRUE ~ "entity"
  )
  paste(anchor, family_class)
}

entity_family_key_one <- function(x) {
  entity_family_from_anchor_class(entity_anchor_key_one(x), entity_class_key_one(x))
}

department_parent_key_one <- function(x) {
  parents <- department_parent_candidates(x)
  parents <- parents[!is.na(parents) & nzchar(parents)]
  if (length(parents) == 0L) return(NA_character_)
  keys <- purrr::map_chr(parents, entity_family_key_one)
  keys <- keys[!is.na(keys) & nzchar(keys)]
  if (length(keys) == 0L) return(NA_character_)
  keys[[1L]]
}

sponsor_entity_profile_basic <- function(x) {
  x <- as.character(x)
  profile_one <- function(value) {
    concept_text <- entity_concept_text(value)
    if (is.na(concept_text) || !nzchar(concept_text)) {
      return(tibble::tibble(
        entity_anchor_key = NA_character_,
        entity_class_key = NA_character_,
        entity_family_key = NA_character_,
        department_parent_key = NA_character_
      ))
    }

    s <- concept_text |>
      stringr::str_remove_all(stringr::regex(.address_rx, ignore_case = TRUE)) |>
      stringr::str_remove(stringr::regex(paste0("\\s+", .country_tail_rx), ignore_case = TRUE)) |>
      stringr::str_remove_all(stringr::regex(.legal_suffixes_rx, ignore_case = TRUE)) |>
      stringr::str_replace_all("[^a-z0-9]+", " ") |>
      stringr::str_squish()

    toks <- if (nzchar(s)) stringr::str_split(s, "\\s+")[[1L]] else character()
    concepts <- unique(toks[toks %in% .entity_concept_tokens])
    class_key <- entity_class_from_concepts(concepts)
    anchor_toks <- toks[nchar(toks) >= 3L & !toks %in% .entity_generic_tokens]
    anchor_key <- if (length(anchor_toks) == 0L) NA_character_ else paste(unique(anchor_toks), collapse = " ")

    tibble::tibble(
      entity_anchor_key = anchor_key,
      entity_class_key = class_key,
      entity_family_key = entity_family_from_anchor_class(anchor_key, class_key),
      department_parent_key = NA_character_
    )
  }

  if (length(x) == 0L) {
    return(tibble::tibble(
      entity_anchor_key = character(),
      entity_class_key = character(),
      entity_family_key = character(),
      department_parent_key = character()
    ))
  }

  purrr::map_dfr(x, profile_one)
}

sponsor_entity_profile <- function(x) {
  basic <- sponsor_entity_profile_basic(x)
  basic$department_parent_key <- purrr::map_chr(as.character(x), department_parent_key_one)
  basic
}

entity_key_is_classed <- function(key) {
  stringr::str_detect(
    dplyr::coalesce(as.character(key), ""),
    "\\b(hospital|university|foundation|trust|institute)\\b$"
  )
}

sponsor_entity_key_one <- function(x) {
  entity_family_key_one(x)
}

sponsor_entity_key <- function(x) {
  x <- as.character(x)
  if (length(x) == 0L) return(character())
  purrr::map_chr(x, sponsor_entity_key_one)
}

sponsor_combined_parts <- function(x) {
  x <- dplyr::coalesce(as.character(x), "") |>
    stringr::str_replace_all("\\ba/s\\b|\\bs/a\\b", " ")
  parts <- unlist(stringr::str_split(x, "\\s*/\\s*|\\s*;\\s*"))
  parts <- parts[!is.na(parts) & nzchar(stringr::str_squish(parts))]
  parts
}

sponsor_is_cross_entity_combined_one <- function(x) {
  parts <- sponsor_combined_parts(x)
  if (length(parts) < 2L) return(FALSE)
  keys <- sponsor_entity_key(parts)
  keys <- keys[!is.na(keys) & nzchar(keys)]
  if (length(keys) != length(parts)) return(TRUE)
  if (dplyr::n_distinct(keys) <= 1L) return(FALSE)

  profiles <- sponsor_entity_profile_basic(parts)
  anchors <- profiles$entity_anchor_key[!is.na(profiles$entity_anchor_key)]
  if (length(anchors) == length(parts)) {
    anchor_tokens <- purrr::map(anchors, ~ stringr::str_split(.x, "\\s+")[[1L]])
    common_tokens <- Reduce(intersect, anchor_tokens)
    common_tokens <- common_tokens[nchar(common_tokens) >= 4L]
    classes <- unique(stats::na.omit(profiles$entity_class_key))
    if (length(common_tokens) > 0L && length(classes) <= 2L) return(FALSE)
  }

  TRUE
}

sponsor_is_cross_entity_combined <- function(x) {
  x <- as.character(x)
  if (length(x) == 0L) return(logical())
  purrr::map_lgl(x, sponsor_is_cross_entity_combined_one)
}

containment_tokens <- function(x) {
  s <- normalise_entity_text(x) |>
    stringr::str_replace_all("[^a-z0-9]+", " ") |>
    stringr::str_squish()
  if (is.na(s) || !nzchar(s)) return(character())
  stringr::str_split(s, "\\s+")[[1L]]
}

token_sequence_contains <- function(haystack, needle) {
  if (length(needle) == 0L || length(haystack) < length(needle)) return(FALSE)
  starts <- seq_len(length(haystack) - length(needle) + 1L)
  any(purrr::map_lgl(starts, function(i) {
    identical(haystack[i:(i + length(needle) - 1L)], needle)
  }))
}

suggest_sponsor_clean <- function(x) {
  x0 <- clean_sponsor_alias(x)
  dept_parent <- department_parent_candidates(x)
  x_base <- if (length(dept_parent) > 0L) dept_parent[[1L]] else x0
  s  <- x_base |>
    stringr::str_remove_all(stringr::regex(.address_rx,    ignore_case = TRUE)) |>
    stringr::str_squish() |>
    stringr::str_remove_all(stringr::regex(.legal_suffixes_rx, ignore_case = TRUE)) |>
    stringr::str_squish() |>
    stringr::str_remove_all(stringr::regex(.rd_rx,         ignore_case = TRUE)) |>
    stringr::str_squish()
  stringr::str_to_title(if (nchar(s) >= 3) s else x0)
}

make_sponsor_candidates <- function(x) {
  x0 <- clean_sponsor_alias(x)

  x_no_addr <- x0 |>
    stringr::str_remove_all(stringr::regex(.address_rx, ignore_case = TRUE)) |>
    stringr::str_squish()

  x_no_legal <- x_no_addr |>
    stringr::str_remove_all(stringr::regex(.legal_suffixes_rx, ignore_case = TRUE)) |>
    stringr::str_squish()

  x_no_rd <- x_no_legal |>
    stringr::str_remove_all(stringr::regex(.rd_rx, ignore_case = TRUE)) |>
    stringr::str_squish()

  dept_candidates <- department_parent_candidates(x)

  # Strip parenthetical content from the RAW string before cleaning —
  # clean_sponsor_alias() converts ( ) to spaces so the paren regex needs
  # to run first. Catches "Erasmus MC Rotterdam (Erasmus MC)" →
  # candidate without the parenthetical suffix.
  x_no_paren <- stringr::str_remove_all(x, "\\(.*?\\)") |>
    stringr::str_squish() |>
    clean_sponsor_alias()

  # Last token catches trailing acronyms: "...Cancer EORTC" -> "eortc"
  all_toks   <- stringr::str_split(x_no_addr, "\\s+")[[1]]
  last_token <- utils::tail(all_toks, 1)

  toks         <- stringr::str_split(x0, "\\s+")[[1]]
  first_tokens <- paste(utils::head(toks, 3), collapse = " ")

  # Shorter prefix candidates from the most-stripped form:
  # catches "Novartis Pharma Services AG" → "novartis",
  # "Boehringer Ingelheim Pharma GmbH & Co. KG" → "boehringer ingelheim", etc.
  clean_toks <- stringr::str_split(x_no_legal, "\\s+")[[1]]
  first_word <- clean_toks[1]
  first_two  <- paste(utils::head(clean_toks, 2), collapse = " ")

  candidates <- unique(stats::na.omit(c(
    x0, x_no_addr, x_no_paren, x_no_legal, x_no_rd, dept_candidates,
    first_tokens, first_word, first_two, last_token
  )))
  candidates[nchar(candidates) >= 2]
}

# ── Sponsor type classifier ───────────────────────────────────────────────────

classify_sponsor_type <- function(x) {
  lx <- stringr::str_to_lower(dplyr::coalesce(as.character(x), ""))
  dplyr::case_when(
    stringr::str_detect(
      lx,
      "\\b(universit|college|hochschule|universitat|universite|universidade|universidad)\\b"
    ) & !stringr::str_detect(
      lx,
      "\\b(hospital|klinikum|kliniken|medical cent|nhs|medisch centrum)\\b"
    ) ~ "academic",
    stringr::str_detect(
      lx,
      "\\b(hospital|hospitals|clinic|klinikum|kliniken|ospedale|hopital|hpital|ziekenhuis|sjukhus|nhs|chu|chru|umc|amc|istituto irccs|policlinico)\\b"
    ) ~ "hospital",
    stringr::str_detect(
      lx,
      "\\b(foundation|fondation|fondazione|stichting|fundacion|fundacao|fundacion|fundatie)\\b"
    ) ~ "foundation",
    stringr::str_detect(
      lx,
      "\\b(eortc|hovon|sakk|gercor|ecog|hecog|swog|alliance|cooperative group|study group|trial group|network)\\b"
    ) ~ "cooperative_group",
    stringr::str_detect(
      lx,
      "\\b(ministry|government|agency|\\bnih\\b|\\bnci\\b|inserm|nhs england|public health|health authority)\\b"
    ) ~ "public_body",
    stringr::str_detect(
      lx,
      "\\b(charity|charitable|cancer research uk|red cross)\\b"
    ) ~ "charity",
    TRUE ~ "unknown"
  )
}

# ── Fuzzy eligibility ─────────────────────────────────────────────────────────

.fuzzy_block_tokens <- c(
  "university", "hospital", "center", "centre", "institute",
  "research", "foundation", "group", "clinic", "medical",
  "pharma", "pharmaceutical", "biotech", "therapeutics",
  "laboratory", "laboratories", "department", "ministry",
  "office", "trust", "healthcare", "clinical", "services"
)

.fuzzy_eligible <- function(candidates) {
  any(purrr::map_lgl(candidates, function(cand) {
    nchar(cand) >= 6 &&
      !grepl("^\\d", cand) &&
      !(cand %in% .fuzzy_block_tokens)
  }))
}

# ── Alias target precomputation ───────────────────────────────────────────────

prepare_sponsor_alias_targets <- function(aliases) {
  if (nrow(aliases) == 0L) {
    empty <- tibble::tibble()
    return(list(containment = empty, containment_token_index = empty, fuzzy = empty))
  }

  containment <- aliases |>
    dplyr::filter(
      !is.na(alias_clean), !is.na(sponsor_clean),
      confidence_prior >= 0.95,
      nchar(alias_clean) >= 5L,
      !alias_clean %in% .fuzzy_block_tokens
    ) |>
    dplyr::mutate(
      alias_tokens = purrr::map(alias_clean, containment_tokens),
      n_alias_tokens = purrr::map_int(alias_tokens, length),
      signal_tokens = purrr::map(alias_tokens, function(toks) {
        toks[nchar(toks) >= 4L & !toks %in% c(.fuzzy_block_tokens, .entity_generic_tokens)]
      }),
      cross_entity = sponsor_is_cross_entity_combined(alias_clean) |
        sponsor_is_cross_entity_combined(sponsor_clean),
      has_signal_token = purrr::map_lgl(signal_tokens, ~ length(.x) > 0L)
    ) |>
    dplyr::filter(
      !cross_entity,
      has_signal_token,
      n_alias_tokens >= 2L | nchar(alias_clean) >= 7L
    ) |>
    dplyr::mutate(containment_id = dplyr::row_number())

  containment_token_index <- containment |>
    dplyr::select(containment_id, signal_tokens) |>
    tidyr::unnest_longer(signal_tokens, values_to = "signal_token") |>
    dplyr::filter(!is.na(signal_token), signal_token != "") |>
    dplyr::distinct(signal_token, containment_id)

  label_targets <- aliases |>
    dplyr::filter(!is.na(sponsor_clean)) |>
    dplyr::transmute(
      target_label = sponsor_clean,
      target_kind = "sponsor_clean",
      sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, source
    ) |>
    dplyr::distinct(target_label, sponsor_clean, .keep_all = TRUE)

  alias_targets <- aliases |>
    dplyr::filter(
      !is.na(alias_clean), !is.na(sponsor_clean),
      confidence_prior >= 0.95,
      nchar(alias_clean) >= 6L,
      !alias_clean %in% .fuzzy_block_tokens
    ) |>
    dplyr::transmute(
      target_label = alias_clean,
      target_kind = "alias_clean",
      sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, source
    ) |>
    dplyr::distinct(target_label, sponsor_clean, .keep_all = TRUE)

  fuzzy <- dplyr::bind_rows(label_targets, alias_targets) |>
    dplyr::filter(!is.na(target_label), nchar(target_label) >= 6L) |>
    dplyr::mutate(fuzzy_key = substr(target_label, 1L, 1L))

  list(
    containment = containment,
    containment_token_index = containment_token_index,
    fuzzy = fuzzy
  )
}

prepare_sponsor_family_targets <- function(aliases, family_map) {
  empty <- tibble::tibble(
    entity_key = character(),
    seed_anchor_key = character(),
    broad_family = logical(),
    sponsor_clean = character(),
    sponsor_parent = character(),
    sponsor_group = character(),
    sponsor_type = character(),
    source = character(),
    reason = character()
  )
  if (nrow(family_map) == 0L) return(empty)

  required <- c(
    "entity_key", "sponsor_clean_to", "sponsor_parent_to",
    "sponsor_group_to", "sponsor_type_to", "reason"
  )
  if (!all(required %in% names(family_map))) return(empty)

  family_map <- family_map |>
    dplyr::select(dplyr::all_of(required)) |>
    dplyr::mutate(
      dplyr::across(dplyr::everything(), ~ stringr::str_squish(as.character(.x))),
      dplyr::across(dplyr::everything(), ~ dplyr::na_if(.x, "")),
      dplyr::across(dplyr::everything(), ~ dplyr::na_if(.x, "NA")),
      seed_anchor_key = purrr::map_chr(entity_key, entity_anchor_key_one),
      entity_key = purrr::map_chr(entity_key, sponsor_entity_key_one),
      broad_family = stringr::str_detect(
        dplyr::coalesce(reason, ""),
        stringr::regex("family-level canonical merge", ignore_case = TRUE)
      )
    ) |>
    dplyr::filter(
      !is.na(sponsor_clean_to), sponsor_clean_to != "",
      !is_department_label(sponsor_clean_to)
    )

  target_profiles <- sponsor_entity_profile_basic(family_map$sponsor_clean_to)
  family_map <- dplyr::bind_cols(
    family_map,
    target_family_key = target_profiles$entity_family_key,
    target_class_key = target_profiles$entity_class_key
  )

  family_rows <- family_map |>
    dplyr::rowwise() |>
    dplyr::mutate(
      class_list = list({
        classes <- strsplit(dplyr::coalesce(target_class_key, ""), "\\|", fixed = FALSE)[[1L]]
        if (!is.na(sponsor_type_to) && sponsor_type_to == "hospital") classes <- "hospital"
        if (!is.na(sponsor_type_to) && sponsor_type_to == "academic") classes <- "university"
        if (isTRUE(broad_family)) classes <- c(classes, "hospital", "university")
        classes <- unique(classes[classes %in% c("hospital", "university", "foundation", "trust", "institute")])
        if (length(classes) == 0L) character() else classes
      })
    ) |>
    dplyr::ungroup()

  direct <- family_rows |>
    dplyr::transmute(
      key_candidates = purrr::map2(entity_key, target_family_key, ~ unique(c(.x, .y))),
      seed_anchor_key, broad_family,
      sponsor_clean = sponsor_clean_to,
      sponsor_parent = sponsor_parent_to,
      sponsor_group = sponsor_group_to,
      sponsor_type = sponsor_type_to,
      source = "final_family_map",
      reason
    ) |>
    tidyr::unnest_longer(key_candidates, values_to = "entity_key")

  classed_from_anchor <- family_rows |>
    dplyr::filter(!is.na(seed_anchor_key), seed_anchor_key != "") |>
    dplyr::transmute(
      seed_anchor_key, broad_family,
      class_list,
      sponsor_clean = sponsor_clean_to,
      sponsor_parent = sponsor_parent_to,
      sponsor_group = sponsor_group_to,
      sponsor_type = sponsor_type_to,
      source = "final_family_map",
      reason = paste0(dplyr::coalesce(reason, "family-map target"), "; generated from family anchor")
    ) |>
    tidyr::unnest_longer(class_list, values_to = "family_class") |>
    dplyr::mutate(entity_key = paste(seed_anchor_key, family_class)) |>
    dplyr::select(-family_class)

  dplyr::bind_rows(direct, classed_from_anchor) |>
    dplyr::filter(!is.na(entity_key), entity_key != "", !is.na(sponsor_clean), sponsor_clean != "") |>
    dplyr::filter(entity_key_is_classed(entity_key)) |>
    dplyr::distinct(entity_key, sponsor_clean, .keep_all = TRUE)
}

# ── Config loader ─────────────────────────────────────────────────────────────

load_sponsor_configs <- function(
  config_dir = file.path("config", "sponsor_norm_pipeline")
) {
  read_csv_safe <- function(path) {
    if (file.exists(path)) {
      readr::read_csv(path, show_col_types = FALSE)
    } else {
      tibble::tibble()
    }
  }
  # Prefer the generated index (manual + EPAR + ROR) when available;
  # fall back to the hand-maintained seed table plus LLM-reviewed aliases if the
  # index hasn't been built.
  alias_index <- file.path(config_dir, "sponsor_alias_index.csv")
  alias_seed  <- file.path(config_dir, "manual_sponsor_aliases.csv")
  alias_llm   <- file.path(config_dir, "sponsor_llm_reviewed.csv")
  aliases <- if (file.exists(alias_index)) {
    read_csv_safe(alias_index)
  } else {
    dplyr::bind_rows(read_csv_safe(alias_seed), read_csv_safe(alias_llm))
  }
  family_map <- read_csv_safe(file.path(config_dir, "final_sponsor_family_map.csv"))
  targets <- prepare_sponsor_alias_targets(aliases)
  list(
    aliases   = aliases,
    containment_targets = targets$containment,
    containment_token_index = targets$containment_token_index,
    fuzzy_targets = targets$fuzzy,
    family_targets = prepare_sponsor_family_targets(aliases, family_map),
    overrides = read_csv_safe(file.path(config_dir, "manual_sponsor_overrides.csv")),
    negatives = read_csv_safe(file.path(config_dir, "sponsor_negative_aliases.csv"))
  )
}

# ── Internal result constructor ───────────────────────────────────────────────

.result <- function(sponsor_clean,
                    sponsor_parent = NA_character_,
                    sponsor_group  = NA_character_,
                    sponsor_type   = NA_character_,
                    status, score, source, reason) {
  tibble::tibble(
    sponsor_clean  = as.character(sponsor_clean),
    sponsor_parent = as.character(sponsor_parent),
    sponsor_group  = as.character(sponsor_group),
    sponsor_type   = as.character(sponsor_type),
    match_status   = status,
    match_score    = as.numeric(score),
    match_source   = source,
    match_reason   = reason
  )
}

# ── Check functions ───────────────────────────────────────────────────────────

check_override <- function(candidates, cfg) {
  if (nrow(cfg$overrides) == 0) return(NULL)
  hit <- cfg$overrides |>
    dplyr::filter(raw_clean %in% candidates) |>
    dplyr::slice(1)
  if (nrow(hit) == 0) return(NULL)
  .result(
    hit$sponsor_clean[1], hit$sponsor_parent[1],
    hit$sponsor_group[1], hit$sponsor_type[1],
    status = hit$match_status[1], score = 100,
    source = "manual_override", reason = hit$reason[1]
  )
}

check_negative <- function(candidates, cfg) {
  if (nrow(cfg$negatives) == 0) return(NULL)
  hit <- cfg$negatives |>
    dplyr::filter(alias_clean %in% candidates) |>
    dplyr::slice(1)
  if (nrow(hit) == 0) return(NULL)
  .result(
    NA_character_, NA_character_, NA_character_, NA_character_,
    status = "rejected", score = 100,
    source = "negative_aliases", reason = hit$reason[1]
  )
}

check_alias <- function(candidates, cfg) {
  if (nrow(cfg$aliases) == 0) return(NULL)

  hits <- cfg$aliases |>
    dplyr::filter(alias_clean %in% candidates) |>
    dplyr::mutate(
      candidate_rank = match(alias_clean, candidates),
      match_score    = confidence_prior * 100 - candidate_rank
    ) |>
    dplyr::arrange(dplyr::desc(match_score))

  if (nrow(hits) == 0) return(NULL)

  top_score <- hits$match_score[1]
  # Use exact tie-check only: shorter candidates (first_word, first_two) can
  # score just 2 points below a longer exact match, so a wider window produces
  # false ambiguity (e.g. "Aarhus University Hospital" spuriously flagging
  # because first_two = "aarhus university" also hits the university alias).
  top_hits  <- hits |> dplyr::filter(match_score == top_score)

  # Department-/unit-level labels should not become final sponsor labels when
  # a parent organisation is also matched by a stripped candidate.
  non_department_hits <- hits |>
    dplyr::filter(!is_department_label(sponsor_clean))
  if (nrow(non_department_hits) > 0L && any(is_department_label(top_hits$sponsor_clean))) {
    hits <- non_department_hits
    top_score <- hits$match_score[1]
    top_hits <- hits |> dplyr::filter(match_score == top_score)
  }

  if (dplyr::n_distinct(top_hits$sponsor_clean) > 1) {
    return(.result(
      NA_character_, NA_character_, NA_character_, NA_character_,
      status = "review", score = top_score,
      source = paste(unique(top_hits$source), collapse = "|"),
      reason = "ambiguous alias maps to multiple sponsors"
    ))
  }

  hit    <- hits |> dplyr::slice(1)
  score  <- hit$match_score
  status <- if (score >= 90) "accepted" else "review"

  .result(
    hit$sponsor_clean, hit$sponsor_parent,
    hit$sponsor_group, hit$sponsor_type,
    status = status, score = score,
    source = hit$source,
    reason = paste0("alias match: '", hit$alias_clean, "' → '", hit$sponsor_clean, "'")
  )
}

check_family_entity <- function(raw_clean, cfg) {
  targets <- cfg$family_targets
  if (is.null(targets) || nrow(targets) == 0L) return(NULL)
  if (sponsor_is_cross_entity_combined_one(raw_clean)) return(NULL)

  profile <- sponsor_entity_profile(raw_clean)
  keys <- unique(stats::na.omit(c(profile$entity_family_key, profile$department_parent_key)))
  keys <- keys[nzchar(keys) & entity_key_is_classed(keys)]
  if (length(keys) == 0L) return(NULL)

  hits <- targets |>
    dplyr::filter(entity_key %in% keys)
  if (nrow(hits) == 0L && !is.na(profile$entity_anchor_key) && nzchar(profile$entity_anchor_key)) {
    raw_anchor <- profile$entity_anchor_key[[1L]]
    raw_classes <- strsplit(dplyr::coalesce(profile$entity_class_key[[1L]], ""), "\\|", fixed = FALSE)[[1L]]
    raw_family_class <- dplyr::case_when(
      "hospital" %in% raw_classes ~ "hospital",
      "foundation" %in% raw_classes ~ "foundation",
      "trust" %in% raw_classes ~ "trust",
      "institute" %in% raw_classes ~ "institute",
      "university" %in% raw_classes ~ "university",
      TRUE ~ NA_character_
    )
    hits <- targets |>
      dplyr::filter(
        broad_family | stringr::str_ends(entity_key, paste0("\\b", raw_family_class, "$")),
        !is.na(seed_anchor_key), seed_anchor_key != "",
        raw_anchor == seed_anchor_key |
          stringr::str_starts(raw_anchor, paste0(seed_anchor_key, " ")) |
          stringr::str_detect(paste0(" ", raw_anchor, " "), stringr::fixed(paste0(" ", seed_anchor_key, " ")))
      )
  }
  if (nrow(hits) == 0L) return(NULL)

  if (dplyr::n_distinct(hits$sponsor_clean) > 1L) {
    return(.result(
      NA_character_, NA_character_, NA_character_, NA_character_,
      status = "review", score = 92,
      source = paste(unique(hits$source), collapse = "|"),
      reason = paste0("ambiguous entity-family match: ", paste(keys, collapse = "|"))
    ))
  }

  hit <- hits |> dplyr::slice(1)
  .result(
    hit$sponsor_clean, hit$sponsor_parent,
    hit$sponsor_group, hit$sponsor_type,
    status = "accepted", score = 95,
    source = hit$source,
    reason = paste0("entity-family match: ", paste(keys, collapse = "|"), " → '", hit$sponsor_clean, "'")
  )
}

check_containment <- function(raw_clean, candidates, cfg) {
  if (nrow(cfg$aliases) == 0) return(NULL)

  candidate_texts <- unique(stats::na.omit(c(raw_clean, candidates)))
  candidate_texts <- candidate_texts[
    nchar(candidate_texts) >= 8L &
      !sponsor_is_cross_entity_combined(candidate_texts)
  ]
  if (length(candidate_texts) == 0L) return(NULL)

  candidate_token_sets <- purrr::map(candidate_texts, containment_tokens)
  candidate_signal_tokens <- unique(unlist(purrr::map(candidate_token_sets, function(toks) {
    toks[nchar(toks) >= 4L & !toks %in% c(.fuzzy_block_tokens, .entity_generic_tokens)]
  }), use.names = FALSE))
  if (length(candidate_signal_tokens) == 0L) return(NULL)

  target_ids <- cfg$containment_token_index |>
    dplyr::filter(signal_token %in% candidate_signal_tokens) |>
    dplyr::pull(containment_id) |>
    unique()
  if (length(target_ids) == 0L) return(NULL)

  targets <- cfg$containment_targets |>
    dplyr::filter(containment_id %in% target_ids)

  if (nrow(targets) == 0L) return(NULL)

  matches <- targets |>
    dplyr::mutate(
      contains = purrr::map_lgl(alias_tokens, function(needle) {
        any(purrr::map_lgl(
          candidate_token_sets,
          token_sequence_contains,
          needle = needle
        ))
      })
    ) |>
    dplyr::filter(contains) |>
    dplyr::mutate(
      match_score = confidence_prior * 100,
      alias_len = nchar(alias_clean)
    ) |>
    dplyr::arrange(dplyr::desc(match_score), dplyr::desc(alias_len))

  if (nrow(matches) == 0L) return(NULL)

  top_score <- matches$match_score[[1L]]
  top_hits <- matches |>
    dplyr::filter(match_score == top_score) |>
    dplyr::filter(alias_len == max(alias_len))

  if (dplyr::n_distinct(top_hits$sponsor_clean) > 1L) {
    return(.result(
      NA_character_, NA_character_, NA_character_, NA_character_,
      status = "review", score = top_score,
      source = paste(unique(top_hits$source), collapse = "|"),
      reason = "ambiguous high-confidence alias containment"
    ))
  }

  hit <- top_hits |> dplyr::slice(1)
  .result(
    hit$sponsor_clean, hit$sponsor_parent,
    hit$sponsor_group, hit$sponsor_type,
    status = if (top_score >= 90) "accepted" else "review",
    score = top_score,
    source = paste0("containment:", hit$source),
    reason = paste0("alias containment: '", hit$alias_clean, "' → '", hit$sponsor_clean, "'")
  )
}

check_fuzzy <- function(candidates, cfg) {
  if (nrow(cfg$aliases) == 0) return(NULL)

  targets <- cfg$fuzzy_targets

  if (nrow(targets) == 0) return(NULL)

  eligible <- candidates[
    nchar(candidates) >= 6 & !candidates %in% .fuzzy_block_tokens
  ]
  if (length(eligible) == 0) return(NULL)

  best_score <- 0
  best_row   <- NULL

  for (cand in eligible) {
    target_subset <- targets |>
      dplyr::filter(fuzzy_key == substr(cand, 1L, 1L))
    if (nrow(target_subset) == 0L) next

    sims <- 1 - stringdist::stringdist(cand, target_subset$target_label, method = "jw")
    idx  <- which.max(sims)
    if (sims[idx] > best_score) {
      best_score <- sims[idx]
      best_row   <- target_subset[idx, , drop = FALSE]
    }
  }

  if (is.null(best_row) || best_score < 0.92) return(NULL)

  score <- round(best_score * 100)
  .result(
    best_row$sponsor_clean, best_row$sponsor_parent,
    best_row$sponsor_group, best_row$sponsor_type,
    status = "review", score = score,
    source = paste0("fuzzy:", best_row$source),
    reason = paste0(
      "fuzzy ", best_row$target_kind, " match to '", best_row$target_label,
      "' (jw similarity ", score, "%)"
    )
  )
}

# ── Core normaliser ───────────────────────────────────────────────────────────

.return_sponsor <- function(raw, r) {
  dplyr::bind_cols(tibble::tibble(raw_sponsor = raw), r)
}

normalise_one <- function(raw, cfg, allow_fuzzy = TRUE) {
  raw_clean  <- clean_sponsor_alias(raw)
  candidates <- make_sponsor_candidates(raw)
  cross_entity <- sponsor_is_cross_entity_combined_one(raw_clean)

  r <- check_override(candidates, cfg)
  if (!is.null(r)) return(.return_sponsor(raw, r))

  r <- check_negative(candidates, cfg)
  if (!is.null(r)) return(.return_sponsor(raw, r))

  raw_profile <- sponsor_entity_profile(raw_clean)
  if (
    is_department_label(raw_clean) &&
      (is.na(raw_profile$entity_class_key[[1L]]) ||
        identical(raw_profile$entity_class_key[[1L]], "department"))
  ) {
    return(.return_sponsor(raw, .result(
      NA_character_, NA_character_, NA_character_, "unknown",
      status = "unknown", score = 0,
      source = NA_character_,
      reason = "generic department label without parent institution"
    )))
  }

  if (!cross_entity) {
    r <- check_family_entity(raw_clean, cfg)
    if (!is.null(r)) return(.return_sponsor(raw, r))
  }

  r <- check_alias(if (cross_entity) raw_clean else candidates, cfg)
  if (!is.null(r)) return(.return_sponsor(raw, r))

  if (cross_entity) {
    return(.return_sponsor(raw, .result(
      stringr::str_squish(as.character(raw)),
      NA_character_, NA_character_, classify_sponsor_type(raw_clean),
      status = "accepted", score = 100,
      source = "combined_preserved",
      reason = "combined multi-entity sponsor preserved without sub-entity collapse"
    )))
  }

  r <- check_containment(raw_clean, candidates, cfg)
  if (!is.null(r)) return(.return_sponsor(raw, r))

  if (allow_fuzzy && .fuzzy_eligible(candidates)) {
    r <- check_fuzzy(candidates, cfg)
    if (!is.null(r)) return(.return_sponsor(raw, r))
  }

  .return_sponsor(raw, .result(
    NA_character_, NA_character_, NA_character_,
    sponsor_type = classify_sponsor_type(raw_clean),
    status = "unknown", score = 0,
    source = NA_character_, reason = "no reliable sponsor match"
  ))
}

normalise_sponsors <- function(raw_vec,
                               config_dir  = "config",
                               configs     = NULL,
                               allow_fuzzy = TRUE) {
  `%||%` <- function(a, b) if (!is.null(a)) a else b
  cfg         <- configs %||% load_sponsor_configs(config_dir)
  if (
      is.null(cfg$containment_targets) ||
      is.null(cfg$containment_token_index) ||
      is.null(cfg$fuzzy_targets) ||
      is.null(cfg$family_targets)
  ) {
    targets <- prepare_sponsor_alias_targets(cfg$aliases)
    cfg$containment_targets <- targets$containment
    cfg$containment_token_index <- targets$containment_token_index
    cfg$fuzzy_targets <- targets$fuzzy
    cfg$family_targets <- tibble::tibble()
  }
  unique_vals <- unique(as.character(raw_vec))
  unique_vals <- unique_vals[!is.na(unique_vals) & nzchar(trimws(unique_vals))]

  if (length(unique_vals) == 0) {
    return(tibble::tibble(
      raw_sponsor    = character(),
      sponsor_clean  = character(),
      sponsor_parent = character(),
      sponsor_group  = character(),
      sponsor_type   = character(),
      match_status   = character(),
      match_score    = numeric(),
      match_source   = character(),
      match_reason   = character()
    ))
  }

  lookup <- purrr::map_dfr(
    unique_vals, ~ normalise_one(.x, cfg = cfg, allow_fuzzy = allow_fuzzy)
  ) |>
    dplyr::mutate(
      suggested_clean = dplyr::if_else(
        !is.na(sponsor_clean),
        sponsor_clean,
        purrr::map_chr(raw_sponsor, suggest_sponsor_clean)
      )
    )
  tibble::tibble(raw_sponsor = as.character(raw_vec)) |>
    dplyr::left_join(lookup, by = "raw_sponsor")
}

# ── CLI entry point ───────────────────────────────────────────────────────────
if (!interactive() && sys.nframe() == 0L) {
  args      <- commandArgs(trailingOnly = TRUE)
  get_arg   <- function(prefix) {
    v <- args[startsWith(args, prefix)]
    if (length(v) == 0) return(NULL)
    stringr::str_remove(v[1], paste0("^", prefix))
  }
  `%||%` <- function(a, b) if (!is.null(a)) a else b

  input_csv   <- get_arg("--input=")
  output_csv  <- get_arg("--output=")
  config_dir  <- get_arg("--config-dir=") %||%
    file.path("config", "sponsor_norm_pipeline")
  write_queue <- "--write-queue" %in% args
  no_fuzzy    <- "--no-fuzzy"    %in% args

  if (is.null(input_csv) || !file.exists(input_csv)) {
    stop("Provide --input=path/to/file.csv with a raw_sponsor column")
  }
  if (is.null(output_csv)) {
    stop("Provide --output=path/to/result.csv")
  }

  df <- readr::read_csv(input_csv, show_col_types = FALSE)
  if (!"raw_sponsor" %in% names(df)) {
    stop(
      "Input CSV has no 'raw_sponsor' column.\n",
      "Columns found: ", paste(names(df), collapse = ", ")
    )
  }

  out <- normalise_sponsors(
    df$raw_sponsor,
    config_dir  = config_dir,
    allow_fuzzy = !no_fuzzy
  )
  if ("n_trials" %in% names(df)) {
    out <- dplyr::left_join(
      out, dplyr::select(df, raw_sponsor, n_trials),
      by = "raw_sponsor"
    )
  }

  readr::write_csv(out, output_csv)
  message(sprintf("Wrote %d rows to %s", nrow(out), output_csv))

  if (write_queue) {
    queue_path <- file.path(config_dir, "sponsor_review_queue.csv")
    out_q <- if ("n_trials" %in% names(out)) out else
      dplyr::mutate(out, n_trials = 1L)

    queue <- out_q |>
      dplyr::filter(match_status %in% c("review", "unknown")) |>
      dplyr::group_by(
        raw_sponsor, candidate_sponsor = sponsor_clean, sponsor_type,
        match_status, match_score, match_source, match_reason
      ) |>
      dplyr::summarise(n_trials = sum(n_trials, na.rm = TRUE), .groups = "drop") |>
      dplyr::arrange(dplyr::desc(n_trials)) |>
      dplyr::mutate(
        decision         = NA_character_,
        canonical_sponsor = NA_character_,
        comment          = NA_character_
      )

    readr::write_csv(queue, queue_path)
    message(sprintf(
      "Wrote %d review/unknown rows to %s", nrow(queue), queue_path
    ))
  }
}
