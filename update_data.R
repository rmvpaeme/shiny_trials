# ============================================================================
# update_data.R  (v18 — CTIS default, explicit EUCTR/results refresh)
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

args <- commandArgs(trailingOnly = TRUE)
truthy <- function(x) tolower(x) %in% c("1", "true", "t", "yes", "y", "on")

REFRESH_EUCTR_RESULTS <- any(args %in% c("--euctr-results", "--results", "--all")) ||
  truthy(Sys.getenv("REFRESH_EUCTR_RESULTS", "false")) ||
  truthy(Sys.getenv("FORCE_RESULTS", "false"))

REFRESH_EUCTR <- any(args %in% c("--euctr", "--refresh-euctr", "--all")) ||
  truthy(Sys.getenv("REFRESH_EUCTR", "false")) ||
  REFRESH_EUCTR_RESULTS

REFRESH_CTIS <- !any(args %in% c("--euctr-only", "--only-euctr")) &&
  !truthy(Sys.getenv("SKIP_CTIS", "false"))

db <- nodbi::src_sqlite(dbname = DB_PATH, collection = DB_COLLECTION)

# ============================================================================
# LOG HELPERS
# ============================================================================

ts <- function() format(Sys.time(), "[%Y-%m-%d %H:%M:%S]")

log_msg <- function(...) message(ts(), " ", ...)

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

    log_msg(sprintf(
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
      euctrresults = REFRESH_EUCTR_RESULTS,
      euctrresultshistory = REFRESH_EUCTR_RESULTS,
      con = db
    )

    log_msg(sprintf("[%s] OK", label))
    TRUE

  }, error = function(e) {

    log_msg(sprintf("[%s] FAIL: %s", label, e$message))
    FALSE
  })
}

# ============================================================================
# LAYER 3 — TRIAL-LEVEL FALLBACK
# ============================================================================

load_trial_fallback <- function(start_date, end_date) {

  label <- sprintf("TRIAL %s → %s", start_date, end_date)
  range_label <- sprintf("%s → %s", start_date, end_date)

  log_msg(sprintf("[%s] switching to trial-level fallback", label))

  tryCatch({

    trial_ids <- get_euctr_ids_for_range(start_date, end_date)

    if (!length(trial_ids)) {
      log_msg(sprintf("[%s] no trial identifiers found", label))
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
          euctrresults = REFRESH_EUCTR_RESULTS,
          euctrresultshistory = REFRESH_EUCTR_RESULTS,
          con = db
        )
        log_msg(sprintf("[%s] OK trial %s", label, trial_id))
        TRUE
      }, error = function(e) {
        log_msg(sprintf("[%s] FAIL trial %s: %s", label, trial_id, e$message))
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

    log_msg(sprintf("[%s] FAILED permanently: %s", label, e$message))

    append_log(FAILED_LOG, label)
    FALSE
  })
}

# ============================================================================
# RETRY FAILED TRIALS
# ============================================================================

retry_failed_trials <- function() {

  lines <- read_log(FAILED_LOG)
  if (!length(lines)) {
    log_msg("[retry] nothing to retry")
    return(invisible(NULL))
  }

  still_failing <- character()

  # Lines with specific trial IDs: "TRIAL <start> → <end> failed trials: <id1>, <id2>"
  trial_lines <- grep("failed trials:", lines, value = TRUE)
  for (line in trial_lines) {
    ids <- trimws(strsplit(sub(".*failed trials: ", "", line), ",")[[1]])
    for (trial_id in ids) {
      ok <- tryCatch({
        ctrLoadQueryIntoDb(
          queryterm   = trial_id,
          register    = "EUCTR",
          euctrresults        = REFRESH_EUCTR_RESULTS,
          euctrresultshistory = REFRESH_EUCTR_RESULTS,
          con = db
        )
        log_msg(sprintf("[retry] OK: %s", trial_id))
        TRUE
      }, error = function(e) {
        log_msg(sprintf("[retry] FAIL: %s — %s", trial_id, e$message))
        FALSE
      })
      if (!ok) still_failing <- c(still_failing, sprintf("failed trials: %s", trial_id))
    }
  }

  # Lines where the whole range failed (no trial IDs): "TRIAL <start> → <end>"
  range_lines <- grep("^TRIAL .* → .*$", lines, value = TRUE)
  range_lines  <- range_lines[!grepl("failed trials:", range_lines)]
  for (line in range_lines) {
    dates <- regmatches(line, gregexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", line))[[1]]
    if (length(dates) < 2L) { still_failing <- c(still_failing, line); next }
    ok <- load_trial_fallback(dates[1], dates[2])
    if (!ok) still_failing <- c(still_failing, line)
  }

  if (!length(still_failing)) {
    log_msg("[retry] all retries succeeded — clearing failed_chunks.txt")
    file.remove(FAILED_LOG)
  } else {
    log_msg(sprintf("[retry] %d entry/entries still failing", length(still_failing)))
    writeLines(still_failing, FAILED_LOG)
  }
}

# ============================================================================
# RECURSIVE ENGINE (THE CORE)
# ============================================================================

load_range <- function(start_date, end_date, depth = 1, max_depth = 8) {

  label <- sprintf("%s → %s", start_date, end_date)

  done <- read_log(DONE_LOG)
  if (label %in% done) {
    log_msg(sprintf("[%s] skipped (done)", label))
    return(TRUE)
  }

  log_msg(sprintf("[%s] depth=%d start", label, depth))

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

    log_msg(sprintf("[%s] splitting range", label))

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

if (REFRESH_EUCTR) {
  log_msg("\n=== EUCTR ingestion (v18) ===")
  if (REFRESH_EUCTR_RESULTS) {
    log_msg("EUCTR result documents enabled (slow).")
  }

  current_year <- as.integer(format(Sys.Date(), "%Y"))

  for (yr in 2004:current_year) {

    log_msg(sprintf("=== YEAR %d ===", yr))
    
    quarters <- make_quarters(yr)
    
    for (q in quarters) {
      
      load_range(q[1], q[2])
    }
  }
  
  log_msg("EUCTR ingestion complete.")
  retry_failed_trials()
} else {
  log_msg("=== EUCTR skipped ===")
  log_msg("Use REFRESH_EUCTR=true Rscript update_data.R or Rscript update_data.R --euctr to refresh EUCTR.")
  if (file.exists(FAILED_LOG)) retry_failed_trials()
}

# ============================================================================
# CTIS
# ============================================================================

if (REFRESH_CTIS) {
  log_msg("=== CTIS ===")
  
  ctis_url <- "https://euclinicaltrials.eu/ctis-public/search#searchCriteria={}"
  
  tryCatch({

    ctrLoadQueryIntoDb(
      queryterm = ctis_url,
      register = "CTIS",
      con = db
    )
    
    log_msg("CTIS done.")

  }, error = function(e) {

    log_msg("CTIS failed: ", e$message)
  })
} else {
  log_msg("=== CTIS skipped ===")
}

# ============================================================================
# DONE
# ============================================================================

log_msg("Finished.")
