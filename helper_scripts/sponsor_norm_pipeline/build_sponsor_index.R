# Build config/sponsor_norm_pipeline/sponsor_alias_index.csv
# from manual aliases, EMA EPAR MAH names, and optionally ROR + DB-sourced tiers.
#
# Sources (priority order):
#   1. manual_sponsor_aliases.csv  (seed, confidence 1.00) — always included
#   2. sponsor_llm_reviewed.csv (accepted queue decisions, confidence 1.00)
#   3. EMA EPAR Marketing Authorisation Holders (confidence 0.85) — MAH name variants
#      for sponsors already in the manual alias table
#   4. ROR academic/hospital name variants (confidence 0.75, --no-ror to skip)
#   5. CTIS businessKey EMA org IDs (confidence 0.95, --no-businesskey to skip)
#      Ground-truth aliases: EMA's own organisation registry links name variants.
#   6. EUCTR email domain (confidence 0.85, --no-email to skip)
#      Sponsors sharing a corporate email domain → same canonical.
#      CRO / generic / NHS-shared domains are blocked.
#   7. Postcode + country + JW name similarity (confidence 0.70, --no-location to skip)
#      Same registered postcode + similar name → institution alias candidate.
#      Only proposed when one name already resolves to a known canonical.
#
# Strategy: for EPAR/ROR, we look up each external name against the manual alias
# table using the same candidate generation logic. If a match is found, the
# external name becomes an additional alias for that canonical sponsor.
# Unmatched external names are written to new_sponsor_candidates.csv for review.
#
# For DB-sourced tiers (4-6), aliases are only added when the resolved names for
# a given businessKey / domain / location group all agree on the same canonical.
# Ambiguous groups are silently skipped.
#
# Usage:
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-epar
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-db
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-businesskey --no-location
#
# Environment:
#   DB_PATH  path to trials.sqlite (default: <project>/data/trials.sqlite)
#
# Outputs:
#   config/sponsor_norm_pipeline/sponsor_alias_index.csv       full merged alias table
#   config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv      accepted queue decisions
#   config/sponsor_norm_pipeline/sponsor_ambiguous_aliases.csv aliases → multiple sponsors
#   config/sponsor_norm_pipeline/new_sponsor_candidates.csv    unmatched for manual review

suppressPackageStartupMessages({
  library(httr2)
  library(readxl)
  library(dplyr)
  library(stringr)
  library(stringi)
  library(readr)
  library(purrr)
  library(tibble)
  library(tidyr)
})

