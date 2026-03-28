# ============================================================================
# update_data.R  (v11 — EUCTR + CTIS + CTGOV)
# ============================================================================

library(ctrdata)
library(dplyr)

options(expressions = 500000)

try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)

DB_PATH       <- "./data/pediatric_trials.sqlite"
DB_COLLECTION <- "trials"

db <- nodbi::src_sqlite(dbname = DB_PATH, collection = DB_COLLECTION)

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
message("\n=== 1/3  EUCTR ===")

assignInNamespace("rows_update", patched_rows_update, ns = "dplyr")

euctr_q <- ctrGetQueryUrl(
  url = paste0(
    "https://www.clinicaltrialsregister.eu/ctr-search/search?",
    "query=&age=adolescent&age=children&age=infant-and-toddler&age=newborn&age=preterm-new-born-infants&age=under-18"
  )
)

euctr_loaded <- FALSE
tryCatch({
  message("Loading EUCTR with euctrresults = TRUE ...")
  ctrLoadQueryIntoDb(queryterm = euctr_q, euctrresults = TRUE, con = db)
  euctr_loaded <- TRUE
  message("EUCTR (with results) complete.")
}, error = function(e) {
  message("euctrresults = TRUE failed: ", e$message)
})

if (!euctr_loaded) {
  tryCatch({
    message("Retrying EUCTR with euctrresults = FALSE ...")
    ctrLoadQueryIntoDb(queryterm = euctr_q, euctrresults = FALSE, con = db)
    message("EUCTR (without results) complete.")
  }, error = function(e) {
    message("EUCTR load failed entirely: ", e$message)
  })
}

assignInNamespace("rows_update", original_rows_update, ns = "dplyr")
message("EUCTR done.\n")

# ============================================================================
# 2. Clinical Trials Information System (CTIS)
# ============================================================================
message("=== 2/3  CTIS ===")

ctis_url <- paste0(
  "https://euclinicaltrials.eu/ctis-public/search#searchCriteria={%22ageGroupCode%22:[2]}"
  #  "https://euclinicaltrials.eu/ctis-public/search#searchCriteria=",
  #  "{%22containAll%22:%22%22,",
  #  "%22containAny%22:%22pediatric,infant,neonatal,adolescent,children%22,",
  #  "%22containNot%22:%22%22}"
)

ctis_q <- ctrGetQueryUrl(ctis_url)

tryCatch({
  ctrLoadQueryIntoDb(queryterm = ctis_q, register = "CTIS", con = db)
  message("CTIS load complete.\n")
}, error = function(e) {
  message("CTIS load failed: ", e$message, "\n")
})

# ============================================================================
# 3. ClinicalTrials.gov (CTGOV2)
# ============================================================================
message("=== 3/3  CTGOV (ClinicalTrials.gov) ===")

ctgov_url <- paste0(
  "https://clinicaltrials.gov/search?aggFilters=ages:child"
)

ctgov_q <- ctrGetQueryUrl(ctgov_url, register = "CTGOV2")

tryCatch({
  ctrLoadQueryIntoDb(queryterm = ctgov_q, register = "CTGOV2", con = db)
  message("CTGOV load complete.\n")
}, error = function(e) {
  message("CTGOV load failed: ", e$message, "\n")
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

