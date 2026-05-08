# Refreshes the local EMA Paediatric Investigation Plan (PIP) decision lookup.
#
# The Shiny app never fetches EMA data at startup. Run this script when you want
# to refresh config/pip_decisions.csv from EMA's official downloadable data table.
#
# Usage:
#   Rscript helper_scripts/update_pip_decisions.R
#   Rscript helper_scripts/update_pip_decisions.R --enrich-missing [--cache PATH] [--delay SECS]
#
# --enrich-missing  After refreshing the bulk feed, fetch individual EMA pages
#                   for every EUCTR decision number absent from the feed.
#                   Requires: package 'rvest'; cache file (--cache or $CACHE_PATH).
# --cache PATH      Path to trials_cache.rds (default: $CACHE_PATH or data/trials_cache.rds).
# --delay SECS      Pause between HTTP requests in seconds (default: 2.0).

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(stringr)
})

# ─── Args & paths ─────────────────────────────────────────────────────────────
args           <- commandArgs(trailingOnly = TRUE)
enrich_missing <- "--enrich-missing" %in% args
{
  i <- which(args == "--cache")
  cache_arg <- if (length(i) && i < length(args)) args[i + 1] else NULL
}
{
  i <- which(args == "--delay")
  req_delay <- if (length(i) && i < length(args)) suppressWarnings(as.numeric(args[i + 1])) else 2.0
  if (is.na(req_delay) || req_delay < 0) req_delay <- 2.0
}

PIP_DATA_URL <- Sys.getenv(
  "EMA_PIP_DATA_URL",
  unset = "https://www.ema.europa.eu/en/documents/report/medicines-output-paediatric_investigation_plans-output-json-report_en.json"
)
OUT_PATH   <- Sys.getenv("PIP_DECISIONS_PATH", unset = "config/pip_decisions.csv")
CACHE_PATH <- if (!is.null(cache_arg)) cache_arg else Sys.getenv("CACHE_PATH", unset = "data/trials_cache.rds")

# ─── Shared helpers ───────────────────────────────────────────────────────────
clean_pip_decision_number <- function(x) {
  x <- as.character(x)
  out <- str_extract(x, regex("P/[0-9]{1,4}/[0-9]{4}", ignore_case = TRUE))
  out <- if_else(is.na(out), NA_character_, toupper(out))
  str_replace(out, "^P/0*([0-9]+)/", "P/\\1/")
}

clean_pip_procedure_number <- function(x) {
  x <- as.character(x)
  out <- str_extract(
    x,
    regex("(EMEA-[0-9]{6}-PIP[0-9]{2}-[0-9]{2}(?:-M[0-9]{2})?|EMA/PE/[0-9]{10})",
          ignore_case = TRUE)
  )
  if_else(is.na(out), NA_character_, toupper(out))
}

as_chr <- function(df, col) {
  if (is.na(col) || !col %in% names(df)) return(rep(NA_character_, nrow(df)))
  as.character(df[[col]])
}

# ─── Bulk feed download ───────────────────────────────────────────────────────
message("Downloading EMA PIP decisions JSON...")
tmp <- tempfile(fileext = ".json")
curl::curl_download(PIP_DATA_URL, tmp, quiet = FALSE)

message("Reading EMA PIP decisions JSON...")
payload <- jsonlite::fromJSON(tmp, flatten = TRUE)
raw <- as.data.frame(payload$data, stringsAsFactors = FALSE)
timestamp <- if (!is.null(payload$meta$timestamp)) payload$meta$timestamp else NA_character_

decision_type_text <- str_squish(as_chr(raw, "decision_type"))
decision_type_code <- str_extract(decision_type_text, "^[A-Z]+")
decision_title     <- decision_type_text

out <- tibble(
  pip_procedure_number  = clean_pip_procedure_number(as_chr(raw, "pip_number")),
  pip_decision_number   = clean_pip_decision_number(as_chr(raw, "decision_number")),
  ema_url               = as_chr(raw, "pip_url"),
  decision_type_code    = decision_type_code,
  decision_type_text    = decision_type_text,
  decision_title        = decision_title,
  decision_date         = as_chr(raw, "decision_date"),
  active_substance      = str_squish(as_chr(raw, "active_substance")),
  therapeutic_area      = str_squish(as_chr(raw, "therapeutic_area")),
  condition             = str_squish(as_chr(raw, "condition_indication")),
  compliance_check_done = str_squish(as_chr(raw, "compliance_outcome")),
  has_full_waiver       = decision_type_code == "W",
  # EMA's bulk decision_type for P records says "with or without partial
  # waiver(s) and or deferral(s)", which is a possibility class, not record-level
  # evidence. Leave partial waiver/deferral unknown unless a richer source is
  # added later.
  has_partial_waiver    = NA,
  has_deferral          = if_else(decision_type_code == "W", FALSE, NA),
  pdf_url               = NA_character_,
  parse_confidence      = "ema_bulk_table",
  fetched_at            = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  ema_feed_timestamp    = timestamp
) %>%
  filter(!is.na(pip_procedure_number) | !is.na(pip_decision_number)) %>%
  distinct()

