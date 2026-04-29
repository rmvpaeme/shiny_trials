# ============================================================================
# update_data.R  (v15 — resilient EUCTR ingestion engine)
# ============================================================================

library(ctrdata)
library(dplyr)

options(expressions = 500000)

try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)

DB_PATH <- "./data/trials.sqlite"
DB_COLLECTION <- "trials"

DONE_LOG   <- "./data/done_chunks.txt"
FAILED_LOG <- "./data/failed_chunks.txt"

db <- nodbi::src_sqlite(dbname = DB_PATH, collection = DB_COLLECTION)

# ============================================================================
# LOG HELPERS
# ============================================================================

read_log <- function(path) {
  if (file.exists(path)) readLines(path) else character()
}

append_log <- function(path, value) {
  write(value, file = path, append = TRUE)
}

# ============================================================================
# SAFE LOADER (bulk attempt)
# ============================================================================

try_load <- function(start_date, end_date, label) {

  url <- sprintf(
    "https://www.clinicaltrialsregister.eu/ctr-search/search?query=&dateFrom=%s&dateTo=%s",
    start_date, end_date
  )

  tryCatch({

    ctrLoadQueryIntoDb(
      queryterm = ctrGetQueryUrl(url),
      euctrresults = FALSE,
      con = db
    )

    message(sprintf("[%s] OK", label))
    TRUE

  }, error = function(e) {

    message(sprintf("[%s] FAIL: %s", label, e$message))
    FALSE
  })
}

# ============================================================================
# LAYER 3 — TRIAL-LEVEL FALLBACK
# ============================================================================

load_trial_fallback <- function(start_date, end_date) {

  label <- sprintf("TRIAL %s → %s", start_date, end_date)

  message(sprintf("[%s] switching to trial-level fallback", label))

  url <- sprintf(
    "https://www.clinicaltrialsregister.eu/ctr-search/search?query=&dateFrom=%s&dateTo=%s",
    start_date, end_date
  )

  tryCatch({

    ctrLoadQueryIntoDb(
      queryterm = ctrGetQueryUrl(url),
      euctrresults = FALSE,
      con = db
    )

    append_log(DONE_LOG, label)
    TRUE

  }, error = function(e) {

    message(sprintf("[%s] FAILED permanently: %s", label, e$message))

    append_log(FAILED_LOG, label)
    FALSE
  })
}

# ============================================================================
# RECURSIVE ENGINE (THE CORE)
# ============================================================================

load_range <- function(start_date, end_date, depth = 1, max_depth = 3) {

  label <- sprintf("%s → %s", start_date, end_date)

  done <- read_log(DONE_LOG)
  if (label %in% done) {
    message(sprintf("[%s] skipped (done)", label))
    return(TRUE)
  }

  message(sprintf("[%s] depth=%d start", label, depth))

  ok <- try_load(start_date, end_date, label)

  if (ok) {
    append_log(DONE_LOG, label)
    return(TRUE)
  }

  # --------------------------------------------------------------------------
  # LAYER 2 — SPLIT STRATEGY
  # --------------------------------------------------------------------------

  if (depth < max_depth) {

    start <- as.Date(start_date)
    end   <- as.Date(end_date)

    mid <- start + floor((end - start) / 2)

    message(sprintf("[%s] splitting range", label))

    load_range(as.character(start), as.character(mid), depth + 1, max_depth)
    load_range(as.character(mid + 1), as.character(end), depth + 1, max_depth)

    return(TRUE)
  }

  # --------------------------------------------------------------------------
  # LAYER 3 — TRIAL FALLBACK
  # --------------------------------------------------------------------------

  load_trial_fallback(start_date, end_date)
}

# ============================================================================
# DATE GENERATION (QUARTERLY START)
# ============================================================================

make_quarters <- function(year) {
  list(
    c(sprintf("%d-01-01", year), sprintf("%d-03-31", year)),
    c(sprintf("%d-04-01", year), sprintf("%d-06-30", year)),
    c(sprintf("%d-07-01", year), sprintf("%d-09-30", year)),
    c(sprintf("%d-10-01", year), sprintf("%d-12-31", year))
  )
}

# ============================================================================
# MAIN EUCTR INGESTION
# ============================================================================

message("\n=== EUCTR ingestion (v15) ===")

current_year <- as.integer(format(Sys.Date(), "%Y"))

for (yr in 2004:current_year) {

  message(sprintf("\n=== YEAR %d ===", yr))

  quarters <- make_quarters(yr)

  for (q in quarters) {

    load_range(q[1], q[2])
  }
}

message("EUCTR ingestion complete.\n")

# ============================================================================
# CTIS (unchanged)
# ============================================================================

message("=== CTIS ===")

ctis_url <- "https://euclinicaltrials.eu/ctis-public/search#searchCriteria={}"

tryCatch({

  ctrLoadQueryIntoDb(
    queryterm = ctrGetQueryUrl(ctis_url),
    register = "CTIS",
    con = db
  )

  message("CTIS done.")

}, error = function(e) {

  message("CTIS failed: ", e$message)
})

# ============================================================================
# DONE
# ============================================================================

message("Finished.")