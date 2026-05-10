# Interactive substance review queue curation.
#
# Usage:
#   Rscript helper_scripts/substance_norm_pipeline/curate_substances.R
#   Rscript helper_scripts/substance_norm_pipeline/curate_substances.R 100
#   Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --include-skipped
#   Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --export
#
# For each pending row in substance_review_queue.csv, answer:
#   a = accept suggested canonical substance
#   r = reject (not a substance; adds to negative_aliases.csv on --export)
#   o = override with a different canonical substance
#   s = skip (defer; re-shown with --include-skipped)
#   q = quit and save progress
#
# Decisions are written back to substance_review_queue.csv immediately.
# --export writes accepted overrides to manual_substance_overrides.csv and
# rejected rows to negative_aliases.csv.

script_path <- local({
  cmd_args <- commandArgs(FALSE)
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
script_dir  <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)

args           <- commandArgs(trailingOnly = TRUE)
flags          <- args[grepl("^--", args)]
pos_args       <- args[!grepl("^--", args)]
include_skipped <- "--include-skipped" %in% flags
export_mode     <- "--export" %in% flags
max_review      <- if (length(pos_args) >= 1) suppressWarnings(as.integer(pos_args[[1]])) else 50L
if (is.na(max_review) || max_review <= 0L) max_review <- 50L

queue_path     <- project_path("config", "substance_norm_pipeline", "substance_review_queue.csv")
overrides_path <- project_path("config", "substance_norm_pipeline", "manual_substance_overrides.csv")
negatives_path <- project_path("config", "substance_norm_pipeline", "negative_aliases.csv")

# ── helpers ──────────────────────────────────────────────────────────────────

prompt_user <- function(label, default = NULL) {
  suffix <- if (!is.null(default) && nzchar(trimws(as.character(default)))) {
    paste0(" [", default, "]")
  } else ""
  prompt_text <- paste0(label, suffix, ": ")
  ans <- if (interactive()) {
    readline(prompt_text)
  } else {
    cat(prompt_text)
    input <- readLines("stdin", n = 1, warn = FALSE)
    if (length(input)) input[[1]] else ""
  }
  if (!nzchar(trimws(ans)) && !is.null(default)) as.character(default) else trimws(ans)
}

is_decided <- function(x) {
  !is.na(x) & nzchar(trimws(x)) & tolower(trimws(x)) %in% c("accepted", "rejected", "skipped")
}

save_queue <- function(queue, path) {
  write.csv(queue, path, row.names = FALSE, na = "NA")
}

update_row <- function(queue, idx, decision, canonical = NA_character_, comment = NA_character_) {
  queue$decision[idx]           <- decision
  queue$canonical_substance[idx] <- canonical
  queue$comment[idx]             <- comment
  queue
}

# ── export mode ──────────────────────────────────────────────────────────────

if (export_mode) {
  if (!file.exists(queue_path)) stop("Queue not found: ", queue_path)

  queue <- read.csv(queue_path, stringsAsFactors = FALSE, check.names = FALSE)
  queue$decision           <- as.character(queue$decision)
  queue$canonical_substance <- as.character(queue$canonical_substance)
  queue$comment             <- as.character(queue$comment)

  # --- export accepted overrides → manual_substance_overrides.csv
  accepted <- queue[
    tolower(trimws(queue$decision)) %in% "accepted" &
    !is.na(queue$canonical_substance) &
    nzchar(trimws(queue$canonical_substance)),
  ]

  n_override_added <- 0L
  if (nrow(accepted) && file.exists(overrides_path)) {
    overrides <- read.csv(overrides_path, stringsAsFactors = FALSE, check.names = FALSE)
    new_rows <- data.frame(
      raw_clean       = tolower(trimws(accepted$raw_substance)),
      substance_clean = tolower(trimws(accepted$canonical_substance)),
      match_status    = "accepted",
      reason          = ifelse(
        !is.na(accepted$comment) & nzchar(trimws(accepted$comment)),
        accepted$comment,
        "accepted during manual curation"
      ),
      stringsAsFactors = FALSE
    )
    key_existing <- paste(overrides$raw_clean, overrides$substance_clean, sep = "\r")
    key_new      <- paste(new_rows$raw_clean,  new_rows$substance_clean,  sep = "\r")
    new_rows     <- new_rows[!key_new %in% key_existing, , drop = FALSE]
    n_override_added <- nrow(new_rows)
    if (n_override_added > 0L) {
      combined <- rbind(overrides, new_rows)
      write.csv(combined, overrides_path, row.names = FALSE, na = "")
    }
  }

  # --- export rejected rows → negative_aliases.csv
  rejected <- queue[tolower(trimws(queue$decision)) %in% "rejected", ]

  n_negative_added <- 0L
  if (nrow(rejected) && file.exists(negatives_path)) {
    negatives <- read.csv(negatives_path, stringsAsFactors = FALSE, check.names = FALSE)
    new_neg <- data.frame(
      alias_clean = tolower(trimws(rejected$raw_substance)),
      reason      = ifelse(
        !is.na(rejected$comment) & nzchar(trimws(rejected$comment)),
        rejected$comment,
        "rejected during manual curation"
      ),
      stringsAsFactors = FALSE
    )
    existing_aliases <- tolower(trimws(negatives$alias_clean))
    new_neg          <- new_neg[!new_neg$alias_clean %in% existing_aliases, , drop = FALSE]
    n_negative_added <- nrow(new_neg)
    if (n_negative_added > 0L) {
      combined <- rbind(negatives, new_neg)
      write.csv(combined, negatives_path, row.names = FALSE, na = "")
    }
  }

  message("Export complete.")
  message("  Accepted overrides added to manual_substance_overrides.csv: ", n_override_added)
  message("  Rejected aliases added to negative_aliases.csv:             ", n_negative_added)
  message("")
  message("Re-run normalise_substances.R to apply decisions to the queue.")
  quit(save = "no", status = 0L)
}

# ── interactive review ────────────────────────────────────────────────────────

if (!file.exists(queue_path)) {
  stop("Queue not found: ", queue_path,
       "\nRun normalise_substances.R --write-queue to generate it.")
}

queue <- read.csv(queue_path, stringsAsFactors = FALSE, check.names = FALSE)
required_cols <- c(
  "raw_substance", "active_substance_clean", "match_status",
  "match_score", "match_source", "match_reason", "n_occurrences",
  "decision", "canonical_substance", "comment"
)
missing_cols <- setdiff(required_cols, names(queue))
if (length(missing_cols)) {
  stop("Queue is missing columns: ", paste(missing_cols, collapse = ", "))
}

queue$decision            <- as.character(queue$decision)
queue$canonical_substance <- as.character(queue$canonical_substance)
queue$comment             <- as.character(queue$comment)
queue$n_occurrences       <- suppressWarnings(as.numeric(queue$n_occurrences))
queue$match_score         <- suppressWarnings(as.numeric(queue$match_score))

n_total   <- nrow(queue)
n_decided <- sum(is_decided(queue$decision))

pending_idx <- which(!is_decided(queue$decision))
if (!include_skipped) {
  skipped_idx <- which(tolower(trimws(queue$decision)) == "skipped")
  pending_idx <- setdiff(pending_idx, skipped_idx)
  n_skipped   <- length(skipped_idx)
} else {
  n_skipped <- 0L
}

pending_idx <- pending_idx[order(-queue$n_occurrences[pending_idx])]
n_remaining <- length(pending_idx)
show_idx    <- head(pending_idx, max_review)

cat("\nSubstance review queue curation\n")
cat("Queue file: ", queue_path, "\n", sep = "")
cat(sprintf("  Total rows:       %d\n", n_total))
cat(sprintf("  Already decided:  %d\n", n_decided))
if (!include_skipped && n_skipped > 0L) {
  cat(sprintf("  Skipped (hidden): %d  (use --include-skipped to show)\n", n_skipped))
}
cat(sprintf("  Remaining:        %d\n", n_remaining))
cat(sprintf("  Showing up to:    %d  (sorted by n_occurrences desc)\n\n", length(show_idx)))

if (!length(show_idx)) {
  message("Nothing left to review. Use --include-skipped to re-show skipped rows.")
  quit(save = "no", status = 0L)
}

n_accepted  <- 0L
n_rejected  <- 0L
n_overridden <- 0L

for (j in seq_along(show_idx)) {
  idx <- show_idx[j]
  row <- queue[idx, ]

  cat("\n", strrep("=", 74), "\n", sep = "")
  cat(sprintf("Row %d / %d  |  n_occurrences: %s\n",
              j, length(show_idx),
              ifelse(is.na(row$n_occurrences), "?", row$n_occurrences)))
  cat(sprintf("Raw substance:    %s\n", row$raw_substance))
  cat(sprintf("Suggested clean:  %s\n", ifelse(is.na(row$active_substance_clean), "(none)", row$active_substance_clean)))
  cat(sprintf("Match status:     %s\n", row$match_status))
  cat(sprintf("Match score:      %s\n", ifelse(is.na(row$match_score), "?", row$match_score)))
  cat(sprintf("Match source:     %s\n", ifelse(is.na(row$match_source), "(none)", row$match_source)))
  cat(sprintf("Match reason:     %s\n", ifelse(is.na(row$match_reason), "(none)", row$match_reason)))
  cat(strrep("-", 74), "\n", sep = "")
  cat("a = accept suggested   r = reject   o = override   s = skip   q = quit\n")

  ans <- tolower(trimws(prompt_user("Decision", "s")))

  if (ans %in% c("q", "quit")) {
    save_queue(queue, queue_path)
    break
  }

  if (ans %in% c("s", "skip", "")) {
    queue <- update_row(queue, idx, "skipped")
    save_queue(queue, queue_path)
    cat("Skipped.\n")
    next
  }

  if (ans %in% c("a", "accept")) {
    canonical <- ifelse(is.na(row$active_substance_clean), "", row$active_substance_clean)
    comment   <- prompt_user("Comment (optional)", "")
    queue     <- update_row(queue, idx, "accepted", canonical, comment)
    save_queue(queue, queue_path)
    n_accepted <- n_accepted + 1L
    cat("Accepted: ", canonical, "\n", sep = "")
    next
  }

  if (ans %in% c("r", "reject")) {
    reason <- prompt_user("Reason for rejection", "not a substance")
    queue  <- update_row(queue, idx, "rejected", NA_character_, reason)
    save_queue(queue, queue_path)
    n_rejected <- n_rejected + 1L
    cat("Rejected.\n")
    next
  }

  if (ans %in% c("o", "override")) {
    canonical <- prompt_user("Correct canonical substance")
    if (!nzchar(canonical)) {
      cat("No canonical entered; skipped.\n")
      next
    }
    comment <- prompt_user("Comment (optional)", paste0("override: was '", row$active_substance_clean, "'"))
    queue   <- update_row(queue, idx, "accepted", canonical, comment)
    save_queue(queue, queue_path)
    n_overridden <- n_overridden + 1L
    cat("Override accepted: ", canonical, "\n", sep = "")
    next
  }

  cat("Unrecognised answer; skipped.\n")
}

cat("\n", strrep("=", 74), "\n", sep = "")
cat(sprintf("Session complete.\n"))
cat(sprintf("  Accepted (suggested): %d\n", n_accepted))
cat(sprintf("  Accepted (override):  %d\n", n_overridden))
cat(sprintf("  Rejected:             %d\n", n_rejected))
cat(sprintf("\nDecisions saved to %s\n", queue_path))
cat("Run with --export to write decisions to config files.\n")