script_path <- local({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  ofiles <- vapply(sys.frames(), function(frame) {
    if (!is.null(frame$ofile)) frame$ofile else NA_character_
  }, character(1))
  ofiles <- ofiles[!is.na(ofiles)]
  if (length(ofiles)) normalizePath(ofiles[[length(ofiles)]], mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)

args            <- commandArgs(trailingOnly = TRUE)
no_epar         <- "--no-epar"         %in% args
no_ror          <- "--no-ror"          %in% args
no_db           <- "--no-db"           %in% args
no_businesskey  <- "--no-businesskey"  %in% args
no_email        <- "--no-email"        %in% args
no_location     <- "--no-location"     %in% args

SNP          <- project_path("config", "sponsor_norm_pipeline")
OUT_INDEX    <- file.path(SNP, "sponsor_alias_index.csv")
OUT_LLM      <- file.path(SNP, "sponsor_llm_reviewed.csv")
OUT_AMBIG    <- file.path(SNP, "sponsor_ambiguous_aliases.csv")
OUT_NEW      <- file.path(SNP, "new_sponsor_candidates.csv")
OUT_ORGS     <- file.path(SNP, "ctis_org_candidates.csv")
OUT_LOC_REVIEW <- file.path(SNP, "postcode_sponsor_candidates.csv")
OUT_FINAL_MAP    <- file.path(SNP, "final_sponsor_canonical_map.csv")
OUT_FINAL_FAMILY_MAP <- file.path(SNP, "final_sponsor_family_map.csv")
OUT_FINAL_REVIEW <- file.path(SNP, "final_sponsor_canonical_review.csv")

# ── Load normaliser helpers ───────────────────────────────────────────────────
source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = FALSE
)

null_coalesce <- function(a, b) {
  if (!is.null(a)) a else b
}

prefer_llm_reviewed <- function(rows) {
  rows |>
    dplyr::group_by(alias_clean) |>
    dplyr::mutate(has_llm_reviewed = any(source == "llm_reviewed")) |>
    dplyr::filter(!(has_llm_reviewed & source == "bulk_reviewed")) |>
    dplyr::ungroup() |>
    dplyr::select(-has_llm_reviewed)
}

collapse_text <- function(x) {
  x |>
    stringi::stri_trans_general("Latin-ASCII") |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("&", " and ") |>
    stringr::str_replace_all("[^a-z0-9]+", " ") |>
    stringr::str_squish()
}

final_exact_key <- function(x) {
  collapse_text(x) |>
    stringr::str_replace_all("\\s+", "")
}

final_stripped_key <- function(x) {
  s <- collapse_text(x)
  s <- stringr::str_remove_all(s, stringr::regex(paste0(
    "\\b(",
    paste(c(
      "the", "of", "for", "and",
      "inc", "incorporated", "corp", "corporation", "company", "co",
      "ltd", "limited", "llc", "plc", "ag", "gmbh", "kg", "kgaa",
      "bv", "nv", "sa", "sas", "srl", "spa", "ab", "oy", "pte", "kk",
      "group", "groupe", "foundation", "fundacion", "fundacao",
      "fondation", "fondazione", "stichting"
    ), collapse = "|"),
    ")\\b"
  ), ignore_case = TRUE))
  stringr::str_squish(s)
}

normalise_final_type <- function(x) {
  x <- as.character(x)
  x[is.na(x) | x == "" | x == "NA" | x == "unknown"] <- NA_character_
  x
}

first_non_missing <- function(x) {
  x <- as.character(x)
  x <- x[!is.na(x) & x != "" & x != "NA"]
  if (length(x) == 0L) NA_character_ else x[[1L]]
}

final_types_compatible <- function(types) {
  length(unique(stats::na.omit(normalise_final_type(types)))) <= 1L
}

is_short_acronym_label <- function(label) {
  clean <- stringr::str_replace_all(label, "[^A-Za-z0-9]", "")
  nchar(clean) >= 2L && nchar(clean) <= 5L && clean == toupper(clean)
}

short_acronym_safe <- function(labels) {
  acronyms <- labels[purrr::map_lgl(labels, is_short_acronym_label)]
  if (length(acronyms) == 0L) return(TRUE)
  text <- collapse_text(paste(labels, collapse = " "))
  all(purrr::map_lgl(acronyms, function(acr) {
    stringr::str_detect(text, paste0("\\b", collapse_text(acr), "\\b"))
  }))
}

review_bucket_for_key <- function(key) {
  first <- stringr::str_to_upper(substr(key, 1L, 1L))
  dplyr::case_when(
    first >= "A" & first <= "F" ~ "A-F",
    first >= "G" & first <= "L" ~ "G-L",
    first >= "M" & first <= "R" ~ "M-R",
    first >= "S" & first <= "Z" ~ "S-Z",
    TRUE ~ "other"
  )
}

entity_key_is_classed <- function(key) {
  stringr::str_detect(
    dplyr::coalesce(as.character(key), ""),
    "\\b(hospital|university|foundation|trust|institute)\\b$"
  )
}

pick_final_canonical <- function(labels, combined) {
  source_priority <- c(
    manual = 1, llm_reviewed = 2, review_queue = 3, bulk_reviewed = 4,
    ctis_businesskey = 5, epar_mah = 6, ror = 7
  )
  candidates <- combined |>
    dplyr::filter(sponsor_clean %in% labels) |>
    dplyr::mutate(
      source_priority = dplyr::coalesce(source_priority[source], 99),
      label_len = nchar(sponsor_clean)
    ) |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(
      source_priority = min(source_priority, na.rm = TRUE),
      label_len = min(label_len, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(source_priority, label_len, sponsor_clean)
  candidates$sponsor_clean[[1L]]
}

apply_explicit_final_map <- function(combined, map_path) {
  empty_map <- tibble::tibble(
    sponsor_clean_from = character(),
    sponsor_clean_to = character(),
    sponsor_parent_to = character(),
    sponsor_group_to = character(),
    sponsor_type_to = character(),
    reason = character()
  )

  final_map <- if (file.exists(map_path)) {
    readr::read_csv(map_path, show_col_types = FALSE)
  } else {
    empty_map
  }

  required <- names(empty_map)
  missing_cols <- setdiff(required, names(final_map))
  if (length(missing_cols)) {
    stop(
      "Final sponsor canonical map is missing columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  final_map <- final_map |>
    dplyr::select(dplyr::all_of(required)) |>
    dplyr::mutate(
      dplyr::across(dplyr::everything(), ~ stringr::str_squish(as.character(.x))),
      dplyr::across(
        c(sponsor_parent_to, sponsor_group_to, sponsor_type_to, reason),
        ~ dplyr::na_if(.x, "")
      )
    ) |>
    dplyr::filter(
      !is.na(sponsor_clean_from), sponsor_clean_from != "",
      !is.na(sponsor_clean_to), sponsor_clean_to != "",
      sponsor_clean_from != sponsor_clean_to
    )

  if (nrow(final_map) == 0L) return(combined)

  dup_from <- final_map |>
    dplyr::count(sponsor_clean_from, name = "n") |>
    dplyr::filter(n > 1L)
  if (nrow(dup_from) > 0L) {
    stop(
      "Final sponsor canonical map has duplicate sponsor_clean_from values: ",
      paste(dup_from$sponsor_clean_from, collapse = ", ")
    )
  }

  to_lookup <- stats::setNames(final_map$sponsor_clean_to, final_map$sponsor_clean_from)
  resolve_target <- function(label) {
    seen <- character()
    current <- label
    while (current %in% names(to_lookup)) {
      if (current %in% seen) {
        stop(
          "Final sponsor canonical map contains a cycle: ",
          paste(c(seen, current), collapse = " -> ")
        )
      }
      seen <- c(seen, current)
      current <- to_lookup[[current]]
    }
    current
  }

  resolved <- tibble::tibble(
    sponsor_clean = unique(combined$sponsor_clean),
    sponsor_clean_final = purrr::map_chr(unique(combined$sponsor_clean), resolve_target)
  )

  map_meta <- final_map |>
    dplyr::transmute(
      sponsor_clean = sponsor_clean_from,
      sponsor_clean_final = sponsor_clean_to,
      sponsor_parent_map = sponsor_parent_to,
      sponsor_group_map = sponsor_group_to,
      sponsor_type_map = sponsor_type_to
    )

  final_defaults <- combined |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(
      sponsor_parent_default = first_non_missing(sponsor_parent),
      sponsor_group_default = first_non_missing(sponsor_group),
      sponsor_type_default = first_non_missing(sponsor_type),
      .groups = "drop"
    ) |>
    dplyr::rename(sponsor_clean_final = sponsor_clean)

  combined |>
    dplyr::left_join(resolved, by = "sponsor_clean") |>
    dplyr::left_join(map_meta, by = c("sponsor_clean", "sponsor_clean_final")) |>
    dplyr::left_join(final_defaults, by = "sponsor_clean_final") |>
    dplyr::mutate(
      sponsor_clean = sponsor_clean_final,
      sponsor_parent = dplyr::coalesce(sponsor_parent_map, sponsor_parent_default, sponsor_parent),
      sponsor_group = dplyr::coalesce(sponsor_group_map, sponsor_group_default, sponsor_group),
      sponsor_type = dplyr::coalesce(sponsor_type_map, sponsor_type_default, sponsor_type)
    ) |>
    dplyr::select(
      alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
      sponsor_type, alias_type, source, confidence_prior
	    )
}

final_review_empty <- function() {
  tibble::tibble(
    cluster_key = character(),
    entity_key = character(),
    entity_anchor_key = character(),
    entity_class_key = character(),
    department_parent_key = character(),
    suggested_canonical = character(),
    sponsor_labels = character(),
    aliases_sample = character(),
    sources = character(),
    sponsor_types = character(),
    score = numeric(),
    evidence = character(),
    confidence_bucket = character(),
    blocked_reason = character(),
    review_bucket = character(),
    applied = logical()
  )
}

ensure_final_review_schema <- function(review) {
  empty <- final_review_empty()
  if (is.null(review) || nrow(review) == 0L) return(empty)
  missing_cols <- setdiff(names(empty), names(review))
  for (nm in missing_cols) {
    review[[nm]] <- if (is.logical(empty[[nm]])) {
      rep(NA, nrow(review))
    } else if (is.numeric(empty[[nm]])) {
      rep(NA_real_, nrow(review))
    } else {
      rep(NA_character_, nrow(review))
    }
  }
  review[, names(empty), drop = FALSE]
}

read_final_family_map <- function(map_path) {
  empty_map <- tibble::tibble(
    entity_key = character(),
    sponsor_clean_to = character(),
    sponsor_parent_to = character(),
    sponsor_group_to = character(),
    sponsor_type_to = character(),
    reason = character()
  )

  family_map <- if (file.exists(map_path)) {
    readr::read_csv(map_path, show_col_types = FALSE)
  } else {
    empty_map
  }

  required <- names(empty_map)
  missing_cols <- setdiff(required, names(family_map))
  if (length(missing_cols)) {
    stop(
      "Final sponsor family map is missing columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  family_map |>
    dplyr::select(dplyr::all_of(required)) |>
    dplyr::mutate(
      dplyr::across(dplyr::everything(), ~ stringr::str_squish(as.character(.x))),
      dplyr::across(dplyr::everything(), ~ dplyr::na_if(.x, "")),
      dplyr::across(dplyr::everything(), ~ dplyr::na_if(.x, "NA")),
      entity_key = purrr::map_chr(entity_key, sponsor_entity_key_one)
    ) |>
    dplyr::filter(
      !is.na(entity_key), entity_key != "",
      !is.na(sponsor_clean_to), sponsor_clean_to != ""
    ) |>
    dplyr::distinct(entity_key, .keep_all = TRUE)
}

expand_final_family_map <- function(combined, family_map) {
  if (nrow(family_map) == 0L) return(family_map)

  configured_keys <- family_map$entity_key

  generated_from_target <- combined |>
    dplyr::semi_join(family_map, by = c("sponsor_clean" = "sponsor_clean_to")) |>
    dplyr::filter(
      !sponsor_is_cross_entity_combined(alias_clean),
      !sponsor_is_cross_entity_combined(sponsor_clean)
    ) |>
    dplyr::mutate(
      alias_entity_key = sponsor_entity_key(alias_clean),
      label_entity_key = sponsor_entity_key(sponsor_clean)
    ) |>
    dplyr::select(
      sponsor_clean_to = sponsor_clean,
      sponsor_parent_to = sponsor_parent,
      sponsor_group_to = sponsor_group,
      sponsor_type_to = sponsor_type,
      alias_entity_key,
      label_entity_key
    ) |>
    tidyr::pivot_longer(
      c(alias_entity_key, label_entity_key),
      names_to = "key_source",
      values_to = "entity_key"
    ) |>
    dplyr::filter(!is.na(entity_key), entity_key != "", nchar(entity_key) >= 3L) |>
    dplyr::left_join(
      family_map |>
        dplyr::select(
          sponsor_clean_to,
          sponsor_parent_map = sponsor_parent_to,
          sponsor_group_map = sponsor_group_to,
          sponsor_type_map = sponsor_type_to,
          reason
        ),
      by = "sponsor_clean_to"
    ) |>
    dplyr::transmute(
      entity_key,
      sponsor_clean_to,
      sponsor_parent_to = dplyr::coalesce(sponsor_parent_map, sponsor_parent_to),
      sponsor_group_to = dplyr::coalesce(sponsor_group_map, sponsor_group_to),
      sponsor_type_to = dplyr::coalesce(sponsor_type_map, sponsor_type_to),
      reason = paste0(
        dplyr::coalesce(reason, "family-map target"),
        "; generated from target sponsor aliases"
      )
    ) |>
    dplyr::filter(entity_key_is_classed(entity_key)) |>
    dplyr::distinct(entity_key, sponsor_clean_to, .keep_all = TRUE)

  generated_conflicts <- generated_from_target |>
    dplyr::filter(!entity_key %in% configured_keys) |>
    dplyr::count(entity_key, name = "n_targets") |>
    dplyr::filter(n_targets > 1L)

  dplyr::bind_rows(
    family_map |>
      dplyr::filter(entity_key_is_classed(entity_key)),
    generated_from_target |>
      dplyr::filter(!entity_key %in% generated_conflicts$entity_key)
  ) |>
    dplyr::arrange(!entity_key %in% configured_keys, entity_key, sponsor_clean_to) |>
    dplyr::distinct(entity_key, .keep_all = TRUE)
}

build_final_family_review <- function(combined, family_map) {
  label_stats <- combined |>
    dplyr::filter(!is.na(sponsor_clean), sponsor_clean != "") |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(
      sponsor_types = paste(sort(unique(stats::na.omit(sponsor_type))), collapse = "|"),
      sources = paste(sort(unique(stats::na.omit(source))), collapse = "|"),
      aliases_sample = paste(utils::head(sort(unique(alias_clean)), 8L), collapse = "|"),
      label_blocked = sponsor_is_cross_entity_combined_one(sponsor_clean[[1L]]),
      .groups = "drop"
    )

  label_stats <- dplyr::bind_cols(
    label_stats,
    sponsor_entity_profile(label_stats$sponsor_clean)
  )

  label_stats <- label_stats |>
    dplyr::mutate(label_entity_key = entity_family_key)

  label_members <- label_stats |>
    dplyr::transmute(
      entity_key = label_entity_key,
      sponsor_clean,
      member_blocked = label_blocked,
      evidence = paste0(
        "shared final-label entity key",
        "; anchor=", dplyr::coalesce(entity_anchor_key, ""),
        "; class=", dplyr::coalesce(entity_class_key, "")
      )
    )

  alias_source <- combined |>
    dplyr::filter(!is.na(alias_clean), !is.na(sponsor_clean))

  alias_members <- dplyr::bind_cols(
    alias_source,
    sponsor_entity_profile_basic(alias_source$alias_clean)
  ) |>
    dplyr::mutate(
      entity_key = entity_family_key,
      member_blocked = sponsor_is_cross_entity_combined(alias_clean) |
        sponsor_is_cross_entity_combined(sponsor_clean),
      evidence = paste0(
        "shared alias entity key",
        "; anchor=", dplyr::coalesce(entity_anchor_key, ""),
        "; class=", dplyr::coalesce(entity_class_key, ""),
        "; department_parent=", dplyr::coalesce(department_parent_key, "")
      )
    ) |>
    dplyr::select(entity_key, sponsor_clean, member_blocked, evidence)

  members <- dplyr::bind_rows(label_members, alias_members) |>
    dplyr::filter(!is.na(entity_key), entity_key != "", nchar(entity_key) >= 3L) |>
    dplyr::distinct(entity_key, sponsor_clean, member_blocked, evidence)

  if (nrow(members) == 0L) return(final_review_empty())

  keep_keys <- members |>
    dplyr::group_by(entity_key) |>
    dplyr::summarise(n_labels = dplyr::n_distinct(sponsor_clean), .groups = "drop") |>
    dplyr::filter(n_labels > 1L | entity_key %in% family_map$entity_key)

  members <- members |>
    dplyr::semi_join(keep_keys, by = "entity_key") |>
    dplyr::left_join(label_stats, by = "sponsor_clean") |>
    dplyr::left_join(family_map, by = "entity_key") |>
    dplyr::mutate(
      mapped = !is.na(sponsor_clean_to),
      label_key_matches = label_entity_key == entity_key,
      member_blocked = member_blocked | (mapped & !label_key_matches),
      confidence_bucket = dplyr::case_when(
        member_blocked ~ "blocked",
        mapped ~ "auto",
        TRUE ~ "review"
      )
    )

  if (nrow(members) == 0L) return(final_review_empty())

  members |>
    dplyr::group_by(entity_key, confidence_bucket) |>
    dplyr::summarise(
      sponsor_labels = paste(sort(unique(sponsor_clean)), collapse = "|"),
      labels_list = list(sort(unique(sponsor_clean))),
      entity_anchor_key = paste(sort(unique(stats::na.omit(entity_anchor_key))), collapse = "|"),
      entity_class_key = paste(sort(unique(stats::na.omit(entity_class_key))), collapse = "|"),
      department_parent_key = paste(sort(unique(stats::na.omit(department_parent_key))), collapse = "|"),
      aliases_sample = paste(utils::head(sort(unique(unlist(strsplit(aliases_sample, "\\|", fixed = FALSE)))), 8L), collapse = "|"),
      sources = paste(sort(unique(unlist(strsplit(sources, "\\|", fixed = FALSE)))), collapse = "|"),
      sponsor_types = paste(sort(unique(unlist(strsplit(sponsor_types, "\\|", fixed = FALSE)))), collapse = "|"),
      suggested_canonical = first_non_missing(sponsor_clean_to),
      evidence = paste(sort(unique(evidence)), collapse = "; "),
      map_reason = first_non_missing(reason),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      suggested_canonical = dplyr::if_else(
        is.na(suggested_canonical) | suggested_canonical == "",
        purrr::map_chr(labels_list, pick_final_canonical, combined = combined),
        suggested_canonical
      ),
      cluster_key = paste0("entity:", entity_key, ":", confidence_bucket),
      score = dplyr::case_when(
        confidence_bucket == "auto" ~ 100,
        confidence_bucket == "review" ~ 92,
        TRUE ~ 0
      ),
      evidence = dplyr::if_else(
        !is.na(map_reason) & map_reason != "",
        paste(evidence, map_reason, sep = "; "),
        evidence
      ),
      blocked_reason = dplyr::case_when(
        confidence_bucket == "blocked" ~
          "combined multi-entity label or alias-only family evidence excluded from auto-map",
        TRUE ~ NA_character_
      ),
      review_bucket = purrr::map_chr(entity_key, review_bucket_for_key),
      applied = confidence_bucket == "auto"
    ) |>
    dplyr::select(
      cluster_key, entity_key, entity_anchor_key, entity_class_key,
      department_parent_key, suggested_canonical, sponsor_labels,
      aliases_sample, sources, sponsor_types, score, evidence,
      confidence_bucket, blocked_reason, review_bucket, applied
    ) |>
    dplyr::arrange(review_bucket, entity_key, confidence_bucket)
}

apply_final_family_canonicalization <- function(combined, family_map_path) {
  family_map <- read_final_family_map(family_map_path)
  family_map <- expand_final_family_map(combined, family_map)
  review <- build_final_family_review(combined, family_map)

  if (nrow(family_map) == 0L) {
    return(list(combined = combined, review = review))
  }

  target_defaults <- combined |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(
      sponsor_parent_default = first_non_missing(sponsor_parent),
      sponsor_group_default = first_non_missing(sponsor_group),
      sponsor_type_default = first_non_missing(sponsor_type),
      .groups = "drop"
    ) |>
    dplyr::rename(sponsor_clean_to = sponsor_clean)

  mapped <- combined |>
    dplyr::mutate(
      entity_key = sponsor_entity_key(sponsor_clean),
      cross_entity = sponsor_is_cross_entity_combined(sponsor_clean)
    ) |>
    dplyr::left_join(family_map, by = "entity_key") |>
    dplyr::left_join(target_defaults, by = "sponsor_clean_to") |>
    dplyr::mutate(
      apply_family = !is.na(sponsor_clean_to) & !cross_entity,
      sponsor_clean = dplyr::if_else(apply_family, sponsor_clean_to, sponsor_clean),
      sponsor_parent = dplyr::if_else(
        apply_family,
        dplyr::coalesce(sponsor_parent_to, sponsor_parent_default, sponsor_parent),
        sponsor_parent
      ),
      sponsor_group = dplyr::if_else(
        apply_family,
        dplyr::coalesce(sponsor_group_to, sponsor_group_default, sponsor_group),
        sponsor_group
      ),
      sponsor_type = dplyr::if_else(
        apply_family,
        dplyr::coalesce(sponsor_type_to, sponsor_type_default, sponsor_type),
        sponsor_type
      )
    ) |>
    dplyr::select(
      alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
      sponsor_type, alias_type, source, confidence_prior
    )

  message(sprintf(
    "Final sponsor family canonicalization: %d family-map keys applied",
    nrow(family_map)
  ))

  list(combined = mapped, review = review)
}

build_final_groups <- function(combined) {
  label_stats <- combined |>
    dplyr::filter(!is.na(sponsor_clean), sponsor_clean != "") |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(
      sponsor_types = paste(sort(unique(stats::na.omit(sponsor_type))), collapse = "|"),
      sources = paste(sort(unique(stats::na.omit(source))), collapse = "|"),
      aliases_sample = paste(utils::head(sort(unique(alias_clean)), 8L), collapse = "|"),
      .groups = "drop"
    )

  label_stats <- dplyr::bind_cols(
    label_stats,
    sponsor_entity_profile(label_stats$sponsor_clean)
  ) |>
    dplyr::mutate(
      final_entity_key = dplyr::coalesce(department_parent_key, entity_family_key),
      final_entity_blocked = sponsor_is_cross_entity_combined(sponsor_clean)
    )

  exact_groups <- label_stats |>
    dplyr::mutate(cluster_key = purrr::map_chr(sponsor_clean, final_exact_key)) |>
    dplyr::filter(nchar(cluster_key) >= 3L) |>
    dplyr::group_by(cluster_key) |>
    dplyr::filter(dplyr::n_distinct(sponsor_clean) > 1L) |>
    dplyr::mutate(evidence = "case/accent/punctuation variant", score = 100) |>
    dplyr::ungroup()

  stripped_groups <- label_stats |>
    dplyr::mutate(cluster_key = purrr::map_chr(sponsor_clean, final_stripped_key)) |>
    dplyr::filter(nchar(cluster_key) >= 3L) |>
    dplyr::group_by(cluster_key) |>
    dplyr::filter(dplyr::n_distinct(sponsor_clean) > 1L) |>
    dplyr::mutate(evidence = "stripped legal/group/foundation tokens", score = 98) |>
    dplyr::ungroup()

  entity_groups <- label_stats |>
    dplyr::filter(
      !is.na(final_entity_key), final_entity_key != "",
      nchar(final_entity_key) >= 3L,
      entity_key_is_classed(final_entity_key),
      !final_entity_blocked
    ) |>
    dplyr::mutate(cluster_key = paste0("entity-final:", final_entity_key)) |>
    dplyr::group_by(cluster_key) |>
    dplyr::filter(dplyr::n_distinct(sponsor_clean) > 1L) |>
    dplyr::mutate(
      evidence = paste0(
        "shared multilingual entity family",
        "; anchor=", dplyr::coalesce(entity_anchor_key, ""),
        "; class=", dplyr::coalesce(entity_class_key, ""),
        "; department_parent=", dplyr::coalesce(department_parent_key, "")
      ),
      score = 98
    ) |>
    dplyr::ungroup()

  fuzzy_groups <- build_final_fuzzy_groups(label_stats)

  dplyr::bind_rows(exact_groups, stripped_groups, entity_groups, fuzzy_groups) |>
    dplyr::distinct(cluster_key, sponsor_clean, .keep_all = TRUE)
}

build_final_fuzzy_groups <- function(label_stats) {
  labels <- label_stats$sponsor_clean
  keys <- purrr::map_chr(labels, collapse_text)
  n <- length(labels)
  if (n < 2L) {
    return(dplyr::slice(label_stats, 0) |>
      dplyr::mutate(cluster_key = character(), evidence = character(), score = numeric()))
  }

  parent <- seq_len(n)
  find <- function(x) {
    r <- x
    while (parent[[r]] != r) r <- parent[[r]]
    r
  }

  blocks <- split(seq_len(n), substr(keys, 1L, 1L))
  for (idx in blocks) {
    if (length(idx) < 2L) next
    for (a in seq_len(length(idx) - 1L)) {
      i <- idx[[a]]
      for (b in (a + 1L):length(idx)) {
        j <- idx[[b]]
        if (abs(nchar(keys[[i]]) - nchar(keys[[j]])) > 3L) next
        if (!short_acronym_safe(c(labels[[i]], labels[[j]]))) next
        sim <- stringdist::stringsim(keys[[i]], keys[[j]], method = "jw", p = 0.1)
        if (is.na(sim) || sim < 0.985) next
        ri <- find(i); rj <- find(j)
        if (ri != rj) parent[[rj]] <- ri
      }
    }
  }

  cluster <- vapply(seq_len(n), find, integer(1L))
  multi <- names(which(table(cluster) > 1L))
  if (length(multi) == 0L) {
    return(dplyr::slice(label_stats, 0) |>
      dplyr::mutate(cluster_key = character(), evidence = character(), score = numeric()))
  }

  label_stats |>
    dplyr::mutate(
      cluster = as.character(cluster),
      cluster_key = paste0("fuzzy:", cluster),
      evidence = "very high JW label similarity",
      score = 99
    ) |>
    dplyr::filter(cluster %in% multi) |>
    dplyr::select(-cluster)
}

apply_auto_final_canonicalization <- function(combined, review_path, seed_review = NULL) {
  seed_review <- ensure_final_review_schema(seed_review)
  groups <- build_final_groups(combined)

  if (nrow(groups) == 0L) {
    readr::write_csv(seed_review, review_path)
    return(combined)
  }

  group_summary <- groups |>
    dplyr::group_by(cluster_key) |>
    dplyr::summarise(
      sponsor_labels = paste(sort(unique(sponsor_clean)), collapse = "|"),
      labels_list = list(sort(unique(sponsor_clean))),
      entity_key = first_non_missing(final_entity_key),
      entity_anchor_key = paste(sort(unique(stats::na.omit(entity_anchor_key))), collapse = "|"),
      entity_class_key = paste(sort(unique(stats::na.omit(entity_class_key))), collapse = "|"),
      department_parent_key = paste(sort(unique(stats::na.omit(department_parent_key))), collapse = "|"),
      aliases_sample = paste(utils::head(sort(unique(unlist(strsplit(aliases_sample, "\\|", fixed = FALSE)))), 8L), collapse = "|"),
      sources = paste(sort(unique(unlist(strsplit(sources, "\\|", fixed = FALSE)))), collapse = "|"),
      sponsor_types = paste(sort(unique(unlist(strsplit(sponsor_types, "\\|", fixed = FALSE)))), collapse = "|"),
      score = max(score),
      evidence = paste(sort(unique(evidence)), collapse = "; "),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      suggested_canonical = purrr::map_chr(labels_list, pick_final_canonical, combined = combined),
      compatible_types = purrr::map_lgl(strsplit(sponsor_types, "\\|", fixed = FALSE), final_types_compatible),
      acronym_safe = purrr::map_lgl(labels_list, short_acronym_safe),
      auto_apply = compatible_types & acronym_safe & score >= 98,
      review_bucket = purrr::map_chr(cluster_key, review_bucket_for_key)
    )

  auto_map <- group_summary |>
    dplyr::filter(auto_apply) |>
    dplyr::select(labels_list, suggested_canonical) |>
    tidyr::unnest_longer(labels_list, values_to = "sponsor_clean") |>
    dplyr::filter(sponsor_clean != suggested_canonical) |>
    dplyr::distinct(sponsor_clean, suggested_canonical) |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::filter(dplyr::n_distinct(suggested_canonical) == 1L) |>
    dplyr::ungroup()

  review <- group_summary |>
    dplyr::filter(!auto_apply) |>
    dplyr::transmute(
      cluster_key,
      entity_key,
      entity_anchor_key,
      entity_class_key,
      department_parent_key,
      suggested_canonical,
      sponsor_labels,
      aliases_sample,
      sources,
      sponsor_types,
      score,
      evidence,
      confidence_bucket = "review",
      blocked_reason = dplyr::case_when(
        !compatible_types ~ "sponsor types differ",
        !acronym_safe ~ "short acronym guard failed",
        TRUE ~ NA_character_
      ),
      review_bucket,
      applied = FALSE
    ) |>
    dplyr::arrange(review_bucket, cluster_key)

  review_out <- dplyr::bind_rows(seed_review, review) |>
    ensure_final_review_schema() |>
    dplyr::arrange(review_bucket, cluster_key)

  readr::write_csv(review_out, review_path)
  message(sprintf(
    "Wrote %d final sponsor canonical review clusters to %s",
    nrow(review_out), review_path
  ))

  if (nrow(auto_map) == 0L) return(combined)

  canonical_defaults <- combined |>
    dplyr::semi_join(auto_map, by = c("sponsor_clean" = "suggested_canonical")) |>
    dplyr::group_by(sponsor_clean) |>
    dplyr::summarise(
      sponsor_parent_default = first_non_missing(sponsor_parent),
      sponsor_group_default = first_non_missing(sponsor_group),
      sponsor_type_default = first_non_missing(sponsor_type),
      .groups = "drop"
    ) |>
    dplyr::rename(sponsor_clean_final = sponsor_clean)

  combined |>
    dplyr::left_join(auto_map, by = "sponsor_clean") |>
    dplyr::mutate(
      sponsor_clean_final = dplyr::coalesce(suggested_canonical, sponsor_clean)
    ) |>
    dplyr::left_join(canonical_defaults, by = "sponsor_clean_final") |>
    dplyr::mutate(
      sponsor_clean = sponsor_clean_final,
      sponsor_parent = dplyr::coalesce(sponsor_parent_default, sponsor_parent),
      sponsor_group = dplyr::coalesce(sponsor_group_default, sponsor_group),
      sponsor_type = dplyr::coalesce(sponsor_type_default, sponsor_type)
    ) |>
    dplyr::select(
      alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
      sponsor_type, alias_type, source, confidence_prior
    )
}

apply_final_canonicalization <- function(combined, map_path, family_map_path, review_path) {
  before_labels <- dplyr::n_distinct(combined$sponsor_clean)

  combined <- apply_explicit_final_map(combined, map_path)
  family_result <- apply_final_family_canonicalization(combined, family_map_path)
  combined <- apply_auto_final_canonicalization(
    family_result$combined,
    review_path,
    seed_review = family_result$review
  )
  combined <- combined |>
    dplyr::arrange(alias_clean, sponsor_clean) |>
    dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE)

  after_labels <- dplyr::n_distinct(combined$sponsor_clean)
  message(sprintf(
    "Final sponsor canonicalization: %d labels -> %d labels",
    before_labels, after_labels
  ))
  combined
}

# ── Manual aliases (seed) ─────────────────────────────────────────────────────

manual_path <- file.path(SNP, "manual_sponsor_aliases.csv")
manual <- readr::read_csv(manual_path, show_col_types = FALSE) |>
  dplyr::mutate(alias_clean = clean_sponsor_alias(alias_clean))

message(sprintf("Manual aliases: %d entries", nrow(manual)))

export_llm_reviewed <- function(queue_path, out_path) {
  empty_llm <- tibble::tibble(
    alias_clean      = character(),
    sponsor_clean    = character(),
    sponsor_parent   = character(),
    sponsor_group    = character(),
    sponsor_type     = character(),
    source           = character(),
    confidence_prior = numeric(),
    alias_type       = character()
  )

  existing_llm <- if (file.exists(out_path)) {
    readr::read_csv(out_path, show_col_types = FALSE) |>
      dplyr::mutate(alias_clean = clean_sponsor_alias(alias_clean)) |>
      dplyr::select(
        alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
        sponsor_type, source, confidence_prior, alias_type
      ) |>
      prefer_llm_reviewed()
  } else {
    empty_llm
  }

  if (!file.exists(queue_path)) {
    return(existing_llm)
  }

  queue <- readr::read_csv(queue_path, show_col_types = FALSE)
  required_cols <- c(
    "raw_sponsor", "sponsor_type", "decision", "canonical_sponsor", "comment"
  )
  missing_cols <- setdiff(required_cols, names(queue))
  if (length(missing_cols)) {
    warning(
      "Cannot export LLM-reviewed sponsors; queue is missing columns: ",
      paste(missing_cols, collapse = ", ")
    )
    return(existing_llm)
  }

  queue_llm <- queue |>
    dplyr::mutate(
      decision          = stringr::str_to_lower(stringr::str_squish(decision)),
      canonical_sponsor = stringr::str_squish(canonical_sponsor),
      comment           = dplyr::coalesce(comment, ""),
      alias_clean       = clean_sponsor_alias(raw_sponsor)
    ) |>
    dplyr::filter(
      decision == "accepted",
      !is.na(canonical_sponsor), nchar(canonical_sponsor) >= 2,
      !stringr::str_detect(comment, stringr::regex("^legacy-export", ignore_case = TRUE))
    ) |>
    dplyr::mutate(
      sponsor_clean    = canonical_sponsor,
      sponsor_parent   = NA_character_,
      sponsor_group    = NA_character_,
      sponsor_type     = dplyr::if_else(
        is.na(sponsor_type) | sponsor_type == "" | sponsor_type == "NA",
        classify_sponsor_type(canonical_sponsor),
        sponsor_type
      ),
      source           = dplyr::case_when(
        stringr::str_detect(comment, stringr::regex("^llm-reviewed", ignore_case = TRUE)) ~ "llm_reviewed",
        stringr::str_detect(comment, stringr::regex("^bulk-", ignore_case = TRUE)) ~ "bulk_reviewed",
        TRUE ~ "review_queue"
      ),
      confidence_prior = 1,
      alias_type       = source
    ) |>
    dplyr::select(
      alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
      sponsor_type, source, confidence_prior, alias_type
    ) |>
    dplyr::filter(
      !is.na(alias_clean), !is.na(sponsor_clean),
      nchar(alias_clean) >= 2, nchar(sponsor_clean) >= 2
    ) |>
    prefer_llm_reviewed() |>
    dplyr::arrange(alias_clean, sponsor_clean) |>
    dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE)

  llm_reviewed <- dplyr::bind_rows(existing_llm, queue_llm) |>
    dplyr::filter(
      !is.na(alias_clean), !is.na(sponsor_clean),
      nchar(alias_clean) >= 2, nchar(sponsor_clean) >= 2
    ) |>
    prefer_llm_reviewed() |>
    dplyr::arrange(alias_clean, sponsor_clean) |>
    dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE)

  readr::write_csv(llm_reviewed, out_path)
  llm_reviewed
}

llm_reviewed <- export_llm_reviewed(
  queue_path = file.path(SNP, "sponsor_review_queue.csv"),
  out_path   = OUT_LLM
)

message(sprintf(
  "Reviewed queue aliases: %d entries (wrote %s)",
  nrow(llm_reviewed), OUT_LLM
))

# Build a lookup table: alias_clean → canonical sponsor fields
# Used to resolve external source names against known canonicals.
alias_lookup <- dplyr::bind_rows(manual, llm_reviewed) |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type
  ) |>
  dplyr::distinct(alias_clean, .keep_all = TRUE)

resolve_external <- function(raw_name, source_label, confidence) {
  ac         <- clean_sponsor_alias(raw_name)
  candidates <- make_sponsor_candidates(raw_name)

  hit <- alias_lookup |>
    dplyr::filter(alias_clean %in% candidates) |>
    dplyr::slice(1)

  if (nrow(hit) == 0) return(NULL)

  tibble::tibble(
    alias_clean      = ac,
    sponsor_clean    = hit$sponsor_clean,
    sponsor_parent   = hit$sponsor_parent,
    sponsor_group    = hit$sponsor_group,
    sponsor_type     = hit$sponsor_type,
    alias_type       = source_label,
    source           = source_label,
    confidence_prior = confidence
  )
}

# ── EMA EPAR — Marketing Authorisation Holder names ──────────────────────────

epar_rows <- tibble::tibble(
  alias_clean      = character(),
  sponsor_clean    = character(),
  sponsor_parent   = character(),
  sponsor_group    = character(),
  sponsor_type     = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)

if (!no_epar) {
  EPAR_URL <- paste0(
    "https://www.ema.europa.eu/en/documents/report/",
    "medicines-output-medicines-report_en.xlsx"
  )

  message("Downloading EMA medicines report...")
  dest <- tempfile(fileext = ".xlsx")
  tryCatch({
    request(EPAR_URL) |>
      req_timeout(180) |>
      req_perform() |>
      resp_body_raw() |>
      writeBin(dest)
    message("Download complete.")

    # Find the header row dynamically — EMA occasionally adds/removes metadata rows.
    # The header row is the first row containing "name of medicine" or "active substance".
    raw_excel <- readxl::read_excel(dest, col_names = FALSE, skip = 0,
                                    .name_repair = "minimal")
    row_strings <- apply(raw_excel, 1, function(r) {
      paste(tolower(trimws(as.character(unlist(r, use.names = FALSE)))),
            collapse = " ")
    })
    header_idx <- which(
      grepl("name of medicine", row_strings) |
      grepl("active substance", row_strings)
    )[1]

    if (is.na(header_idx)) {
      stop("Could not find header row in EPAR Excel")
    }

    headers   <- stringr::str_squish(
      as.character(unlist(raw_excel[header_idx, ], use.names = FALSE))
    )
    data_rows <- raw_excel[(header_idx + 1):nrow(raw_excel), ]
    colnames(data_rows) <- headers

    # The EMA MAH column is "Marketing authorisation developer / applicant / holder"
    # (exact wording varies across releases); match on the shared prefix.
    # Use ignore.case so the returned value preserves the original column name.
    mah_col <- grep(
      "marketing authori[sz]ation",
      names(data_rows),
      ignore.case = TRUE,
      value = TRUE
    )[1]

    if (is.na(mah_col)) {
      message(
        "WARNING: Could not find MAH column. Columns: ",
        paste(names(data_rows), collapse = ", ")
      )
    } else {
      mah_names <- data_rows[[mah_col]]
      mah_names <- unique(mah_names[!is.na(mah_names) & nzchar(trimws(mah_names))])
      message(sprintf("EPAR: %d unique MAH names", length(mah_names)))

      epar_resolved <- purrr::map_dfr(
        mah_names,
        ~ resolve_external(.x, source_label = "epar_mah", confidence = 0.85)
      )

      n_unmatched <- length(mah_names) - nrow(epar_resolved)
      message(sprintf(
        "EPAR: %d matched, %d unmatched (see new_sponsor_candidates.csv)",
        nrow(epar_resolved), n_unmatched
      ))

      # Write unmatched MAH names for manual review
      unmatched_mah <- mah_names[
        !clean_sponsor_alias(mah_names) %in% epar_resolved$alias_clean
      ]
      epar_rows <- epar_resolved
    }
  }, error = function(e) {
    message("WARNING: EPAR download/parse failed: ", conditionMessage(e))
  })
}

# ── ROR — academic and hospital name variants ─────────────────────────────────

ror_rows <- tibble::tibble(
  alias_clean      = character(),
  sponsor_clean    = character(),
  sponsor_parent   = character(),
  sponsor_group    = character(),
  sponsor_type     = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)

if (!no_ror) {
  # Query ROR for academic/hospital organizations in EU trial-heavy countries.
  # ROR v1 API: paginated, 20 results per page.
  # We target organizations that are likely EU clinical trial sponsors.

  EU_COUNTRIES <- c(
    "NL", "BE", "DE", "FR", "GB", "IT", "ES", "DK", "SE", "NO",
    "AT", "CH", "FI", "PT", "IE", "PL", "CZ", "HU", "GR", "RO"
  )
  ROR_TYPES <- c("education", "healthcare")
  ROR_BASE  <- "https://api.ror.org/organizations"

  fetch_ror_page <- function(page, country, type) {
    tryCatch({
      resp <- request(ROR_BASE) |>
        req_url_query(
          page    = page,
          filter  = paste0(
            "country.country_code:", country,
            ",types:", stringr::str_to_title(type)
          )
        ) |>
        req_timeout(30) |>
        req_retry(max_tries = 3, backoff = ~ 2) |>
        req_perform() |>
        resp_body_json()
      resp
    }, error = function(e) {
      message("  ROR page error (", country, "/", type, "/p", page, "): ",
              conditionMessage(e))
      NULL
    })
  }

  extract_ror_names <- function(org) {
    names_vec <- character(0)
    if (!is.null(org$name)) names_vec <- c(names_vec, org$name)
    if (!is.null(org$aliases) && length(org$aliases) > 0) {
      names_vec <- c(names_vec, unlist(org$aliases))
    }
    if (!is.null(org$labels) && length(org$labels) > 0) {
      labels <- purrr::map_chr(org$labels, ~ null_coalesce(.x$label, NA_character_))
      names_vec <- c(names_vec, labels[!is.na(labels)])
    }
    if (!is.null(org$acronyms) && length(org$acronyms) > 0) {
      names_vec <- c(names_vec, unlist(org$acronyms))
    }
    unique(names_vec[nzchar(names_vec)])
  }

  message("Querying ROR for EU academic/hospital organizations...")

  ror_all_names <- character(0)

  for (country in EU_COUNTRIES) {
    for (type in ROR_TYPES) {
      page1 <- fetch_ror_page(1, country, type)
      if (is.null(page1)) next

      total     <- null_coalesce(page1$number_of_results, 0L)
      n_pages   <- ceiling(total / 20)
      if (n_pages == 0) next

      message(sprintf("  %s/%s: %d orgs, %d pages", country, type, total, n_pages))

      orgs <- null_coalesce(page1$items, list())
      for (p in seq_len(min(n_pages, 50))) {  # cap at 50 pages (1000 orgs) per combo
        if (p > 1) {
          Sys.sleep(0.05)
          pg <- fetch_ror_page(p, country, type)
          if (!is.null(pg)) orgs <- c(orgs, null_coalesce(pg$items, list()))
        }
      }

      new_names <- purrr::map(orgs, extract_ror_names) |> unlist()
      ror_all_names <- unique(c(ror_all_names, new_names))
    }
  }

  message(sprintf("ROR: %d unique name strings collected", length(ror_all_names)))

  ror_resolved <- purrr::map_dfr(
    ror_all_names,
    ~ resolve_external(.x, source_label = "ror", confidence = 0.75)
  )

  n_ror_unmatched <- length(ror_all_names) - nrow(ror_resolved)
  message(sprintf(
    "ROR: %d matched, %d unmatched",
    nrow(ror_resolved), n_ror_unmatched
  ))

  ror_rows <- ror_resolved
}

# ── DB-sourced tiers: businessKey / email-domain / postcode ──────────────────

empty_tier <- tibble::tibble(
  alias_clean      = character(),
  sponsor_clean    = character(),
  sponsor_parent   = character(),
  sponsor_group    = character(),
  sponsor_type     = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)
bk_rows    <- empty_tier
email_rows <- empty_tier
loc_rows   <- empty_tier

bk_unresolved <- tibble::tibble(
  businesskey = character(),
  raw_name    = character(),
  alias_clean = character()
)

if (!no_db) {
  db_path <- Sys.getenv(
    "DB_PATH", unset = project_path("data", "trials.sqlite")
  )
  if (!file.exists(db_path)) {
    message(
      "WARNING: DB not found at ", db_path,
      " — skipping DB tiers (use --no-db to suppress, or set DB_PATH)"
    )
  } else {
    suppressPackageStartupMessages({
      library(nodbi)
      library(ctrdata)
    })

    db <- nodbi::src_sqlite(dbname = db_path, collection = "trials")

    # Helper: resolve a raw name against the manual alias lookup.
    # Returns the first matching alias_lookup row, or NULL.
    resolve_name <- function(raw_name) {
      cands <- make_sponsor_candidates(raw_name)
      hit   <- alias_lookup[alias_lookup$alias_clean %in% cands, , drop = FALSE]
      if (nrow(hit) > 0) hit[1L, ] else NULL
    }

    # Helper: build one alias row given a canonical hit tibble.
    make_alias_row <- function(ac, canonical, alias_type, source, conf) {
      tibble::tibble(
        alias_clean      = ac,
        sponsor_clean    = canonical$sponsor_clean,
        sponsor_parent   = canonical$sponsor_parent,
        sponsor_group    = canonical$sponsor_group,
        sponsor_type     = canonical$sponsor_type,
        alias_type       = alias_type,
        source           = source,
        confidence_prior = conf
      )
    }

    # ── Tier 1: CTIS businessKey (confidence 0.95) ───────────────────────────

    if (!no_businesskey) {
      message("Tier 1 — CTIS businessKey aliases...")
      NAME_COL <- paste0(
        "authorizedApplication.authorizedPartI",
        ".sponsors.organisation.name"
      )
      BK_COL <- paste0(
        "authorizedApplication.authorizedPartI",
        ".sponsors.organisation.businessKey"
      )

      bk_df <- ctrdata::dbGetFieldsIntoDf(
        fields = c(NAME_COL, BK_COL), con = db
      )
      bk_df <- bk_df[
        grepl("[0-9][0-9]$", bk_df[["_id"]]) &
        !is.na(bk_df[[BK_COL]]) & !is.na(bk_df[[NAME_COL]]),
      ]

      bk_groups <- bk_df |>
        dplyr::group_by(.data[[BK_COL]]) |>
        dplyr::summarise(
          names = list(unique(.data[[NAME_COL]])), .groups = "drop"
        ) |>
        dplyr::filter(purrr::map_int(names, length) > 1L)

      message(sprintf(
        "  %d businessKeys with >=2 name variants", nrow(bk_groups)
      ))

      new_bk <- vector("list", nrow(bk_groups))

      for (i in seq_len(nrow(bk_groups))) {
        names_i <- bk_groups$names[[i]]
        hits    <- purrr::map(names_i, resolve_name)
        resolved   <- purrr::compact(hits)
        canonicals <- purrr::map_chr(resolved, ~ .x$sponsor_clean)

        if (length(resolved) == 0L) {
          bk_unresolved <- dplyr::bind_rows(
            bk_unresolved,
            tibble::tibble(
              businesskey = bk_groups[[BK_COL]][i],
              raw_name    = names_i,
              alias_clean = clean_sponsor_alias(names_i)
            )
          )
          next
        }
        if (dplyr::n_distinct(canonicals) > 1L) next  # ambiguous key

        canonical    <- resolved[[1L]]
        unresolved_i <- names_i[purrr::map_lgl(hits, is.null)]

        new_bk[[i]] <- purrr::map_dfr(unresolved_i, function(nm) {
          ac <- clean_sponsor_alias(nm)
          if (nchar(ac) < 2L) return(NULL)
          make_alias_row(ac, canonical, "ctis_businesskey",
                         "ctis_businesskey", 0.95)
        })
      }

      bk_rows <- dplyr::bind_rows(new_bk)
      message(sprintf("  %d new alias entries", nrow(bk_rows)))
    }

    # ── Tier 2: EUCTR email domain (confidence 0.85) ─────────────────────────

    if (!no_email) {
      # Domains shared by CROs, generic mail, or regional health authorities
      # that umbrella multiple distinct sponsor institutions.
      blocked_domains <- c(
        "ppdi.com", "covance.com", "quintiles.com", "iqvia.com",
        "parexel.com", "pra.com", "praintl.com", "icon.com", "iconplc.com",
        "syneos.com", "medpace.com", "clinipace.com", "clinact.com",
        "inventivhealth.com", "tfscro.com", "psi-cro.com", "nuvisan.com",
        "worldwide.com", "icta.fr",
        "gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "nhs.net"
      )

      # Generic institution-type tokens that are too common to be discriminative.
      generic_tokens <- c(
        "university", "hospital", "centre", "center", "medical", "institute",
        "research", "department", "foundation", "national", "general",
        "royal", "clinical", "health", "science", "sciences", "college",
        "academic", "school", "faculty", "division", "unit", "trust",
        "regional", "municipal", "canton", "universitaire", "universitario",
        "universitaria", "universitaet", "universitets", "universitets",
        "clinique", "clinic", "klinik", "klinikum", "ziekenhuis",
        "ospedale", "hopital", "krankenhaus", "sjukhuset", "sygehus",
        "uniklinik", "medizinische"
      )

      message("Tier 2 — EUCTR email domain aliases...")

      em_df <- ctrdata::dbGetFieldsIntoDf(
        fields = c("b1_sponsor.b11_name_of_sponsor", "b1_sponsor.b56_email"),
        con    = db
      )
      em_df <- em_df[
        grepl("[A-Z][A-Z0-9]*$", em_df[["_id"]]) &
        !is.na(em_df[["b1_sponsor.b56_email"]]) &
        !is.na(em_df[["b1_sponsor.b11_name_of_sponsor"]]),
      ]

      raw_email <- stringr::str_replace_all(
        em_df[["b1_sponsor.b56_email"]], "&#64;|&#x40;", "@"
      )
      em_df$domain <- tolower(trimws(sub(".*@", "", raw_email)))
      em_df$domain <- stringr::str_extract(
        em_df$domain, "^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}"
      )
      em_df <- em_df[
        !is.na(em_df$domain) & !em_df$domain %in% blocked_domains,
      ]

      dom_groups <- em_df |>
        dplyr::group_by(domain) |>
        dplyr::summarise(
          names = list(unique(`b1_sponsor.b11_name_of_sponsor`)),
          .groups = "drop"
        )

      new_em <- vector("list", nrow(dom_groups))

      for (i in seq_len(nrow(dom_groups))) {
        names_i  <- dom_groups$names[[i]]
        domain_i <- dom_groups$domain[i]
        hits     <- purrr::map(names_i, resolve_name)
        resolved   <- purrr::compact(hits)
        canonicals <- purrr::map_chr(resolved, ~ .x$sponsor_clean)

        if (length(resolved) == 0L)             next
        if (dplyr::n_distinct(canonicals) > 1L) next  # ambiguous domain

        canonical     <- resolved[[1L]]
        canonical_clean <- clean_sponsor_alias(canonical$sponsor_clean)
        sig_tokens <- function(s) {
          t <- stringr::str_split(clean_sponsor_alias(s), "\\s+")[[1L]]
          t <- t[nchar(t) >= 4L]
          t[!t %in% generic_tokens]
        }
        # Discriminative tokens from all resolved names in this domain
        anchor_tokens <- unique(unlist(purrr::map(
          purrr::map_chr(resolved, ~ .x$sponsor_clean), sig_tokens
        )))
        unresolved_i <- names_i[purrr::map_lgl(hits, is.null)]

        new_em[[i]] <- purrr::map_dfr(unresolved_i, function(nm) {
          ac <- clean_sponsor_alias(nm)
          if (nchar(ac) < 2L) return(NULL)
          # Require at least one shared discriminative token to guard against
          # investigator emails being attributed to an unrelated sponsor.
          if (length(anchor_tokens) == 0L) return(NULL)
          nm_sig <- sig_tokens(nm)
          if (length(intersect(nm_sig, anchor_tokens)) == 0L) return(NULL)
          make_alias_row(ac, canonical, "euctr_email_domain",
                         paste0("euctr_email_domain:", domain_i), 0.85)
        })
      }

      email_rows <- dplyr::bind_rows(new_em)
      message(sprintf("  %d new alias entries", nrow(email_rows)))
    }

    # ── Tier 3: Postcode + country + JW similarity (confidence 0.70) ─────────

    if (!no_location) {
      message("Tier 3 — Postcode + country aliases...")

      ctis_loc <- ctrdata::dbGetFieldsIntoDf(fields = c(
        paste0("authorizedApplication.authorizedPartI",
               ".sponsors.organisation.name"),
        paste0("authorizedApplication.authorizedPartI",
               ".sponsors.addresses.address.postcode"),
        paste0("authorizedApplication.authorizedPartI",
               ".sponsors.addresses.address.countryName")
      ), con = db)

      ctis_loc <- ctis_loc[
        grepl("[0-9][0-9]$", ctis_loc[["_id"]]),
      ] |>
        dplyr::transmute(
          name = .data[[paste0(
            "authorizedApplication.authorizedPartI",
            ".sponsors.organisation.name"
          )]],
          postcode = toupper(stringr::str_squish(.data[[paste0(
            "authorizedApplication.authorizedPartI",
            ".sponsors.addresses.address.postcode"
          )]])),
          country = .data[[paste0(
            "authorizedApplication.authorizedPartI",
            ".sponsors.addresses.address.countryName"
          )]]
        ) |>
        dplyr::filter(
          !is.na(name), !is.na(postcode), !is.na(country), nzchar(postcode)
        )

      euctr_loc <- ctrdata::dbGetFieldsIntoDf(fields = c(
        "b1_sponsor.b11_name_of_sponsor",
        "b1_sponsor.b533_post_code",
        "b1_sponsor.b534_country"
      ), con = db)

      euctr_loc <- euctr_loc[
        grepl("[A-Z][A-Z0-9]*$", euctr_loc[["_id"]]),
      ] |>
        dplyr::transmute(
          name     = .data[["b1_sponsor.b11_name_of_sponsor"]],
          postcode = toupper(stringr::str_squish(
            .data[["b1_sponsor.b533_post_code"]]
          )),
          country  = .data[["b1_sponsor.b534_country"]]
        ) |>
        dplyr::filter(
          !is.na(name), !is.na(postcode), !is.na(country), nzchar(postcode)
        )

      all_loc <- dplyr::bind_rows(ctis_loc, euctr_loc)

      loc_groups <- all_loc |>
        dplyr::group_by(postcode, country) |>
        dplyr::summarise(
          names = list(unique(name)), .groups = "drop"
        ) |>
        dplyr::filter(purrr::map_int(names, length) > 1L)

      message(sprintf(
        "  %d postcode+country groups with >=2 names", nrow(loc_groups)
      ))

      new_loc <- vector("list", nrow(loc_groups))

      for (i in seq_len(nrow(loc_groups))) {
        names_i      <- loc_groups$names[[i]]
        hits         <- purrr::map(names_i, resolve_name)
        resolved_idx <- which(!purrr::map_lgl(hits, is.null))

        if (length(resolved_idx) == 0L) next

        name_clean_i <- clean_sponsor_alias(names_i)
        unresolved_j <- which(purrr::map_lgl(hits, is.null))
        group_rows   <- list()

        for (ri in resolved_idx) {
          canonical    <- hits[[ri]]
          anchor_clean <- name_clean_i[[ri]]

          for (j in unresolved_j) {
            jw_sim <- 1 - stringdist::stringdist(
              anchor_clean, name_clean_i[[j]], method = "jw", p = 0.1
            )
            if (jw_sim < 0.88) next
            ac <- clean_sponsor_alias(names_i[[j]])
            if (nchar(ac) < 2L) next
            group_rows <- c(group_rows, list(
              make_alias_row(ac, canonical,
                             "location_postcode", "location_postcode", 0.70)
            ))
          }
        }

        if (length(group_rows) > 0L) {
          new_loc[[i]] <- dplyr::bind_rows(group_rows)
        }
      }

      loc_rows <- dplyr::bind_rows(new_loc)
      if (nrow(loc_rows) > 0L) {
        readr::write_csv(
          loc_rows |>
            dplyr::select(
              alias_clean, suggested_canonical = sponsor_clean,
              sponsor_parent, sponsor_group, sponsor_type,
              source, confidence_prior
            ) |>
            dplyr::arrange(suggested_canonical, alias_clean),
          OUT_LOC_REVIEW
        )
      }
      message(sprintf(
        "  %d postcode candidates written to %s (review-only, not added to alias index)",
        nrow(loc_rows), OUT_LOC_REVIEW
      ))
      loc_rows <- empty_index_rows()
    }
  }
}

db_rows <- dplyr::bind_rows(bk_rows, email_rows, loc_rows)

# ── Merge ─────────────────────────────────────────────────────────────────────

# Prepare manual seed in the same schema
manual_index <- manual |>
  dplyr::mutate(alias_type = "manual") |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
    sponsor_type, alias_type, source, confidence_prior
  )

# Prepare reviewed queue aliases in the same schema. These are generated from
# accepted queue decisions and intentionally kept outside the hand-maintained
# manual seed file.
llm_index <- llm_reviewed |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
    sponsor_type, alias_type, source, confidence_prior
  )

# Row order = priority: manual > reviewed queue > epar > ror > db
# (businesskey > email > location)
combined <- dplyr::bind_rows(manual_index, llm_index, epar_rows, ror_rows, db_rows) |>
  dplyr::filter(
    !is.na(alias_clean), !is.na(sponsor_clean),
    nchar(alias_clean) >= 2, nchar(sponsor_clean) >= 2
  ) |>
  dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE)

