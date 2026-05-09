# helper_scripts/build_substance_index.R
# Builds config/substance_alias_index.csv from manual overrides, EPAR, and ChEMBL.
# Run once manually before cache rebuild, like update_pip_decisions.R.
#
# Usage:
#   Rscript helper_scripts/build_substance_index.R             # manual + EPAR + ChEMBL
#   Rscript helper_scripts/build_substance_index.R --no-chembl # manual + EPAR only
#
# Outputs:
#   config/substance_alias_index.csv       full alias → substance table with metadata
#   config/ambiguous_substance_aliases.csv aliases that map to more than one substance

suppressPackageStartupMessages({
  library(httr2)
  library(readxl)
  library(dplyr)
  library(stringr)
  library(readr)
  library(purrr)
  library(tibble)
})

args      <- commandArgs(trailingOnly = TRUE)
no_chembl <- "--no-chembl" %in% args

OUT_INDEX     <- file.path("config", "substance_alias_index.csv")
OUT_AMBIGUOUS <- file.path("config", "ambiguous_substance_aliases.csv")

# ── Shared cleaning helpers ───────────────────────────────────────────────────
# Canonical definitions — also sourced by normalise_substances.R via source().

clean_alias <- function(x) {
  x |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[ ​‌‍]", " ") |>
    stringr::str_replace_all("[®™]", "") |>
    stringr::str_replace_all("[‘’]", "'") |>
    stringr::str_replace_all("[–—−]", "-") |>
    stringr::str_replace_all("\\s+", " ") |>
    stringr::str_squish()
}

clean_substance <- function(x) {
  x |>
    clean_alias() |>
    # Normalise combination separators to |; combination products are NOT ambiguous aliases
    stringr::str_replace_all("\\s*/\\s*", "|") |>
    stringr::str_replace_all("\\s*;\\s*", "|") |>
    stringr::str_replace_all("\\s*\\|\\s*", "|") |>
    stringr::str_squish()
}

# ── Manual brand overrides (highest priority) ─────────────────────────────────
manual_path <- file.path("config", "manual_brand_to_substance.csv")
manual_brand <- if (file.exists(manual_path)) {
  readr::read_csv(manual_path, show_col_types = FALSE) |>
    dplyr::mutate(
      alias_clean     = clean_alias(alias_clean),
      substance_clean = clean_substance(substance_clean)
    ) |>
    dplyr::select(alias_clean, substance_clean, alias_type, source, confidence_prior)
} else {
  tibble::tibble(
    alias_clean      = character(),
    substance_clean  = character(),
    alias_type       = character(),
    source           = character(),
    confidence_prior = numeric()
  )
}
message(sprintf("Manual brands: %d entries", nrow(manual_brand)))

# ── EPAR ──────────────────────────────────────────────────────────────────────
EPAR_URL <- "https://www.ema.europa.eu/en/documents/report/medicines-output-medicines-report_en.xlsx"

message("Downloading EMA medicines report...")
dest <- tempfile(fileext = ".xlsx")
request(EPAR_URL) |>
  req_timeout(180) |>
  req_perform() |>
  resp_body_raw() |>
  writeBin(dest)
message("Download complete.")

# EMA Excel layout: rows 1-8 are metadata, row 9 is the header row, data from row 10.
raw_excel <- readxl::read_excel(dest, col_names = FALSE, skip = 0)
headers   <- as.character(raw_excel[9, ])
data_rows <- raw_excel[10:nrow(raw_excel), ]
colnames(data_rows) <- headers

name_col  <- grep("name of medicine", names(data_rows), ignore.case = TRUE, value = TRUE)[1]
subst_col <- grep("active substance",  names(data_rows), ignore.case = TRUE, value = TRUE)[1]

if (is.na(name_col) || is.na(subst_col)) {
  stop(
    "Could not identify medicine name and active substance columns.\n",
    "Columns found: ", paste(names(data_rows), collapse = ", ")
  )
}

epar <- data_rows |>
  dplyr::select(product_name = dplyr::all_of(name_col),
                substance    = dplyr::all_of(subst_col)) |>
  dplyr::filter(
    !is.na(product_name), !is.na(substance),
    nchar(stringr::str_squish(product_name)) > 0,
    nchar(stringr::str_squish(substance)) > 0
  ) |>
  dplyr::mutate(
    alias_clean      = clean_alias(product_name),
    substance_clean  = clean_substance(substance),
    alias_type       = "ema_product_name",
    source           = "epar",
    confidence_prior = 0.95
  ) |>
  dplyr::select(alias_clean, substance_clean, alias_type, source, confidence_prior) |>
  dplyr::distinct()

