# ============================================================================
# update_data.R  (v16 — resilient EUCTR ingestion engine)
# ============================================================================

library(ctrdata)
library(dplyr)

options(expressions = 500000)

try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)

DB_PATH <- "./data/trials.sqlite"
DB_COLLECTION <- "trials"

DONE_LOG   <- "./data/done_chunks.txt"
FAILED_LOG <- "./data/failed_chunks.txt"

HTTP_TIMEOUT_SEC <- 30L
HTTP_RETRIES <- 2L

options(timeout = max(getOption("timeout"), HTTP_TIMEOUT_SEC))

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

read_url_lines <- function(url, label, timeout_sec = HTTP_TIMEOUT_SEC,
                           retries = HTTP_RETRIES) {
  last_error <- NULL

  for (attempt in seq_len(retries + 1L)) {
    old_timeout <- getOption("timeout")
    options(timeout = timeout_sec)
    on.exit(options(timeout = old_timeout), add = TRUE)

    out <- tryCatch(
      readLines(url, warn = FALSE),
      error = function(e) {
        last_error <<- e
        NULL
      }
    )

    options(timeout = old_timeout)

    if (!is.null(out)) return(out)

    message(sprintf(
      "[%s] read failed%s: %s",
      label,
      if (attempt <= retries) sprintf(" (attempt %d/%d)", attempt, retries + 1L) else "",
      conditionMessage(last_error)
    ))
  }

  stop(sprintf("Could not read %s after %d attempt(s): %s",
               label, retries + 1L, conditionMessage(last_error)))
}

# ============================================================================
# EUCTR QUERY HELPERS
# ============================================================================

make_euctr_url <- function(start_date, end_date) {
  sprintf(
    "https://www.clinicaltrialsregister.eu/ctr-search/search?query=&dateFrom=%s&dateTo=%s",
    start_date, end_date
  )
}

get_euctr_ids_for_range <- function(start_date, end_date) {

  query <- ctrGetQueryUrl(make_euctr_url(start_date, end_date))
  queryterm <- query[nrow(query), "query-term", drop = TRUE]

  search_url <- sprintf(
    "https://www.clinicaltrialsregister.eu/ctr-search/search?%s",
    queryterm
  )

  search_page <- read_url_lines(search_url, sprintf("%s search page", start_date))
  search_page <- paste(search_page, collapse = "\n")

  n_trials <- sub(
    ".*Trials with a EudraCT protocol \\(([0-9,.]*)\\).*",
    "\\1",
    search_page
  )
  n_trials <- suppressWarnings(as.integer(gsub("[,.]", "", n_trials)))

  if (is.na(n_trials) || n_trials == 0L) {
    return(character())
  }

  n_pages <- ceiling(n_trials / 20L)
  trial_ids <- character()

  for (page in seq_len(n_pages)) {
    summary_url <- sprintf(
      "https://www.clinicaltrialsregister.eu/ctr-search/rest/download/summary?%s&page=%i&mode=current_page",
      queryterm,
      page
    )

    summary_lines <- read_url_lines(
      summary_url,
      sprintf("%s summary page %d", start_date, page)
    )
    ids <- regmatches(
      summary_lines,
      gregexpr("[0-9]{4}-[0-9]{6}-[0-9]{2}", summary_lines)
    )
    trial_ids <- c(trial_ids, unlist(ids, use.names = FALSE))
  }

  unique(trial_ids)
}

# ============================================================================
# SAFE LOADER (bulk attempt)
# ============================================================================

try_load <- function(start_date, end_date, label) {

  url <- make_euctr_url(start_date, end_date)

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
  range_label <- sprintf("%s → %s", start_date, end_date)

  message(sprintf("[%s] switching to trial-level fallback", label))

  tryCatch({

    trial_ids <- get_euctr_ids_for_range(start_date, end_date)

    if (!length(trial_ids)) {
      message(sprintf("[%s] no trial identifiers found", label))
      append_log(DONE_LOG, range_label)
      append_log(DONE_LOG, label)
      return(TRUE)
    }

    failures <- character()

    for (trial_id in trial_ids) {
      ok <- tryCatch({
        ctrLoadQueryIntoDb(
          queryterm = trial_id,
          register = "EUCTR",
          euctrresults = FALSE,
          con = db
        )
        message(sprintf("[%s] OK trial %s", label, trial_id))
        TRUE
      }, error = function(e) {
        message(sprintf("[%s] FAIL trial %s: %s", label, trial_id, e$message))
        FALSE
      })

      if (!ok) failures <- c(failures, trial_id)
    }

    if (length(failures)) {
      append_log(
        FAILED_LOG,
        sprintf("%s failed trials: %s", label, paste(failures, collapse = ", "))
      )
    }

    append_log(DONE_LOG, range_label)
    append_log(DONE_LOG, label)
    length(failures) == 0L

  }, error = function(e) {

    message(sprintf("[%s] FAILED permanently: %s", label, e$message))

    append_log(FAILED_LOG, label)
    FALSE
  })
}

# ============================================================================
# RECURSIVE ENGINE (THE CORE)
# ============================================================================

load_range <- function(start_date, end_date, depth = 1, max_depth = 8) {

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

  start <- as.Date(start_date)
  end   <- as.Date(end_date)

  if (depth < max_depth && start < end) {

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

message("\n=== EUCTR ingestion (v16) ===")

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