message(sprintf("Combined index: %d total alias entries", nrow(combined)))

combined <- apply_final_canonicalization(
  combined,
  map_path = OUT_FINAL_MAP,
  family_map_path = OUT_FINAL_FAMILY_MAP,
  review_path = OUT_FINAL_REVIEW
)

# ── Ambiguous aliases ─────────────────────────────────────────────────────────

n_per_alias <- combined |>
  dplyr::distinct(alias_clean, sponsor_clean) |>
  dplyr::count(alias_clean, name = "n_sponsors")

ambiguous <- combined |>
  dplyr::filter(
    alias_clean %in% (n_per_alias |> dplyr::filter(n_sponsors > 1))$alias_clean
  ) |>
  dplyr::group_by(alias_clean) |>
  dplyr::summarise(
    sponsors_all = paste(sort(unique(sponsor_clean)), collapse = "|"),
    n_sponsors   = dplyr::n_distinct(sponsor_clean),
    sources      = paste(sort(unique(source)), collapse = "|"),
    .groups      = "drop"
  ) |>
  dplyr::arrange(dplyr::desc(n_sponsors), alias_clean)

message(sprintf(
  "Ambiguous aliases (one alias → multiple sponsors): %d",
  nrow(ambiguous)
))

readr::write_csv(ambiguous, OUT_AMBIG)
message(sprintf("Wrote %d ambiguous aliases to %s", nrow(ambiguous), OUT_AMBIG))

