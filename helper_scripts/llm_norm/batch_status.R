#!/usr/bin/env Rscript
# Check batch status directly. Minimal machinery: no block table, no work list,
# no content construction — just auth and one HTTP call, so it isolates whether
# the problem is credentials, the network, or the batch itself.
#
# Usage
#   Rscript helper_scripts/llm_norm/batch_status.R              # list recent batches
#   Rscript helper_scripts/llm_norm/batch_status.R msgbatch_01H8...   # one batch

suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(tibble); library(purrr); library(dplyr)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

cat("1. resolving credentials\n")
key <- Sys.getenv("ANTHROPIC_API_KEY", "")
if (nzchar(key)) {
  cat("   ANTHROPIC_API_KEY is set (", nchar(key), " chars)\n", sep = "")
  headers <- c("x-api-key" = key); betas <- character()
} else {
  cat("   ANTHROPIC_API_KEY is NOT set — falling back to the `ant` CLI.\n")
  cat("   If this script hangs here, that shell-out is your hang: run\n")
  cat("     ant auth print-credentials --access-token\n")
  cat("   by hand and see whether it returns, prompts, or stalls.\n")
  t0 <- Sys.time()
  tok <- tryCatch(
    suppressWarnings(system2("ant", c("auth", "print-credentials", "--access-token"),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) character()
  )
  tok <- tok[nzchar(tok)]
  cat(sprintf("   ant returned in %.1fs\n", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  if (!length(tok)) stop("No credentials. Set ANTHROPIC_API_KEY or run `ant auth login`.",
                         call. = FALSE)
  headers <- c("Authorization" = paste("Bearer", tok[[1L]]))
  betas <- "oauth-2025-04-20"
}

req <- function(path) {
  r <- httr2::request(paste0("https://api.anthropic.com", path)) |>
    httr2::req_headers(!!!c(headers, "anthropic-version" = "2023-06-01",
                            "content-type" = "application/json")) |>
    httr2::req_timeout(30) |>
    httr2::req_error(is_error = function(x) FALSE)
  if (length(betas)) r <- httr2::req_headers(r, "anthropic-beta" = paste(betas, collapse = ","))
  r
}

args <- commandArgs(trailingOnly = TRUE)
do_cancel <- "--cancel" %in% args
args <- args[args != "--cancel"]
batch_id <- if (length(args)) args[[1L]] else NA_character_

# Cancelling stops requests that have not yet started. Anything already
# completed is still billed and its results remain fetchable for 29 days, so a
# cancel never destroys work you have paid for.
if (do_cancel) {
  if (is.na(batch_id)) stop("--cancel needs a batch id.", call. = FALSE)
  cat("2. cancelling ", batch_id, "\n", sep = "")
  resp <- httr2::req_perform(
    httr2::req_body_raw(
      httr2::req_method(req(paste0("/v1/messages/batches/", batch_id, "/cancel")), "POST"),
      "", "application/json"))
  cat(sprintf("   HTTP %d\n", httr2::resp_status(resp)))
  if (httr2::resp_status(resp) >= 400L) {
    cat("   ", substr(httr2::resp_body_string(resp), 1L, 500L), "\n", sep = "")
    quit(status = 1L)
  }
  b <- httr2::resp_body_json(resp)
  rc <- b$request_counts
  cat("   status now: ", b$processing_status, "\n", sep = "")
  cat(sprintf("   succeeded=%s (billed, still fetchable) canceled=%s processing=%s\n",
              rc$succeeded %||% 0, rc$canceled %||% 0, rc$processing %||% 0))
  cat("\nCancellation is not instant — poll this script again to see it settle.\n")
  quit(status = 0L)
}

cat("2. calling the API\n")
t0 <- Sys.time()
path <- if (is.na(batch_id)) "/v1/messages/batches?limit=20" else
  paste0("/v1/messages/batches/", batch_id)
resp <- tryCatch(httr2::req_perform(req(path)), error = function(e) e)
if (inherits(resp, "condition")) {
  cat("   NETWORK FAILURE: ", conditionMessage(resp), "\n", sep = "")
  cat("   The batch is unaffected — it runs server-side.\n")
  quit(status = 1L)
}
cat(sprintf("   HTTP %d in %.1fs\n", httr2::resp_status(resp),
            as.numeric(difftime(Sys.time(), t0, units = "secs"))))
if (httr2::resp_status(resp) >= 400L) {
  cat("   ", substr(httr2::resp_body_string(resp), 1L, 500L), "\n", sep = "")
  quit(status = 1L)
}

b <- httr2::resp_body_json(resp)

fmt <- function(x) {
  rc <- x$request_counts
  sprintf("%-34s %-12s ok=%-6s err=%-5s proc=%-6s expired=%-5s canceled=%s",
          x$id, x$processing_status,
          rc$succeeded %||% 0, rc$errored %||% 0, rc$processing %||% 0,
          rc$expired %||% 0, rc$canceled %||% 0)
}

if (is.na(batch_id)) {
  cat("\nrecent batches (newest first):\n")
  for (x in b$data) cat("  ", fmt(x), "\n", sep = "")
  cat("\nResume one with:  --poll=<batch_id>\n")
} else {
  cat("\n", fmt(b), "\n\n", sep = "")
  cat("created_at        : ", b$created_at %||% "?", "\n", sep = "")
  cat("ended_at          : ", b$ended_at %||% "(still running)", "\n", sep = "")
  cat("expires_at        : ", b$expires_at %||% "?", "\n", sep = "")
  cat("results_url       : ", if (is.null(b$results_url)) "(not ready)" else "ready", "\n", sep = "")
  if (identical(b$processing_status, "ended")) {
    cat("\nThis batch is DONE. Fetch it with --poll=", b$id, "\n", sep = "")
  } else {
    cat("\nStill processing. Batches usually finish within an hour, max 24.\n")
    cat("Credits move only as requests complete, so a flat balance while\n")
    cat("processing>0 is expected, not a sign of failure.\n")
  }
}
