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

.rd_rx <- paste0(
  "\\b(",
  paste(c(
    "international", "pharmaceuticals", "biologicals", "biosciences",
    "sciences", "therapeutics", "oncology", "diagnostics",
    "europe", "north america", "global"
  ), collapse = "|"),
  ")\\b"
)

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

  toks         <- stringr::str_split(x0, "\\s+")[[1]]
  first_tokens <- paste(utils::head(toks, 3), collapse = " ")

  candidates <- unique(stats::na.omit(c(
    x0, x_no_addr, x_no_legal, x_no_rd, first_tokens
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
  # fall back to the hand-maintained seed table if the index hasn't been built.
  alias_index <- file.path(config_dir, "sponsor_alias_index.csv")
  alias_seed  <- file.path(config_dir, "manual_sponsor_aliases.csv")
  list(
    aliases   = read_csv_safe(
      if (file.exists(alias_index)) alias_index else alias_seed
    ),
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
  top_hits  <- hits |> dplyr::filter(match_score >= top_score - 2)

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

check_fuzzy <- function(candidates, cfg) {
  if (nrow(cfg$aliases) == 0) return(NULL)

  targets <- cfg$aliases |>
    dplyr::filter(!is.na(sponsor_clean)) |>
    dplyr::distinct(sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, source)

  if (nrow(targets) == 0) return(NULL)

  eligible <- candidates[
    nchar(candidates) >= 6 & !candidates %in% .fuzzy_block_tokens
  ]
  if (length(eligible) == 0) return(NULL)

  best_score <- 0
  best_row   <- NULL

  for (cand in eligible) {
    sims <- 1 - stringdist::stringdist(cand, targets$sponsor_clean, method = "jw")
    idx  <- which.max(sims)
    if (sims[idx] > best_score) {
      best_score <- sims[idx]
      best_row   <- targets[idx, , drop = FALSE]
    }
  }

  if (is.null(best_row) || best_score < 0.92) return(NULL)

  score <- round(best_score * 100)
  .result(
    best_row$sponsor_clean, best_row$sponsor_parent,
    best_row$sponsor_group, best_row$sponsor_type,
    status = "review", score = score,
    source = paste0("fuzzy:", best_row$source),
    reason = paste0("fuzzy match (jw similarity ", score, "%)")
  )
}

# ── Core normaliser ───────────────────────────────────────────────────────────

.return_sponsor <- function(raw, r) {
  dplyr::bind_cols(tibble::tibble(raw_sponsor = raw), r)
}

normalise_one <- function(raw, cfg, allow_fuzzy = TRUE) {
  raw_clean  <- clean_sponsor_alias(raw)
  candidates <- make_sponsor_candidates(raw)

  r <- check_override(candidates, cfg)
  if (!is.null(r)) return(.return_sponsor(raw, r))

  r <- check_negative(candidates, cfg)
  if (!is.null(r)) return(.return_sponsor(raw, r))

  r <- check_alias(candidates, cfg)
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
