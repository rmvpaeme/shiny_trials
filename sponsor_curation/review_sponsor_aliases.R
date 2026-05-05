# Interactive sponsor alias review.
#
# Usage:
#   Rscript sponsor_curation/review_sponsor_aliases.R
#   Rscript sponsor_curation/review_sponsor_aliases.R 50
#
# For each high-volume candidate, answer:
#   y = approve suggested mapping
#   n = skip
#   e = edit canonical/pattern/match type before approving
#   q = quit and save approvals so far
#
# Approved mappings are appended to config/sponsor_aliases.csv. Reviewed
# approve/skip decisions are also logged to config/sponsor_review_decisions.csv
# so the next session resumes after already-reviewed candidates.

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
script_dir <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)
audit_script <- file.path(script_dir, "audit_sponsors.R")
rscript_bin <- function() {
  bin <- file.path(R.home("bin"), "Rscript")
  if (file.exists(bin)) bin else "Rscript"
}

args <- commandArgs(trailingOnly = TRUE)
flags <- args[grepl("^--", args)]
pos_args <- args[!grepl("^--", args)]
include_reviewed <- "--include-reviewed" %in% flags
max_review <- if (length(pos_args) >= 1) suppressWarnings(as.integer(pos_args[[1]])) else 50L
if (is.na(max_review) || max_review <= 0L) max_review <- 50L

candidate_path <- project_path("data", "sponsor_alias_candidates.csv")
alias_path <- project_path("config", "sponsor_aliases.csv")
decision_path <- project_path("config", "sponsor_review_decisions.csv")