message(sprintf("EPAR: %d alias-substance pairs", nrow(epar)))

# ── ChEMBL REST ───────────────────────────────────────────────────────────────
chembl <- tibble::tibble(
  alias_clean      = character(),
  substance_clean  = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)

if (!no_chembl) {
  CHEMBL_URL <- "https://www.ebi.ac.uk/chembl/api/data/molecule"

  fetch_page <- function(offset, limit = 1000) {
    request(CHEMBL_URL) |>
      req_url_query(format = "json", limit = limit, offset = offset,
                    max_phase__gte = 1) |>
      req_timeout(60) |>
      req_retry(max_tries = 3) |>
      req_perform() |>
      resp_body_json()
  }

  message("Fetching ChEMBL molecule count...")
  meta  <- fetch_page(0, 1)
  total <- meta$page_meta$total_count
  n_req <- ceiling(total / 1000)
  message(sprintf("ChEMBL: %d molecules, %d pages", total, n_req))

  parse_molecule <- function(mol) {
    pref <- mol$pref_name
    if (is.null(pref) || is.na(pref) || !nzchar(stringr::str_trim(pref))) return(NULL)
    syns <- mol$molecule_synonyms
    if (length(syns) == 0) return(NULL)

    purrr::map_dfr(syns, function(s) {
      syn_type <- s$syn_type
      synonym  <- s$molecule_synonym
      if (is.null(synonym) || is.null(syn_type)) return(NULL)

      alias_type <- dplyr::case_when(
        syn_type == "TRADE_NAME" ~ "trade_name",
        syn_type == "USAN"       ~ "usan",
        syn_type == "BAN"        ~ "ban",
        TRUE                     ~ "chembl_synonym"
      )
      confidence <- dplyr::case_when(
        syn_type == "TRADE_NAME" ~ 0.90,
        syn_type == "USAN"       ~ 0.85,
        syn_type == "BAN"        ~ 0.85,
        TRUE                     ~ 0.65
      )

      tibble::tibble(
        alias_clean      = clean_alias(synonym),
        substance_clean  = clean_substance(pref),
        alias_type       = alias_type,
        source           = "chembl",
        confidence_prior = confidence
      )
    })
  }

  offsets     <- seq(0, (n_req - 1) * 1000, by = 1000)
  chembl_rows <- vector("list", length(offsets))

  for (i in seq_along(offsets)) {
    if (i %% 10 == 1) message(sprintf("  page %d / %d", i, n_req))
    Sys.sleep(0.1)
    page <- fetch_page(offsets[i])
    chembl_rows[[i]] <- purrr::map_dfr(page$molecules, parse_molecule)
  }

  chembl <- dplyr::bind_rows(chembl_rows)
  message(sprintf("ChEMBL: %d alias-substance pairs", nrow(chembl)))
}

# ── Merge ─────────────────────────────────────────────────────────────────────
# Row order encodes priority: manual > epar > chembl.
# Ambiguous aliases (one alias → multiple substances) are flagged but NOT dropped.
combined <- dplyr::bind_rows(manual_brand, epar, chembl) |>
  dplyr::filter(
    !is.na(alias_clean),
    !is.na(substance_clean),
    nchar(alias_clean) >= 3,
    nchar(substance_clean) >= 3
  ) |>
  dplyr::distinct(alias_clean, substance_clean, alias_type, source, confidence_prior)

# Identify aliases that map to more than one distinct substance
n_per_alias <- combined |>
  dplyr::distinct(alias_clean, substance_clean) |>
  dplyr::count(alias_clean, name = "n_substances")

ambiguous_detail <- combined |>
  dplyr::filter(alias_clean %in% (n_per_alias |> dplyr::filter(n_substances > 1))$alias_clean) |>
  dplyr::group_by(alias_clean) |>
  dplyr::summarise(
    substances_all = paste(sort(unique(substance_clean)), collapse = "|"),
    n_substances   = dplyr::n_distinct(substance_clean),
    sources        = paste(sort(unique(source)), collapse = "|"),
    .groups        = "drop"
  )

message(sprintf(
  "Ambiguous aliases: %d (same alias → multiple substances — review before accepting)",
  nrow(ambiguous_detail)
))

readr::write_csv(ambiguous_detail, OUT_AMBIGUOUS)
message(sprintf("Wrote %d ambiguous aliases to %s", nrow(ambiguous_detail), OUT_AMBIGUOUS))

readr::write_csv(combined, OUT_INDEX)
message(sprintf("Wrote %d total alias-substance pairs to %s", nrow(combined), OUT_INDEX))
message("Done.")