# ── New sponsor candidates (unmatched external names) ─────────────────────────

# Collect all external names that didn't match anything in the manual table
new_candidates <- tibble::tibble(
  raw_name   = character(),
  source     = character(),
  alias_clean = character()
)

if (!no_epar && exists("unmatched_mah")) {
  new_candidates <- dplyr::bind_rows(
    new_candidates,
    tibble::tibble(
      raw_name    = unmatched_mah,
      source      = "epar_mah",
      alias_clean = clean_sponsor_alias(unmatched_mah)
    )
  )
}

if (!no_db && nrow(bk_unresolved) > 0L) {
  # Collapse each businessKey group to one row.
  # Canonical = shortest alias_clean in the group (tends to be the most
  # stripped-down form; reviewer can override when adding to manual aliases).
  org_candidates <- bk_unresolved |>
    dplyr::group_by(businesskey) |>
    dplyr::arrange(nchar(alias_clean), .by_group = TRUE) |>
    dplyr::summarise(
      suggested_canonical = raw_name[1L],
      alias_clean         = alias_clean[1L],
      n_variants          = dplyr::n(),
      other_names         = if (dplyr::n() > 1L) {
        paste(raw_name[-1L], collapse = " | ")
      } else NA_character_,
      .groups = "drop"
    ) |>
    dplyr::arrange(alias_clean)

  readr::write_csv(org_candidates, OUT_ORGS)
  message(sprintf(
    "Wrote %d unresolved CTIS org groups to %s (for manual review)",
    nrow(org_candidates), OUT_ORGS
  ))
}