if (!dir.exists(dirname(OUT_PATH))) dir.create(dirname(OUT_PATH), recursive = TRUE)
write.csv(out, OUT_PATH, row.names = FALSE, na = "")
message(sprintf(
  "Wrote %s rows (%s procedure numbers, %s decision numbers) to %s",
  format(nrow(out), big.mark = ","),
  format(sum(!is.na(out$pip_procedure_number)), big.mark = ","),
  format(sum(!is.na(out$pip_decision_number)), big.mark = ","),
  OUT_PATH
))

# ─── Per-decision page enrichment (--enrich-missing) ─────────────────────────
if (!enrich_missing) quit(save = "no", status = 0)

message("\n── Enrich-missing mode ─────────────────────────────────────────────────")

for (.pkg in c("rvest", "xml2", "httr2")) {
  if (!requireNamespace(.pkg, quietly = TRUE)) {
    stop(sprintf("Package '%s' is required for --enrich-missing.\n  Install: install.packages('%s')", .pkg, .pkg))
  }
}
suppressPackageStartupMessages({ library(rvest); library(xml2); library(httr2) })
rm(.pkg)

if (!file.exists(CACHE_PATH)) {
  stop(sprintf(
    "Cache not found: %s\nProvide path via --cache or $CACHE_PATH.", CACHE_PATH
  ))
}

message("Loading cache: ", CACHE_PATH)
cache <- readRDS(CACHE_PATH)

if (!"pip_decision_number" %in% names(cache)) {
  stop("Cache does not contain a 'pip_decision_number' column. Rebuild the cache first.")
}

euctr_decisions  <- unique(cache$pip_decision_number[!is.na(cache$pip_decision_number)])
already_covered  <- out$pip_decision_number[!is.na(out$pip_decision_number)]
missing_decisions <- setdiff(euctr_decisions, already_covered)

message(sprintf(
  "EUCTR decision numbers in cache : %d\nAlready in bulk feed            : %d\nTo scrape                       : %d  (delay: %.1fs each)",
  length(euctr_decisions),
  length(intersect(euctr_decisions, already_covered)),
  length(missing_decisions),
  req_delay
))

if (length(missing_decisions) == 0) {
  message("Nothing to enrich — all EUCTR decision numbers are already in the bulk feed.")
  quit(save = "no", status = 0)
}

# ── Per-page helpers ──────────────────────────────────────────────────────────

# Build an httr2 request with the same retry/throttle pattern used by ctrdata:
# - honours Retry-After on 429/503 automatically
# - exponential back-off when no Retry-After header is present
# - up to 10 tries, 120s total failure window
EMA_UA <- "ctrdata/1.26.1.9000 (https://cran.r-project.org/package=ctrdata)"

ema_request <- function(url) {
  httr2::request(url) |>
    httr2::req_user_agent(EMA_UA) |>
    httr2::req_throttle(rate = 1 / req_delay) |>
    httr2::req_retry(
      max_tries        = 10L,
      is_transient     = function(resp) httr2::resp_status(resp) %in% c(429L, 503L),
      failure_timeout  = 120L
    ) |>
    httr2::req_error(is_error = function(resp) FALSE)
}

pip_page_url <- function(decision_number) {
  slug <- tolower(str_replace_all(decision_number, "/", "-"))
  sprintf(
    "https://www.ema.europa.eu/en/medicines/human/paediatric-investigation-plans/%s", slug
  )
}

# Extract the first matching dd value given a dt label pattern.
get_field <- function(dt_vec, dd_vec, pattern) {
  idx <- which(str_detect(tolower(dt_vec), tolower(pattern)))
  if (!length(idx) || idx[1] > length(dd_vec)) return(NA_character_)
  str_squish(dd_vec[idx[1]])
}

