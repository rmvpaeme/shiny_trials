# Build config/sponsor_norm_pipeline/sponsor_alias_index.csv
# from manual aliases, EMA EPAR MAH names, and optionally ROR.
#
# Sources (priority order):
#   1. manual_sponsor_aliases.csv  (seed, confidence 1.00) — always included
#   2. EMA EPAR Marketing Authorisation Holders (confidence 0.85) — MAH name variants
#      for sponsors already in the manual alias table
#   3. ROR academic/hospital name variants (confidence 0.75, --no-ror to skip)
#
# Strategy: for EPAR/ROR, we look up each external name against the manual alias
# table using the same candidate generation logic. If a match is found, the
# external name becomes an additional alias for that canonical sponsor.
# Unmatched external names are written to new_sponsor_candidates.csv for review.
#
# Usage:
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-epar
#
# Outputs:
#   config/sponsor_norm_pipeline/sponsor_alias_index.csv       full merged alias table
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

args     <- commandArgs(trailingOnly = TRUE)
no_epar  <- "--no-epar" %in% args
no_ror   <- "--no-ror"  %in% args

SNP          <- project_path("config", "sponsor_norm_pipeline")
OUT_INDEX    <- file.path(SNP, "sponsor_alias_index.csv")
OUT_AMBIG    <- file.path(SNP, "sponsor_ambiguous_aliases.csv")
OUT_NEW      <- file.path(SNP, "new_sponsor_candidates.csv")

# ── Load normaliser helpers ───────────────────────────────────────────────────
source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = FALSE
)

# ── Manual aliases (seed) ─────────────────────────────────────────────────────

manual_path <- file.path(SNP, "manual_sponsor_aliases.csv")
manual <- readr::read_csv(manual_path, show_col_types = FALSE) |>
  dplyr::mutate(alias_clean = clean_sponsor_alias(alias_clean))

message(sprintf("Manual aliases: %d entries", nrow(manual)))

# Build a lookup table: alias_clean → canonical sponsor fields
# Used to resolve external source names against known canonicals.
alias_lookup <- manual |>
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
      labels <- purrr::map_chr(org$labels, ~ .x$label %||% NA_character_)
      names_vec <- c(names_vec, labels[!is.na(labels)])
    }
    if (!is.null(org$acronyms) && length(org$acronyms) > 0) {
      names_vec <- c(names_vec, unlist(org$acronyms))
    }
    unique(names_vec[nzchar(names_vec)])
  }

  `%||%` <- function(a, b) if (!is.null(a)) a else b

  message("Querying ROR for EU academic/hospital organizations...")

  ror_all_names <- character(0)

  for (country in EU_COUNTRIES) {
    for (type in ROR_TYPES) {
      page1 <- fetch_ror_page(1, country, type)
      if (is.null(page1)) next

      total     <- page1$number_of_results %||% 0L
      n_pages   <- ceiling(total / 20)
      if (n_pages == 0) next

      message(sprintf("  %s/%s: %d orgs, %d pages", country, type, total, n_pages))

      orgs <- page1$items %||% list()
      for (p in seq_len(min(n_pages, 50))) {  # cap at 50 pages (1000 orgs) per combo
        if (p > 1) {
          Sys.sleep(0.05)
          pg <- fetch_ror_page(p, country, type)
          if (!is.null(pg)) orgs <- c(orgs, pg$items %||% list())
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

# ── Merge ─────────────────────────────────────────────────────────────────────

# Prepare manual seed in the same schema
manual_index <- manual |>
  dplyr::mutate(alias_type = "manual") |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
    sponsor_type, alias_type, source, confidence_prior
  )

# Row order = priority: manual > epar > ror
combined <- dplyr::bind_rows(manual_index, epar_rows, ror_rows) |>
  dplyr::filter(
    !is.na(alias_clean), !is.na(sponsor_clean),
    nchar(alias_clean) >= 2, nchar(sponsor_clean) >= 2
  ) |>
  dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE)

message(sprintf("Combined index: %d total alias entries", nrow(combined)))

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

new_candidates <- new_candidates |>
  dplyr::distinct(alias_clean, source, .keep_all = TRUE) |>
  dplyr::filter(nchar(alias_clean) >= 4) |>
  dplyr::arrange(source, alias_clean)

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
