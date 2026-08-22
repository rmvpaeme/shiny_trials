#!/usr/bin/env Rscript
# Nightly incremental resolution of NEW substance strings.
#
# A-E are a one-shot batch over a frozen corpus. The database updates every
# night, so a trial registered today can carry a substance string the registry
# has never seen. Without this script that string is simply never labelled —
# and unlike sponsors there is no raw-name fallback to soften it, because v2
# deliberately dropped v1's (it was what put "Not yet assigned" and
# "mL concentrate for solution for infusion" into the app's substance filter).
#
# THE CHEAP PASS RUNS FIRST, AND IT DOES MOST OF THE WORK. Measured on a real
# nightly delta of 986 new strings:
#
#   431  matched ChEMBL/EPAR exactly            -> free, no API call
#    10  filtered as dosage language            -> free
#     2  placebo                                -> free
#     5  ambiguous alias                        -> model
#   538  no registry hit                        -> model
#
# So 44% of a night's new strings never reach the API. That is the whole reason
# the deterministic pass exists, and it is why this script calls A_resolve
# before anything else.
#
# ORDER MATTERS AFTER THAT TOO: offer the new strings to the EXISTING registry
# (B_assign, pick-from-list) before minting anything (C_mint). Minting first
# would fragment the registry — a new spelling of a drug already in ChEMBL would
# become a second entity for it.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   - never runs D_consolidate: a wrong merge is the most expensive error this
#     pipeline can make, and its guards are tuned against measured failures.
#     New canonicals are left for the next manual consolidation pass.
#   - never uses --batch: llm_batch_wait() polls for up to 24h and the nightly
#     window is ~1h. At these volumes sync costs cents.
#   - never re-runs the full A_resolve: that rebuild discards every model-minted
#     entity. --incremental is the only safe entry point once B and C have run.
#
# Usage
#   Rscript .../N_nightly_resolve.R              # what rebuild_cache.R runs
#   Rscript .../N_nightly_resolve.R --dry-run    # report the work list, no calls
#
# Environment
#   SUBSTANCE_NIGHTLY_MAX_SYNC       default 300  refuse above this many strings
#   SUBSTANCE_NIGHTLY_CAP_USD        default 1.00 per-run ceiling
#   SUBSTANCE_NIGHTLY_USD_PER_STRING default 0.0023 (measured on the live B pass)
#
# Exit codes (rebuild_cache.R branches on these)
#   0   nothing to do, or resolved. Abstentions are NOT failures.
#   10  no ANTHROPIC_API_KEY
#   11  per-run budget refused the run — backlog written
#   12  more new strings than the sync ceiling — backlog written
#   13  a sub-pass failed

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "client.R"))

args    <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args

MAX_SYNC       <- as.integer(Sys.getenv("SUBSTANCE_NIGHTLY_MAX_SYNC", "300"))
RUN_CAP_USD    <- as.numeric(Sys.getenv("SUBSTANCE_NIGHTLY_CAP_USD", "1.00"))
USD_PER_STRING <- as.numeric(Sys.getenv("SUBSTANCE_NIGHTLY_USD_PER_STRING", "0.0023"))

V2       <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
DATA_DIR <- Sys.getenv("DATA_DIR",         unset = pp("data"))
NRUNS    <- file.path(V2, "N_nightly_runs.csv")
NBACKLOG <- file.path(V2, "N_backlog.csv")
RESIDUE  <- file.path(DATA_DIR, "substance_residue.csv")
ASG      <- file.path(V2, "assignments.csv")
SPEND    <- file.path(V2, "llm_spend.csv")

sb <- function(f) pp("helper_scripts", "substance_norm_pipeline_v2", f)
rscript <- file.path(R.home("bin"), "Rscript")

run_step <- function(script, args = character(), label = basename(script)) {
  message("  -> ", label)
  status <- system2(rscript, c(script, args))
  if (!identical(status, 0L)) message(sprintf("     %s exited %s", label, status))
  invisible(status)
}

record_run <- function(outcome, n_new, n_model, note = "") {
  row <- tibble(ran_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                outcome = outcome, n_new_strings = n_new,
                n_sent_to_model = n_model, note = note)
  # EVERY column as character. readr guesses, and it guessed <datetime> for the
  # ISO timestamp it had just written, so bind_rows() refused to combine it with
  # the fresh character row and killed the script AFTER all the work was saved.
  # Same failure as llm_cache_merge (sponsor handover §3.0a): a run log that
  # crashes on its own output is worse than no run log.
  prev <- if (file.exists(NRUNS)) {
    suppressWarnings(read_csv(NRUNS, show_col_types = FALSE, progress = FALSE,
                              col_types = readr::cols(.default = readr::col_character())))
  } else NULL
  if (!is.null(prev)) row <- mutate(row, across(everything(), as.character))
  dir.create(dirname(NRUNS), recursive = TRUE, showWarnings = FALSE)
  write_csv(bind_rows(prev, row), NRUNS, na = "", eol = "\n")
}

finish <- function(code, outcome, n_new = 0L, n_model = 0L, note = "") {
  # Bookkeeping must never change the outcome of a run that already succeeded.
  tryCatch(record_run(outcome, n_new, n_model, note),
           error = function(e) message("  (run log not written: ", conditionMessage(e), ")"))
  quit(save = "no", status = code)
}

# ── 1. Deterministic pass over new strings only. Free, no API. ────────────────

message("=== substance nightly: deterministic pass ===")
st <- run_step(sb("A_resolve.R"), "--incremental", label = "A_resolve --incremental")
if (!identical(st, 0L)) finish(13L, "a_resolve_failed", note = "A_resolve --incremental")

