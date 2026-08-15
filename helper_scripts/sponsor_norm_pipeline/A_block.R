#!/usr/bin/env Rscript
# Pass A — group the distinct raw sponsor strings into blocks.
#
# MAKES NO DECISIONS. It emits candidate groups; pass B decides what is one
# organisation. Everything here is deterministic and offline, so it can be run
# and re-run freely while the thresholds are tuned.
#
# Why blocking exists at all, given the model does the labelling: pass B's whole
# premise is that a cluster gets named ONCE, with every variant visible in the
# same request. That is what stops "UZ Gent", "Ghent University Hospital" and
# "Universitair Ziekenhuis Gent" becoming three canonicals. You cannot get it by
# handing a model 16,594 strings and asking for a clustering — the response
# would be 16k assignments, far past max_tokens, and unverifiable. So something
# has to group candidate-same strings first, and that is this.
#
# Usage
#   Rscript helper_scripts/sponsor_norm_pipeline/A_block.R
#   Rscript .../A_block.R --extra-channels     # add n-gram + acronym, and report
#                                              # what they contribute uniquely
#   Rscript .../A_block.R --max-block=40
#
# Outputs
#   data/sponsor_blocks.csv   raw_sponsor, block_id, n_trials, block_size

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
  library(purrr)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "retrieve.R"), local = FALSE)

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
extra_channels <- "--extra-channels" %in% args
MAX_BLOCK      <- as.integer(arg_value("--max-block", "40"))
# Pair score is shared IDF mass over the smaller string's total mass, so 0.5
# means "half of what the shorter string is about is also in the longer one".
#
# Tune it from this script's own output, not from a benchmark: the run prints
# the score distribution, the block-size distribution, and the three largest
# blocks in full. Too low shows up as blocks mixing organisations that are
# obviously distinct; too high shows up as a rising singleton count and, one
# pass later, as a rising abstention rate in C_assign.
#
# Do NOT lower it globally to rescue singletons. At 0.48-0.49 true and false
# positives are interleaved — "Polski Bank Komorek Macierzy" / "Polski Bank
# Komrek Macierzystych" is one organisation, "Centre Ren Huguenin" / "Centre
# Ren Gauducheau" are two different cancer centres. The rescue path is the
# round-2 re-block of C_assign's abstainers (--only, lower threshold), where a
# registry already exists and the model decides rather than the threshold.
THRESHOLD      <- as.numeric(arg_value("--threshold", "0.5"))

RAW_PATH      <- pp("data", "trial_sponsors_raw.csv")
EVIDENCE_PATH <- pp("data", "sponsor_structured_evidence.csv")
OUT_PATH      <- pp("data", "sponsor_blocks.csv")

if (!file.exists(RAW_PATH)) {
  stop("Missing ", RAW_PATH, " — run 1_export_trial_sponsors.R first.", call. = FALSE)
}

# ── Corpus ────────────────────────────────────────────────────────────────────

raw <- read_csv(RAW_PATH, show_col_types = FALSE, progress = FALSE)
strings <- raw |>
  filter(!is.na(raw_sponsor), nzchar(trimws(raw_sponsor))) |>
  count(raw_sponsor, name = "n_trials") |>
  arrange(desc(n_trials), raw_sponsor)

# --only restricts the corpus to a subset, which is how C_assign's abstainers
# get a second chance: re-block just them, at a lower threshold, so strings
# whose only neighbours were also unassigned finally group with each other.
# Blocking the whole corpus at a low threshold instead would merge organisations
# that are genuinely distinct.
only_path <- arg_value("--only", NA_character_)
if (!is.na(only_path)) {
  op <- if (file.exists(only_path)) only_path else pp(only_path)
  if (!file.exists(op)) stop("--only file not found: ", only_path, call. = FALSE)
  keep <- read_csv(op, show_col_types = FALSE, progress = FALSE)$raw_sponsor
  before <- nrow(strings)
  strings <- strings |> filter(raw_sponsor %in% keep)
  message(sprintf("--only: %d of %d strings retained from %s",
                  nrow(strings), before, basename(op)))
  OUT_PATH <- pp("data", "sponsor_blocks_reblock.csv")
}

message(sprintf("corpus: %d distinct raw strings over %d trial rows",
                nrow(strings), sum(strings$n_trials)))

evidence <- if (file.exists(EVIDENCE_PATH)) {
  e <- read_csv(EVIDENCE_PATH, show_col_types = FALSE, progress = FALSE)
  message(sprintf("structured evidence: %d rows, %d distinct keys",
                  nrow(e), dplyr::n_distinct(e$evidence_key)))
  e
} else {
  message("structured evidence: none (run A0_extract_evidence.R to add the ",
          "businessKey / email-domain / postcode channel)")
  NULL
}

# ── Index and pair graph ──────────────────────────────────────────────────────
# Self-index: with no registry yet, the corpus is indexed against itself and the
# pairs are string-to-string.