truthy <- function(x) {
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

append_aliases <- function(new_aliases, alias_path) {
  if (!nrow(new_aliases)) return(invisible(0L))
  aliases <- read.csv(alias_path, stringsAsFactors = FALSE, check.names = FALSE)
  required <- c("priority", "pattern", "canonical", "match_type", "approved", "notes")
  aliases <- aliases[, required]
  next_priority <- suppressWarnings(max(as.integer(aliases$priority), na.rm = TRUE))
  if (!is.finite(next_priority)) next_priority <- 0L
  new_aliases$priority <- seq(next_priority + 10L, by = 10L, length.out = nrow(new_aliases))
  new_aliases <- new_aliases[, required]
  combined <- rbind(aliases, new_aliases)
  key <- paste(
    tolower(trimws(combined$pattern)),
    tolower(trimws(combined$canonical)),
    tolower(trimws(combined$match_type)),
    sep = "\r"
  )
  old_n <- nrow(combined)
  combined <- combined[!duplicated(key), , drop = FALSE]
  combined$priority <- seq(10L, by = 10L, length.out = nrow(combined))
  write.csv(combined, alias_path, row.names = FALSE, na = "")
  old_n - nrow(combined)
}

candidate_key <- function(df) {
  paste(
    tolower(trimws(df$canonical_suggestion)),
    tolower(trimws(df$suggested_pattern)),
    tolower(trimws(df$sponsor_a)),
    tolower(trimws(df$sponsor_b)),
    sep = " ||| "
  )
}

empty_decisions <- function() {
  data.frame(
    decision_key = character(),
    decision = character(),
    canonical_suggestion = character(),
    suggested_pattern = character(),
    sponsor_a = character(),
    sponsor_b = character(),
    total_n = numeric(),
    similarity_score = numeric(),
    decided_at = character(),
    notes = character(),
    stringsAsFactors = FALSE
  )
}

load_decisions <- function(path) {
  if (!file.exists(path)) {
    return(empty_decisions())
  }
  decisions <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  required <- names(empty_decisions())
  missing <- setdiff(required, names(decisions))
  for (col in missing) decisions[[col]] <- NA
  decisions$decision_key <- candidate_key(decisions)
  decisions[, required, drop = FALSE]
}

append_decision <- function(row, decision, notes = "") {
  dir.create(dirname(decision_path), recursive = TRUE, showWarnings = FALSE)
  decision_row <- data.frame(
    decision_key = candidate_key(row),
    decision = decision,
    canonical_suggestion = row$canonical_suggestion,
    suggested_pattern = row$suggested_pattern,
    sponsor_a = row$sponsor_a,
    sponsor_b = row$sponsor_b,
    total_n = suppressWarnings(as.numeric(row$total_n)),
    similarity_score = suppressWarnings(as.numeric(row$similarity_score)),
    decided_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"),
    notes = notes,
    stringsAsFactors = FALSE
  )
  decisions <- load_decisions(decision_path)
  decisions <- decisions[decisions$decision_key != decision_row$decision_key, , drop = FALSE]
  decisions <- rbind(decisions, decision_row)
  write.csv(decisions, decision_path, row.names = FALSE, na = "")
  invisible(TRUE)
}

prompt <- function(label, default = NULL) {
  suffix <- if (!is.null(default) && nzchar(default)) paste0(" [", default, "]") else ""
  prompt_text <- paste0(label, suffix, ": ")
  ans <- if (interactive()) {
    readline(prompt_text)
  } else {
    cat(prompt_text)
    input <- readLines("stdin", n = 1, warn = FALSE)
    if (length(input)) input[[1]] else ""
  }
  if (!nzchar(trimws(ans)) && !is.null(default)) default else trimws(ans)
}

if (!file.exists(candidate_path)) {
  stop("Candidate file not found: ", candidate_path,
       ". Run Rscript sponsor_curation/audit_sponsors.R first.")
}
if (!file.exists(alias_path)) {
  stop("Alias table not found: ", alias_path)
}

candidates <- read.csv(candidate_path, stringsAsFactors = FALSE, check.names = FALSE)
required <- c(
  "canonical_suggestion", "sponsor_a", "sponsor_b", "n_a", "n_b", "total_n",
  "similarity_score", "token_overlap", "informative_common",
  "suggested_pattern", "suggested_match_type", "approved"
)
missing <- setdiff(required, names(candidates))
if (length(missing)) {
  stop("Candidate file missing required columns: ", paste(missing, collapse = ", "))
}

candidates <- candidates[!truthy(candidates$approved), , drop = FALSE]
candidates$total_n <- suppressWarnings(as.numeric(candidates$total_n))
candidates$similarity_score <- suppressWarnings(as.numeric(candidates$similarity_score))
candidates$token_overlap <- suppressWarnings(as.numeric(candidates$token_overlap))

decisions <- load_decisions(decision_path)
if (!include_reviewed && nrow(decisions)) {
  reviewed_keys <- decisions$decision_key[decisions$decision %in% c("approved", "skipped")]
  n_before_review_filter <- nrow(candidates)
  candidates <- candidates[!candidate_key(candidates) %in% reviewed_keys, , drop = FALSE]
  n_reviewed_filtered <- n_before_review_filter - nrow(candidates)
} else {
  n_reviewed_filtered <- 0L
}

candidates <- candidates[order(-candidates$total_n, -candidates$similarity_score), , drop = FALSE]
n_remaining_total <- nrow(candidates)
candidates <- head(candidates, max_review)

cat("\nInteractive sponsor alias review\n")
cat("Approvals will be appended to ", alias_path, "\n", sep = "")
cat("Review decisions will be saved to ", decision_path, "\n", sep = "")
if (!include_reviewed && n_reviewed_filtered > 0L) {
  cat("Previously reviewed candidates skipped: ", n_reviewed_filtered, "\n", sep = "")
}
if (include_reviewed) {
  cat("Previously reviewed candidates are included because --include-reviewed was set.\n")
}
cat("Total candidates remaining to review: ", n_remaining_total, "\n", sep = "")
if (!nrow(candidates)) {
  message("No unreviewed candidates to review.")
  approved_count <- 0L
  duplicate_count <- 0L
} else {
  approved_count <- 0L
  duplicate_count <- 0L

  cat("Reviewing up to ", nrow(candidates), " candidate(s).\n\n", sep = "")

  for (i in seq_len(nrow(candidates))) {
    row <- candidates[i, ]
    cat("\n", strrep("=", 78), "\n", sep = "")
    cat("Candidate ", i, " / ", nrow(candidates), "\n", sep = "")
    cat("Canonical suggestion: ", row$canonical_suggestion, "\n", sep = "")
    cat("Map pattern/name:      ", row$suggested_pattern, "\n", sep = "")
    cat("Sponsor A:            ", row$sponsor_a, " (n=", row$n_a, ")\n", sep = "")
    cat("Sponsor B:            ", row$sponsor_b, " (n=", row$n_b, ")\n", sep = "")
    cat("Combined trials:      ", row$total_n, "\n", sep = "")
    cat("Similarity:           ", row$similarity_score,
        " | token overlap: ", row$token_overlap, "\n", sep = "")
    cat("Shared tokens:        ", row$informative_common, "\n", sep = "")
    cat("\n")

    ans <- tolower(prompt("Approve? y/n/e/q", "n"))
    if (ans %in% c("q", "quit")) break
    if (ans %in% c("n", "no", "s", "skip", "")) {
      append_decision(row, "skipped", "Skipped interactively")
      cat("Skipped and saved.\n")
      next
    }

    canonical <- row$canonical_suggestion
    pattern <- row$suggested_pattern
    match_type <- row$suggested_match_type
    notes <- if ("notes" %in% names(row) && nzchar(trimws(row$notes))) {
      row$notes
    } else {
      paste0("Approved interactively from ", candidate_path)
    }

    if (ans %in% c("e", "edit")) {
      canonical <- prompt("Canonical", canonical)
      pattern <- prompt("Pattern/name", pattern)
      match_type <- prompt("Match type: exact or regex", match_type)
      notes <- prompt("Notes", notes)
    } else if (!ans %in% c("y", "yes")) {
      cat("Unrecognised answer; skipped.\n")
      next
    }

    if (!nzchar(canonical) || !nzchar(pattern)) {
      cat("Canonical and pattern are required; skipped.\n")
      next
    }
    if (!tolower(match_type) %in% c("exact", "regex")) {
      cat("Match type must be exact or regex; skipped.\n")
      next
    }

    alias_row <- data.frame(
      priority = NA_integer_,
      pattern = pattern,
      canonical = canonical,
      match_type = tolower(match_type),
      approved = TRUE,
      notes = notes,
      stringsAsFactors = FALSE
    )
    duplicate_count <- duplicate_count + append_aliases(alias_row, alias_path)
    append_decision(row, "approved", notes)
    approved_count <- approved_count + 1L
    cat("Approved and saved.\n")
  }
}

if (approved_count) {
  message("Approved aliases appended: ", approved_count - duplicate_count)
  message("Skipped as duplicates: ", duplicate_count)
}

if (approved_count && file.exists(audit_script)) {
  message("Regenerating candidate queue...")
  status <- system2(
    rscript_bin(),
    c(audit_script, project_path("data", "sponsor_normalisation_log.csv"), candidate_path, alias_path)
  )
  if (!identical(status, 0L)) {
    warning("audit_sponsors.R exited with status ", status)
  }
}
