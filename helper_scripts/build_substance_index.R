# helper_scripts/build_substance_index.R
# Builds config/epar_brand_inn.csv from EPAR + ChEMBL REST API.
# Run once manually before cache rebuild, like update_pip_decisions.R.
#
# Usage:
#   Rscript helper_scripts/build_substance_index.R             # EPAR + ChEMBL
#   Rscript helper_scripts/build_substance_index.R --no-chembl # EPAR only
#
# Output: config/epar_brand_inn.csv  (brand_name_clean, substance_clean)

suppressPackageStartupMessages({
  library(httr2)
  library(readxl)
  library(dplyr)
  library(stringr)
  library(readr)
  library(purrr)
})

args      <- commandArgs(trailingOnly = TRUE)
no_chembl <- "--no-chembl" %in% args
OUT_CSV   <- file.path("config", "epar_brand_inn.csv")

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
raw <- read_excel(dest, col_names = FALSE, skip = 0)

headers   <- as.character(raw[9, ])
data_rows <- raw[10:nrow(raw), ]
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
  select(brand_name = all_of(name_col), substance = all_of(subst_col)) |>
  filter(
    !is.na(brand_name), !is.na(substance),
    nchar(str_squish(brand_name)) > 0, nchar(str_squish(substance)) > 0
  ) |>
  mutate(
    brand_name_clean = tolower(str_squish(brand_name)),
    substance_clean  = tolower(str_squish(substance)),
    source           = "epar"
  ) |>
  select(brand_name_clean, substance_clean, source) |>
  distinct()

message(sprintf("EPAR: %d brand-substance pairs", nrow(epar)))

# ── ChEMBL REST ───────────────────────────────────────────────────────────────
# Fetches all molecules with max_phase >= 1 (clinical-stage or approved).
# For each molecule: pref_name = canonical INN; TRADE_NAME / BAN / USAN synonyms
# = brand/approved names to map from.
chembl <- tibble(brand_name_clean = character(), substance_clean = character(),
                 source = character())

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
    if (is.null(pref) || is.na(pref) || !nzchar(str_trim(pref))) return(NULL)
    syns <- mol$molecule_synonyms
    if (length(syns) == 0) return(NULL)
    brand_names <- keep(syns, ~ .x$syn_type %in% c("TRADE_NAME", "BAN", "USAN")) |>
      map_chr(~ .x$molecule_synonym)
    if (length(brand_names) == 0) return(NULL)
    tibble(
      brand_name_clean = tolower(str_squish(brand_names)),
      substance_clean  = tolower(str_squish(pref)),
      source           = "chembl"
    )
  }

  offsets <- seq(0, (n_req - 1) * 1000, by = 1000)
  chembl_rows <- vector("list", length(offsets))

  for (i in seq_along(offsets)) {
    if (i %% 10 == 1) message(sprintf("  page %d / %d", i, n_req))
    Sys.sleep(0.1)
    page <- fetch_page(offsets[i])
    chembl_rows[[i]] <- map_dfr(page$molecules, parse_molecule)
  }

  chembl <- bind_rows(chembl_rows)
  message(sprintf("ChEMBL: %d brand-substance pairs", nrow(chembl)))
}

# ── Merge: EPAR takes precedence over ChEMBL for the same brand name ─────────
combined <- bind_rows(epar, chembl) |>
  filter(nchar(brand_name_clean) >= 3, nchar(substance_clean) >= 3) |>
  group_by(brand_name_clean) |>
  arrange(brand_name_clean, factor(source, levels = c("epar", "chembl"))) |>
  slice(1) |>
  ungroup() |>
  select(brand_name_clean, substance_clean) |>
  distinct()

message(sprintf("Writing %d total pairs to %s", nrow(combined), OUT_CSV))
write_csv(combined, OUT_CSV)
message("Done.")