# Collapse variants into one row per group using two passes:
#  1. Exact suggest_key match — strips legal suffixes + single-char fragments
#     (handles S.A./SA, GmbH/AG, B.V./BV, Ltd/Limited, etc.)
#  2. JW fuzzy cluster on suggest_key at >=0.90 — catches linguistic variants
#     that survive suffix stripping (Companhia/Ca/Cª, Corp./Co., etc.)
suggest_key <- function(raw) {
  s <- tolower(suggest_sponsor_clean(raw))

  # Strip branch/office indicators and the city token that follows them.
  # e.g. "Zweigniederlassung Jena" → "", "Sucursal Madrid" → ""
  s <- stringr::str_remove_all(s, stringr::regex(
    "\\b(zweigniederlassung|niederlassung|sucursal|filiale|agencia|branch)\\b(\\s+[a-z]+)?",
    ignore_case = TRUE
  ))

  # Strip country name tokens not already covered by .address_rx.
  s <- stringr::str_remove_all(s, stringr::regex(paste0("\\b(", paste(c(
    "ireland", "spain", "italy", "portugal", "sweden", "denmark",
    "norway", "finland", "poland", "czech", "hungary", "greece",
    "romania", "bulgaria", "slovakia", "croatia", "slovenia",
    "luxembourg", "malta", "cyprus", "australia", "canada",
    "japan", "china", "india", "brazil", "mexico"
  ), collapse = "|"), ")\\b"), ignore_case = TRUE))

  s <- stringr::str_squish(s)

  # Re-apply legal suffix strip — catches suffixes exposed by the removals
  # above (e.g. "Limited" in "Biolitec Limited Zweigniederlassung Jena").
  legal_rx <- paste0(
    "\\s+\\b(",
    paste(c(
      "inc", "corp", "corporation", "company", "co", "ltd", "limited",
      "llc", "plc", "ag", "gmbh", "kg", "kgaa", "bv", "nv", "sa",
      "sas", "srl", "spa", "ab", "oy", "pte", "kk", "ehf", "hf"
    ), collapse = "|"),
    ")$"
  )
  s <- stringr::str_remove(s, stringr::regex(legal_rx, ignore_case = TRUE))
  s <- stringr::str_squish(s)

  toks <- stringr::str_split(s, "\\s+")[[1L]]
  stringr::str_squish(paste(toks[nchar(toks) > 1L], collapse = " "))
}

