suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(purrr)
  library(readr)
  library(tibble)
  library(stringdist)
})

# ── Shared cleaning helpers ───────────────────────────────────────────────────

clean_alias <- function(x) {
  x |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[  ​‌‍]", " ") |>
    stringr::str_replace_all("[®™]", "") |>
    stringr::str_replace_all("[‘’]", "'") |>
    stringr::str_replace_all("[–—−]", "-") |>
    stringr::str_replace_all("\\s+", " ") |>
    stringr::str_squish()
}

clean_substance <- function(x) {
  x |>
    clean_alias() |>
    stringr::str_replace_all("\\s*/\\s*", "|") |>
    stringr::str_replace_all("\\s*;\\s*", "|") |>
    stringr::str_replace_all("\\s*\\|\\s*", "|") |>
    stringr::str_squish()
}

.dose_pattern <- paste0(
  "\\b\\d+[,.]?\\d*\\s*",
  "(mg|mcg|microgram|micrograms|g|ml|l|iu|ui|mbq|gbq|%|ppm|mmol|",
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

sanitise_substance_output <- function(x) {
  if (is.na(x) || x == "placebo") return(x)
  x |>
    stringr::str_remove_all(
      stringr::regex(.dose_pattern, ignore_case = TRUE)
    ) |>
    stringr::str_remove_all(
      stringr::regex(.form_pattern, ignore_case = TRUE)
    ) |>
    stringr::str_squish()
}

# ── Config loader ─────────────────────────────────────────────────────────────

load_substance_configs <- function(
  config_dir = file.path("config", "substance_norm_pipeline")
) {
  read_csv_safe <- function(path) {
    if (file.exists(path)) {
      readr::read_csv(path, show_col_types = FALSE)
    } else {
      tibble::tibble()
    }
  }
  list(
    canonical = read_csv_safe(
      file.path(config_dir, "canonical_substances.csv")
    ),
    alias     = read_csv_safe(
      file.path(config_dir, "substance_alias_index.csv")
    ),
    negatives = read_csv_safe(
      file.path(config_dir, "negative_aliases.csv")
    ),
    overrides = read_csv_safe(
      file.path(config_dir, "manual_substance_overrides.csv")
    )
  )
}

# ── Candidate generator ───────────────────────────────────────────────────────

generate_candidates <- function(raw) {
  x0 <- clean_alias(raw)

  x_no_dose <- stringr::str_remove_all(
    x0, stringr::regex(.dose_pattern, ignore_case = TRUE)
  ) |> stringr::str_squish()

  x_no_form <- stringr::str_remove_all(
    x_no_dose, stringr::regex(.form_pattern, ignore_case = TRUE)
  ) |> stringr::str_squish()

  first_token <- stringr::str_extract(x_no_form, "^[a-z0-9][a-z0-9\\-]*")

  unique(stats::na.omit(c(x0, x_no_dose, x_no_form, first_token)))
}

# ── Internal result constructor ───────────────────────────────────────────────

.result <- function(substance, parent = NA_character_,
                    status, score, source, reason) {
  tibble::tibble(
    active_substance_clean  = as.character(substance),
    active_substance_parent = as.character(parent),
    match_status            = status,
    match_score             = as.numeric(score),
    match_source            = source,
    match_reason            = reason
  )
}

# ── Check functions ───────────────────────────────────────────────────────────

check_placebo <- function(raw) {
  if (stringr::str_detect(
    stringr::str_to_lower(raw), "\\bplacebo\\b"
  )) {
    return(.result(
      "placebo",
      status = "accepted", score = 100,
      source = "placebo_rule", reason = "placebo rule"
    ))
  }
  NULL
}

.reject_patterns <- c(
  "\\bmedical device\\b",
  "\\bcosmetic product\\b",
  "\\btoothpaste\\b",
  "\\bdressing\\b",
  "\\btest product\\b",
  "\\bblinded\\b",
  "\\bvehicle control\\b",
  "\\bexcipient\\b",
  "\\bopadry\\b",
  "\\bstrain\\b",
  "\\b(h1n1|h3n2|h5n1)\\b",
  "^.+\\bantagonist$",
  "^.+\\binhibitor$",
  "^.+\\bagonist$",
  "\\bclass\\b",
  "\\bstudy drug\\b",
  "\\binvestigational product\\b",
  "\\binvestigational medicinal product\\b"
)

check_negative <- function(candidates, cfg) {
  if (nrow(cfg$negatives) == 0) return(NULL)
  hit <- cfg$negatives |>
    dplyr::filter(alias_clean %in% candidates) |>
    dplyr::slice(1)
  if (nrow(hit) == 0) return(NULL)
  .result(
    NA_character_,
    status = "rejected", score = 100,
    source = "negative_aliases", reason = hit$reason[1]
  )
}

check_pattern_reject <- function(candidates) {
  for (cand in candidates) {
    for (pat in .reject_patterns) {
      if (stringr::str_detect(
        cand, stringr::regex(pat, ignore_case = TRUE)
      )) {
        return(.result(
          NA_character_,
          status = "rejected", score = 100,
          source = "pattern_reject",
          reason = paste0("matched pattern: ", pat)
        ))
      }
    }
  }
  NULL
}

check_override <- function(candidates, cfg) {
  if (nrow(cfg$overrides) == 0) return(NULL)
  hit <- cfg$overrides |>
    dplyr::filter(raw_clean %in% candidates) |>
    dplyr::slice(1)
  if (nrow(hit) == 0) return(NULL)
  .result(
    hit$substance_clean,
    status = hit$match_status, score = 99,
    source = "manual_override", reason = hit$reason[1]
  )
}

check_canonical <- function(candidates, cfg) {
  if (nrow(cfg$canonical) == 0) return(NULL)
  hits <- cfg$canonical |>
    dplyr::filter(substance_clean %in% candidates)
  if (nrow(hits) == 0) return(NULL)
  hit <- hits |> dplyr::slice(1)
  .result(
    hit$substance_clean,
    parent = hit$parent_substance,
    status = "accepted", score = 100,
    source = "canonical",
    reason = "exact canonical substance match"
  )
}

check_alias <- function(candidates, cfg) {
  if (nrow(cfg$alias) == 0) return(NULL)
  hits <- cfg$alias |>
    dplyr::filter(alias_clean %in% candidates) |>
    dplyr::mutate(
      candidate_rank = match(alias_clean, candidates),
      match_score    = confidence_prior * 100 - candidate_rank
    ) |>
    dplyr::arrange(dplyr::desc(match_score))
  if (nrow(hits) == 0) return(NULL)

  top_score <- hits$match_score[1]
  top_hits  <- hits |> dplyr::filter(match_score >= top_score - 2)

  if (dplyr::n_distinct(top_hits$substance_clean) > 1) {
    return(.result(
      NA_character_,
      status = "review", score = top_score,
      source = paste(unique(top_hits$source), collapse = "|"),
      reason = "ambiguous alias maps to multiple substances"
    ))
  }

  hit <- hits |> dplyr::slice(1)
  # Identity match: alias IS the substance — always accepted regardless of confidence
  is_identity <- hit$alias_clean == hit$substance_clean
  score  <- if (is_identity) 100 else hit$match_score
  status <- if (score >= 85 || is_identity) "accepted" else "review"
  .result(
    hit$substance_clean,
    status = status, score = score,
    source = hit$source,
    reason = paste0(
      "alias match (", hit$alias_type, "): '",
      hit$alias_clean, "' → '", hit$substance_clean, "'"
    )
  )
}

.attach_parent <- function(r, cfg) {
  if (is.na(r$active_substance_clean) || nrow(cfg$canonical) == 0) {
    return(r)
  }
  row <- cfg$canonical |>
    dplyr::filter(substance_clean == r$active_substance_clean) |>
    dplyr::slice(1)
  if (nrow(row) > 0) r$active_substance_parent <- row$parent_substance[1]
  r
}

.fuzzy_eligible <- function(candidates) {
  any(purrr::map_lgl(candidates, function(c) {
    nchar(c) >= 6 &&
      stringr::str_count(c, "\\s+") <= 3 &&   # reject long multi-word phrases
      !stringr::str_detect(
        c, stringr::regex(.dose_pattern, ignore_case = TRUE)
      ) &&
      !stringr::str_detect(
        c,
        stringr::regex(
          paste(.reject_patterns, collapse = "|"), ignore_case = TRUE
        )
      )
  }))
}

check_fuzzy <- function(candidates, cfg) {
  targets <- dplyr::bind_rows(
    if (nrow(cfg$canonical) > 0) {
      dplyr::select(cfg$canonical, substance_clean, source)
    } else tibble::tibble(substance_clean = character(), source = character()),
    if (nrow(cfg$alias) > 0) {
      cfg$alias |>
        dplyr::filter(!is.na(substance_clean)) |>
        dplyr::select(substance_clean, source)
    } else tibble::tibble(substance_clean = character(), source = character())
  ) |>
    dplyr::distinct(substance_clean, .keep_all = TRUE)

  if (nrow(targets) == 0) return(NULL)

  eligible <- candidates[nchar(candidates) >= 6]
  if (length(eligible) == 0) return(NULL)

  best_score <- 0
  best_row   <- NULL

  for (cand in eligible) {
    sims <- 1 - stringdist::stringdist(
      cand, targets$substance_clean, method = "jw"
    )
    idx <- which.max(sims)
    if (sims[idx] > best_score) {
      best_score <- sims[idx]
      best_row   <- targets[idx, ]
    }
  }

  if (is.null(best_row) || best_score < 0.80) return(NULL)

  score  <- round(best_score * 100)
  status <- if (score >= 85) "review" else "unknown"
  .result(
    best_row$substance_clean,
    status = status, score = score,
    source = paste0("fuzzy:", best_row$source),
    reason = paste0("fuzzy match (jw similarity ", score, "%)")
  )
}

# ── Core normaliser ───────────────────────────────────────────────────────────

.return <- function(raw, r) {
  r$active_substance_clean <- sanitise_substance_output(
    r$active_substance_clean
  )
  dplyr::bind_cols(tibble::tibble(raw_substance = raw), r)
}

normalise_one <- function(raw, cfg, allow_fuzzy = TRUE) {
  candidates <- generate_candidates(raw)

  r <- check_placebo(raw)
  if (!is.null(r)) return(.return(raw, r))

  r <- check_override(candidates, cfg)
  if (!is.null(r)) return(.return(raw, r))

  r <- check_negative(candidates, cfg)
  if (!is.null(r)) return(.return(raw, r))

  r <- check_pattern_reject(candidates)
  if (!is.null(r)) return(.return(raw, r))

  r <- check_canonical(candidates, cfg)
  if (!is.null(r)) return(.return(raw, .attach_parent(r, cfg)))

  r <- check_alias(candidates, cfg)
  if (!is.null(r)) return(.return(raw, .attach_parent(r, cfg)))

  if (allow_fuzzy && .fuzzy_eligible(candidates)) {
    r <- check_fuzzy(candidates, cfg)
    if (!is.null(r)) return(.return(raw, .attach_parent(r, cfg)))
  }

  .return(raw, .result(
    NA_character_,
    status = "unknown", score = 0,
    source = NA_character_, reason = "no reliable match"
  ))
}

normalise_substances <- function(raw_vec,
                                 config_dir = "config",
                                 configs    = NULL,
                                 allow_fuzzy = TRUE) {
  `%||%` <- function(a, b) if (!is.null(a)) a else b
  cfg         <- configs %||% load_substance_configs(config_dir)
  unique_vals <- unique(as.character(raw_vec))

  if (length(unique_vals) == 0) {
    return(tibble::tibble(
      raw_substance           = character(),
      active_substance_clean  = character(),
      active_substance_parent = character(),
      match_status            = character(),
      match_score             = numeric(),
      match_source            = character(),
      match_reason            = character()
    ))
  }

  lookup <- purrr::map_dfr(
    unique_vals, ~ normalise_one(.x, cfg = cfg, allow_fuzzy = allow_fuzzy)
  )
  tibble::tibble(raw_substance = as.character(raw_vec)) |>
    dplyr::left_join(lookup, by = "raw_substance")
}

# ── CLI entry point ───────────────────────────────────────────────────────────
if (!interactive() && sys.nframe() == 0L) {
  args       <- commandArgs(trailingOnly = TRUE)
  get_arg    <- function(prefix) {
    v <- args[startsWith(args, prefix)]
    if (length(v) == 0) return(NULL)
    stringr::str_remove(v[1], paste0("^", prefix))
  }

  input_csv  <- get_arg("--input=")
  output_csv <- get_arg("--output=")
  config_dir <- get_arg("--config-dir=") %||%
    file.path("config", "substance_norm_pipeline")
  write_queue <- "--write-queue" %in% args
  no_fuzzy    <- "--no-fuzzy"    %in% args

  if (is.null(input_csv) || !file.exists(input_csv)) {
    stop("Provide --input=path/to/file.csv with a raw_substance column")
  }
  if (is.null(output_csv)) {
    stop("Provide --output=path/to/result.csv")
  }

  df <- readr::read_csv(input_csv, show_col_types = FALSE)
  if (!"raw_substance" %in% names(df)) {
    stop(
      "Input CSV has no 'raw_substance' column.\n",
      "Columns found: ", paste(names(df), collapse = ", "), "\n",
      "Tip: this should be your trial data, not the brand index."
    )
  }
  out <- normalise_substances(
    df$raw_substance,
    config_dir  = config_dir,
    allow_fuzzy = !no_fuzzy
  )
  if ("n_trials" %in% names(df)) {
    out <- dplyr::left_join(
      out,
      dplyr::select(df, raw_substance, n_trials),
      by = "raw_substance"
    )
  }
  readr::write_csv(out, output_csv)
  message(sprintf("Wrote %d rows to %s", nrow(out), output_csv))

  if (write_queue) {
    queue_path <- file.path(config_dir, "substance_review_queue.csv")
    out_q <- if ("n_trials" %in% names(out)) {
      out
    } else {
      dplyr::mutate(out, n_trials = 1L)
    }
    queue <- out_q |>
      dplyr::filter(match_status %in% c("review", "unknown")) |>
      dplyr::group_by(
        raw_substance, active_substance_clean,
        match_status, match_score, match_source, match_reason
      ) |>
      dplyr::summarise(n_occurrences = sum(n_trials), .groups = "drop") |>
      dplyr::arrange(dplyr::desc(n_occurrences)) |>
      dplyr::mutate(
        decision            = NA_character_,
        canonical_substance = NA_character_,
        comment             = NA_character_
      )
    readr::write_csv(queue, queue_path)
    message(sprintf(
      "Wrote %d review/unknown rows to %s", nrow(queue), queue_path
    ))
  }
}