message("building index (dual fold: transliterated + deleted)...")
t0  <- Sys.time()
idx <- build_index(strings$raw_sponsor, ids = seq_len(nrow(strings)))
message(sprintf("  %d surface forms, %d token postings, %.0fs",
                nrow(idx$forms), nrow(idx$tokens),
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))

# How much the dual fold actually adds: strings whose two folds differ are the
# ones the old transliterate-only cleaner could never join across registers.
dual <- idx$forms |> count(label_id, name = "n_forms") |> filter(n_forms > 1L)
message(sprintf("  %d strings indexed under two distinct folds (the cross-register fix)",
                nrow(dual)))

message("building pair graph...")
t0 <- Sys.time()
pairs <- build_pair_graph(idx, evidence = evidence, extra_channels = extra_channels)
message(sprintf("  %d candidate pairs, %.0fs", nrow(pairs),
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))

cat("\npairs by channel:\n")
print(as.data.frame(pairs |> count(channel, sort = TRUE)))

# What each channel contributes that no other channel found. A channel with a
# unique contribution near zero is paying graph-build time for nothing, which is
# the measurement that retired n-gram and acronym.
uniq <- pairs |>
  group_by(a, b) |>
  summarise(n_ch = dplyr::n(), channel = dplyr::first(channel), .groups = "drop") |>
  filter(n_ch == 1L) |>
  count(channel, name = "unique_pairs")
cat("\npairs found by exactly one channel:\n")
print(as.data.frame(uniq))

# ── Components ────────────────────────────────────────────────────────────────

message("\nblocking (greedy canopy)...")
# Connected components was tried here and produced one component holding 11,838
# of 16,594 strings — transitive closure chains everything once the graph has
# 200k edges. Canopy admits a string only if it is similar TO THE SEED, so a
# block is a statement about one string rather than a path through the graph.
cat(sprintf("  pair score distribution (%d pairs):\n", nrow(pairs)))
print(round(quantile(pairs$score, c(0, .25, .5, .75, .9, .95, .99, 1)), 3))
cat(sprintf("  pairs at or above threshold %.2f: %d\n",
            THRESHOLD, sum(pairs$score >= THRESHOLD)))

strings$block_raw <- canopy_blocks(
  pairs, n_nodes = nrow(strings), weights = strings$n_trials,
  threshold = THRESHOLD, max_block = MAX_BLOCK
)

strings <- strings |>
  group_by(block_raw) |>
  mutate(block_size = dplyr::n()) |>
  ungroup() |>
  arrange(desc(block_size > 1L), desc(n_trials)) |>
  mutate(block_id = sprintf("blk_%05d", as.integer(factor(block_raw, levels = unique(block_raw)))))

# ── Report ────────────────────────────────────────────────────────────────────

final_sizes <- strings |> count(block_id, name = "size")
cat("\n=== block size distribution ===\n")
print(table(cut(final_sizes$size,
                breaks = c(0, 1, 2, 5, 10, 20, 40, Inf),
                labels = c("1", "2", "3-5", "6-10", "11-20", "21-40", ">40"))))

multi <- final_sizes |> filter(size > 1L)
cat(sprintf("\nblocks           : %d\n", nrow(final_sizes)))
cat(sprintf("  singletons     : %d  (go straight to pass C or mint alone)\n",
            sum(final_sizes$size == 1L)))
cat(sprintf("  multi-member   : %d  (these are pass B's requests)\n", nrow(multi)))
cat(sprintf("  strings in them: %d\n", sum(multi$size)))

# Pass B request count and therefore pass B cost.
impact <- strings |> group_by(block_id) |> summarise(trials = sum(n_trials), .groups = "drop")
top <- impact |> arrange(desc(trials)) |> head(500)
cat(sprintf("\ntop 500 blocks carry %.1f%% of all trial rows\n",
            100 * sum(top$trials) / sum(strings$n_trials)))

cat("\n=== largest blocks (inspect these before trusting the graph) ===\n")
for (bid in (final_sizes |> arrange(desc(size)) |> head(3))$block_id) {
  m <- strings |> filter(block_id == bid) |> arrange(desc(n_trials))
  cat(sprintf("\n%s  (%d members)\n", bid, nrow(m)))
  for (i in seq_len(min(8L, nrow(m)))) {
    cat(sprintf("   %5d  %s\n", m$n_trials[[i]], substr(m$raw_sponsor[[i]], 1L, 88L)))
  }
  if (nrow(m) > 8L) cat(sprintf("   ... %d more\n", nrow(m) - 8L))
}

write_csv(strings |> select(raw_sponsor, block_id, n_trials, block_size),
          OUT_PATH, na = "", eol = "\n")
cat(sprintf("\nwrote %s (%d rows)\n", basename(OUT_PATH), nrow(strings)))
cat("Nothing decided. Pass B names the clusters.\n")