scrape_pip_page <- function(url, decision_number) {
  tryCatch({
    resp <- httr2::req_perform(ema_request(url))
    if (httr2::resp_status(resp) != 200L) {
      message(sprintf("  [SKIP] %s: HTTP %d", decision_number, httr2::resp_status(resp)))
      return(NULL)
    }
    page      <- xml2::read_html(httr2::resp_body_string(resp))
    page_text <- rvest::html_text2(page)

    dt_text <- str_squish(rvest::html_text2(rvest::html_elements(page, "dt")))
    dd_text <- str_squish(rvest::html_text2(rvest::html_elements(page, "dd")))

    active_substance  <- get_field(dt_text, dd_text, "active substance")
    decision_type_raw <- get_field(dt_text, dd_text, "decision type|type of decision")
    procedure_raw     <- get_field(dt_text, dd_text, "pip number|procedure number|pip no")
    decision_date_raw <- get_field(dt_text, dd_text, "decision date")
    therapeutic_area  <- get_field(dt_text, dd_text, "therapeutic area")
    condition_raw     <- get_field(dt_text, dd_text, "condition|indication")

    # Fallback: regex scan of full page text for procedure number
    if (is.na(procedure_raw) ||
        !str_detect(coalesce(procedure_raw, ""), regex("EMEA|EMA/PE", ignore_case = TRUE))) {
      procedure_raw <- str_extract(
        page_text,
        regex("(EMEA-[0-9]{6}-PIP[0-9]{2}-[0-9]{2}(?:-M[0-9]{2})?|EMA/PE/[0-9]{10})",
              ignore_case = TRUE)
      )
    }

    dtt_lower  <- tolower(coalesce(decision_type_raw, ""))
    page_lower <- tolower(page_text)

    code <- dplyr::case_when(
      str_detect(dtt_lower, "full waiver|class waiver") ~ "W",
      str_detect(dtt_lower, "^w\\b|^w -")              ~ "W",
      str_detect(dtt_lower, "partial waiver")           ~ "PW",
      str_detect(dtt_lower, "modification")             ~ "M",
      str_detect(dtt_lower, "paediatric investigation plan") ~ "P",
      str_detect(dtt_lower, "^p\\b|^p -")              ~ "P",
      TRUE ~ toupper(str_extract(coalesce(decision_type_raw, ""), "^[A-Za-z]+"))
    )

    # Waiver/deferral flags from page text — more informative than bulk feed P records
    has_full_waiver    <- str_detect(page_lower, "full waiver|class waiver")
    has_partial_waiver <- str_detect(page_lower, "partial waiver")
    has_deferral       <- str_detect(page_lower, "deferral|deferred")

    pdf_href <- rvest::html_attr(rvest::html_element(page, "a[href$='.pdf']"), "href")
    pdf_url  <- if (!is.na(pdf_href) && !str_starts(coalesce(pdf_href, ""), "http")) {
      paste0("https://www.ema.europa.eu", pdf_href)
    } else {
      pdf_href
    }

    tibble(
      pip_procedure_number  = clean_pip_procedure_number(procedure_raw),
      pip_decision_number   = decision_number,
      ema_url               = url,
      decision_type_code    = code,
      decision_type_text    = decision_type_raw,
      decision_title        = decision_type_raw,
      decision_date         = decision_date_raw,
      active_substance      = active_substance,
      therapeutic_area      = therapeutic_area,
      condition             = condition_raw,
      compliance_check_done = NA_character_,
      has_full_waiver       = has_full_waiver,
      has_partial_waiver    = has_partial_waiver,
      has_deferral          = has_deferral,
      pdf_url               = pdf_url,
      parse_confidence      = "ema_per_page",
      fetched_at            = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      ema_feed_timestamp    = NA_character_
    )
  }, error = function(e) {
    message(sprintf("  [SKIP] %s: %s", decision_number, conditionMessage(e)))
    NULL
  })
}

# ── Scrape loop ───────────────────────────────────────────────────────────────
n_total  <- length(missing_decisions)
enriched <- vector("list", n_total)
n_ok     <- 0L
n_err    <- 0L

for (i in seq_along(missing_decisions)) {
  dn  <- missing_decisions[i]
  url <- pip_page_url(dn)
  if (i == 1 || i %% 10 == 0 || i == n_total) {
    message(sprintf("[%d/%d] %s  (ok: %d, skip: %d)", i, n_total, dn, n_ok, n_err))
  }
  row <- scrape_pip_page(url, dn)
  if (!is.null(row)) {
    enriched[[i]] <- row
    n_ok <- n_ok + 1L
  } else {
    n_err <- n_err + 1L
  }
  # req_throttle inside ema_request() enforces the per-request delay
}

enriched_df <- dplyr::bind_rows(enriched)
message(sprintf("\nScraping complete: %d succeeded, %d skipped/errored", n_ok, n_err))

if (nrow(enriched_df) == 0) {
  message("No rows scraped — pip_decisions.csv unchanged.")
  quit(save = "no", status = 0)
}

# Bulk feed rows take precedence; enriched_df only contains decision numbers that
# were absent from out, so a simple bind_rows produces no duplicates.
out_final <- bind_rows(out, enriched_df)
write.csv(out_final, OUT_PATH, row.names = FALSE, na = "")
message(sprintf(
  "Wrote %s total rows (%s bulk, %s per-page) to %s",
  format(nrow(out_final), big.mark = ","),
  format(nrow(out), big.mark = ","),
  format(nrow(enriched_df), big.mark = ","),
  OUT_PATH
))
