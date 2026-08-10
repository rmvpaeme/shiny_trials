# Mine token-level transformations from the frozen (raw, final) decision pairs.
#
# This is the evidence behind the rule set in
# helper_scripts/*_norm_pipeline/derive_*_canonical.R and behind the mined
# additions to .legal_suffixes_rx. It reads only committed config, so its output
# is reproducible from a clean checkout with no database and no network.
#
# Usage:
#   Rscript tests/derivation/mine_removals.R
#   Rscript tests/derivation/mine_removals.R --top=40
#
# Writes nothing; prints a report. See replay.R for the acceptance harness.

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(purrr)
})

script_path <- local({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  NA_character_
})
project_root <- if (!is.na(script_path)) {
  normalizePath(file.path(dirname(script_path), "..", ".."), mustWork = TRUE)
} else {
  getwd()
}
project_path <- function(...) file.path(project_root, ...)

source(project_path("tests", "derivation", "corpus.R"), local = FALSE)

args   <- commandArgs(trailingOnly = TRUE)
top_n  <- local({
  v <- args[startsWith(args, "--top=")]
  if (length(v) == 0L) 25L else as.integer(sub("^--top=", "", v[[1]]))
})

# ── transformation classifier ─────────────────────────────────────────────────
#
# classify_pair() and is_subsequence() live in corpus.R, so the miner and the
# replay harness partition the corpus the same way.

removed_tokens <- function(raw_tokens, final_tokens) {
  # The tokens of `raw` not consumed while matching `final` into it.
  keep <- logical(length(raw_tokens))
  i <- 1L
  for (j in seq_along(raw_tokens)) {
    if (i <= length(final_tokens) && identical(raw_tokens[[j]], final_tokens[[i]])) {
      keep[[j]] <- TRUE
      i <- i + 1L
    }
  }
  raw_tokens[!keep]
}

trailing_removal <- function(raw_tokens, final_tokens) {
  # The removed span, when it sits entirely at the end of the raw string.
  n <- length(final_tokens)
  if (n >= length(raw_tokens)) return(NA_character_)
  if (!identical(raw_tokens[seq_len(n)], final_tokens)) return(NA_character_)
  paste(raw_tokens[(n + 1L):length(raw_tokens)], collapse = " ")
}

# ── report ────────────────────────────────────────────────────────────────────

report_side <- function(pairs, label) {
  cat(sprintf("\n=== %s — %d pairs ===\n\n", label, nrow(pairs)))

  tokens_of <- function(x) str_split(x, "\\s+")

  raw_toks   <- tokens_of(pairs$raw_clean)
  final_toks <- tokens_of(pairs$final_clean)

  kind <- classify_pairs(pairs)

  summary_tbl <- tibble(kind = kind) |>
    count(kind, name = "rows") |>
    mutate(share = sprintf("%.1f%%", 100 * rows / sum(rows))) |>
    arrange(desc(rows))
  print(as.data.frame(summary_tbl), row.names = FALSE)

  removal_idx <- which(kind == "removal")
  if (length(removal_idx) == 0L) return(invisible(NULL))

  tails <- map2_chr(
    raw_toks[removal_idx], final_toks[removal_idx], trailing_removal
  )
  tails <- tails[!is.na(tails)]

  cat(sprintf(
    "\nTrailing removals: %d of %d removal rows (%.1f%%). Top %d spans:\n",
    length(tails), length(removal_idx),
    100 * length(tails) / length(removal_idx), top_n
  ))
  top <- tibble(span = tails) |>
    count(span, sort = TRUE, name = "rows") |>
    head(top_n) |>
    mutate(cum_share = sprintf(
      "%.1f%%", 100 * cumsum(rows) / length(tails)
    ))
  print(as.data.frame(top), row.names = FALSE)

  scattered <- map2(raw_toks[removal_idx], final_toks[removal_idx], removed_tokens)
  cat(sprintf("\nTop %d removed tokens (any position):\n", top_n))
  top_tok <- tibble(token = unlist(scattered, use.names = FALSE)) |>
    count(token, sort = TRUE, name = "rows") |>
    head(top_n)
  print(as.data.frame(top_tok), row.names = FALSE)

  invisible(NULL)
}

sponsor_pairs   <- load_sponsor_corpus(project_root)
substance_pairs <- load_substance_corpus(project_root)

cat("Mined from committed config only — no database, no network.\n")
report_side(sponsor_pairs, "Sponsors")
report_side(substance_pairs, "Substances")
cat("\n")