# ── 2. What is left for the model ─────────────────────────────────────────────
# The residue file is cumulative, so subtract what is already assigned rather
# than trusting its length.

if (!file.exists(RESIDUE)) finish(0L, "no_residue_file")
resid <- read_csv(RESIDUE, show_col_types = FALSE, progress = FALSE)

# "Unresolved" means no answer of ANY kind, which is not the same as "not
# assigned". A string the model judged not-a-substance has an answer; so does
# one already matched. Counting only the assigned ones inflated this by ~1,000
# and would re-send the same dosage-language strings to the API every single
# night — the cost equivalent of the B_assign convergence bug (handover §4.7b).
col1 <- function(path, col) {
  if (!file.exists(path)) return(character())
  x <- suppressWarnings(read_csv(path, show_col_types = FALSE, progress = FALSE))
  if (col %in% names(x)) as.character(x[[col]]) else character()
}
answered <- unique(c(
  col1(ASG, "raw_substance"),
  col1(file.path(V2, "B_not_substance.csv"), "raw_substance"),
  col1(file.path(V2, "C_not_substance.csv"), "raw_substance"),
  local({
    d <- if (file.exists(file.path(V2, "B_assign_decisions.csv"))) {
      suppressWarnings(read_csv(file.path(V2, "B_assign_decisions.csv"),
                                show_col_types = FALSE, progress = FALSE))
    } else NULL
    if (is.null(d) || !all(c("raw_substance", "chosen_index") %in% names(d))) character()
    else unique(d$raw_substance[!is.na(suppressWarnings(as.integer(d$chosen_index)))])
  })
))
todo <- resid |> filter(!raw_substance %in% answered)

message(sprintf("unresolved after the deterministic pass: %d string(s) / %d trial pairs",
                nrow(todo), sum(todo$n_trials, na.rm = TRUE)))

if (!nrow(todo)) {
  message("Nothing for the model. Registry unchanged.")
  finish(0L, "nothing_to_do")
}

if (dry_run) {
  print(as.data.frame(todo |> arrange(desc(n_trials)) |> head(20)))
  message(sprintf("--dry-run: would send %d string(s), est $%.2f",
                  nrow(todo), nrow(todo) * USD_PER_STRING))
  quit(save = "no", status = 0L)
}

# ── 3. Guards ─────────────────────────────────────────────────────────────────
# A ceiling AND a budget, because they fail differently. A corpus reload that
# dumps thousands of new strings is affordable and still means something
# structural broke, so it wants a human rather than an unattended bill.

if (!nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
  message("*** no ANTHROPIC_API_KEY — backlog written, nothing resolved ***")
  write_csv(todo, NBACKLOG, na = "", eol = "\n")
  finish(10L, "no_api_key", nrow(todo), 0L)
}

if (nrow(todo) > MAX_SYNC) {
  message(sprintf("*** %d new strings exceeds the %d ceiling — refusing ***",
                  nrow(todo), MAX_SYNC))
  message("    This is a size guard, not a budget guard. Raise it deliberately")
  message("    with SUBSTANCE_NIGHTLY_MAX_SYNC, or run the passes by hand.")
  write_csv(todo, NBACKLOG, na = "", eol = "\n")
  finish(12L, "over_ceiling", nrow(todo), 0L,
         sprintf("%d > %d", nrow(todo), MAX_SYNC))
}

est <- nrow(todo) * USD_PER_STRING
ok <- tryCatch({
  llm_run_cap_guard(est, RUN_CAP_USD, "N_nightly (substance)",
                    cap_var = "SUBSTANCE_NIGHTLY_CAP_USD")
  llm_budget_guard(est, SPEND, "N_nightly (substance)")
  TRUE
}, error = function(e) { message("*** ", conditionMessage(e), " ***"); FALSE })
if (!ok) {
  write_csv(todo, NBACKLOG, na = "", eol = "\n")
  finish(11L, "budget_refused", nrow(todo), 0L)
}

# ── 4. Assign against the existing registry, THEN mint the remainder ──────────

message("=== substance nightly: model passes ===")
n_before <- if (file.exists(ASG)) nrow(read_csv(ASG, show_col_types = FALSE, progress = FALSE)) else 0L

st <- run_step(sb("B_assign.R"), c("--sync", paste0("--limit=", nrow(todo))),
               label = "B_assign --sync")
if (!identical(st, 0L)) finish(13L, "b_assign_failed", nrow(todo), nrow(todo))

# Whatever B abstained on gets a canonical of its own. --singletons because a
# handful of new strings will not block with each other meaningfully.
st <- run_step(sb("B_assign.R"), "--rebuild-lists", label = "B_assign --rebuild-lists")
if (identical(st, 0L)) {
  st <- run_step(sb("C_mint.R"), c("--sync", "--singletons", paste0("--limit=", MAX_SYNC)),
                 label = "C_mint --sync --singletons")
  if (identical(st, 0L)) run_step(sb("C_mint.R"), "--materialise", label = "C_mint --materialise")
}

n_after <- if (file.exists(ASG)) nrow(read_csv(ASG, show_col_types = FALSE, progress = FALSE)) else 0L
message(sprintf("assignments %d -> %d (+%d)", n_before, n_after, n_after - n_before))

# Abstentions are not failures — E_emit reports whatever is still unresolved,
# and the regression gate in rebuild_cache.R decides whether to write labels.
if (file.exists(NBACKLOG)) unlink(NBACKLOG)
finish(0L, "resolved", nrow(todo), nrow(todo),
       sprintf("assignments +%d", n_after - n_before))