nc <- new_candidates |>
  dplyr::filter(!is.na(raw_name), nchar(alias_clean) >= 4L) |>
  dplyr::mutate(grp = purrr::map_chr(raw_name, suggest_key))

if (nrow(nc) == 0L) {
  new_candidates <- tibble::tibble(
    raw_name = character(),
    source = character(),
    suggested_canonical = character(),
    other_names = character()
  )
} else {
  # Pass 1: exact key collapse — collect all raw names per (grp, source)
  nc_grp <- nc |>
    dplyr::group_by(grp, source) |>
    dplyr::arrange(nchar(alias_clean), .by_group = TRUE) |>
    dplyr::summarise(raw_names = list(unique(raw_name)), .groups = "drop") |>
    dplyr::arrange(nchar(grp))  # shortest key first so clusters pick it as head

  # Pass 2: JW fuzzy cluster within each source
  n_nc   <- nrow(nc_grp)
  parent <- seq_len(n_nc)
  find   <- function(x) { r <- x; while (parent[r] != r) r <- parent[[r]]; r }

  if (n_nc > 1L) {
    dist_mat <- stringdist::stringdistmatrix(
      nc_grp$grp, nc_grp$grp, method = "jw", p = 0.1
    )
    for (i in seq_len(n_nc - 1L)) {
      for (j in (i + 1L):n_nc) {
        if (nc_grp$source[i] != nc_grp$source[j]) next
        if (1 - dist_mat[i, j] < 0.90)            next
        ri <- find(i); rj <- find(j)
        if (ri != rj) parent[rj] <- ri
      }
    }
  }

  nc_grp$cluster <- vapply(seq_len(n_nc), find, integer(1L))

  new_candidates <- nc_grp |>
    dplyr::group_by(cluster, source) |>
    dplyr::summarise(
      raw_name            = raw_names[[1L]][[1L]],
      suggested_canonical = stringr::str_to_title(grp[[1L]]),
      other_names = {
        all_r <- unique(unlist(raw_names))
        rest  <- all_r[all_r != raw_names[[1L]][[1L]]]
        if (length(rest) > 0L) paste(rest, collapse = " | ") else NA_character_
      },
      .groups = "drop"
    ) |>
    dplyr::select(raw_name, source, suggested_canonical, other_names) |>
    dplyr::arrange(source, suggested_canonical)
}

readr::write_csv(new_candidates, OUT_NEW)
message(sprintf(
  "Wrote %d unmatched external names to %s (for manual review)",
  nrow(new_candidates), OUT_NEW
))

# ── Write index ───────────────────────────────────────────────────────────────

readr::write_csv(combined, OUT_INDEX)
message(sprintf(
  "Wrote %d alias entries to %s", nrow(combined), OUT_INDEX
))
message("Done. Run build_sponsor_labels.R to apply the new index.")
