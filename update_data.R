# ============================================================================
# update_data.R  (v12 — euctrresults weekly guard + FORCE_RESULTS override)
# ============================================================================
# Normal run:  Rscript update_data.R
#   - Updates EUCTR trial records (always; EUCTR has no incremental API so all
#     371 pages are fetched, but only changed records are imported)
#   - Updates CTIS records (always)
#   - Skips euctrresults if last run was < 7 days ago
#
# Force results: FORCE_RESULTS=true Rscript update_data.R
#   - Runs euctrresults regardless of last-run date
#
# Skip EUCTR entirely: SKIP_EUCTR=true Rscript update_data.R
# ============================================================================

library(ctrdata)
library(dplyr)

options(expressions = 500000)

try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)

DB_PATH       <- "./data/pediatric_trials.sqlite"
DB_COLLECTION <- "trials"
RESULTS_STAMP <- "./data/.last_results_update"
RESULTS_TTL_DAYS <- 7L

db <- nodbi::src_sqlite(dbname = DB_PATH, collection = DB_COLLECTION)

# ============================================================================
# Helpers
# ============================================================================

days_since_stamp <- function(path) {
  if (!file.exists(path)) return(Inf)
  as.numeric(difftime(Sys.time(), file.mtime(path), units = "days"))
}

# ============================================================================
# Patch dplyr::rows_update (needed for EUCTR euctrresults)
# ============================================================================

original_rows_update <- dplyr::rows_update

patched_rows_update <- function(x, y, by = NULL, ...,
                                unmatched = "ignore",
                                copy = FALSE, in_place = FALSE) {
  if (is.null(by)) by <- intersect(names(x), names(y))
  if (length(by) > 0 && nrow(y) > 0) {
    tryCatch({
      y <- y[!duplicated(y[, by, drop = FALSE], fromLast = TRUE), ]
      ky <- do.call(paste, c(y[, by, drop = FALSE], sep = "\x01"))
      kx <- do.call(paste, c(x[, by, drop = FALSE], sep = "\x01"))
      y  <- y[ky %in% kx, ]
    }, error = function(e) {
      message("[patch] Key dedup fallback: ", e$message)
    })
  }
  if (nrow(y) == 0) return(x)
  original_rows_update(x, y, by = by, ...,
                       unmatched = "ignore", copy = copy, in_place = in_place)
}

# ============================================================================
# 1. EU Clinical Trials Register (EUCTR)
# ============================================================================
message("\n=== 1/2  EUCTR ===")

skip_euctr <- identical(Sys.getenv("SKIP_EUCTR"), "true")

if (skip_euctr) {
  message("SKIP_EUCTR=true — skipping EUCTR update.")
} else {
  # Decide whether to fetch euctrresults
  force_results  <- identical(Sys.getenv("FORCE_RESULTS"), "true")
  days_since     <- days_since_stamp(RESULTS_STAMP)
  fetch_results  <- force_results || (days_since >= RESULTS_TTL_DAYS)

  if (fetch_results) {
    message(sprintf(
      "euctrresults: YES (last run %.1f days ago%s)",
      days_since,
      if (force_results) " — FORCE_RESULTS override" else ""
    ))
  } else {
    message(sprintf(
      "euctrresults: SKIPPED (last run %.1f days ago, TTL=%d days). Set FORCE_RESULTS=true to override.",
      days_since, RESULTS_TTL_DAYS
    ))
  }

  euctr_url_raw <- paste0(
    "https://www.clinicaltrialsregister.eu/ctr-search/search?",
    "query=&age=adolescent&age=children&age=infant-and-toddler&age=newborn&age=preterm-new-born-infants&age=under-18"
  )
  euctr_q <- ctrGetQueryUrl(url = euctr_url_raw)

  assignInNamespace("rows_update", patched_rows_update, ns = "dplyr")

  euctr_loaded <- FALSE
  if (fetch_results) {
    tryCatch({
      message("Loading EUCTR with euctrresults = TRUE ...")
      ctrLoadQueryIntoDb(queryterm = euctr_q, euctrresults = TRUE, con = db)
      euctr_loaded <- TRUE
      # Record successful results fetch
      writeLines(as.character(Sys.time()), RESULTS_STAMP)
      message("EUCTR (with results) complete.")
    }, error = function(e) {
      message("euctrresults = TRUE failed: ", e$message)
    })
  }

  if (!euctr_loaded) {
    tryCatch({
      msg <- if (fetch_results) "Retrying EUCTR without results ..." else "Loading EUCTR (records only) ..."
      message(msg)
      ctrLoadQueryIntoDb(queryterm = euctr_q, euctrresults = FALSE, con = db)
      euctr_loaded <- TRUE
      message("EUCTR (without results) complete.")
    }, error = function(e) {
      message("EUCTR load failed entirely: ", e$message)
    })
  }

  assignInNamespace("rows_update", original_rows_update, ns = "dplyr")
}

message("EUCTR done.\n")

# ============================================================================
# 2. Clinical Trials Information System (CTIS)
# ============================================================================
message("=== 2/2  CTIS ===")

ctis_url <- paste0(
  "https://euclinicaltrials.eu/ctis-public/search#searchCriteria={%22ageGroupCode%22:[2]}"
)

ctis_q <- ctrGetQueryUrl(ctis_url)

tryCatch({
  ctrLoadQueryIntoDb(queryterm = ctis_q, register = "CTIS", con = db)
  message("CTIS load complete.\n")
}, error = function(e) {
  message("CTIS load failed: ", e$message, "\n")
})

# ============================================================================
# Finish
# ============================================================================
message("Running VACUUM to compress database...")
con <- DBI::dbConnect(RSQLite::SQLite(), DB_PATH)
DBI::dbExecute(con, "VACUUM")
DBI::dbDisconnect(con)

message(sprintf(
  "Done. Database: %s (%s bytes)",
  normalizePath(DB_PATH),
  format(file.size(DB_PATH), big.mark = ",")
))
