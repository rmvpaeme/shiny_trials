#!/usr/bin/env Rscript
# Nightly incremental resolution of NEW sponsor strings.
#
# The A-E passes are a one-shot batch over a frozen corpus. The database updates
# every night, so a trial registered today can carry a sponsor string the
# registry has never seen. Without this script that string falls through
# E_emit's `coalesce(sponsor_clean, sponsor_name)` and is displayed raw — the app
# slowly re-accumulates exactly the unnormalised names the rewrite removed.
#
# This is NOT step F. It is the incremental driver: it runs C's and B's logic
# over new strings only, in that order, and never touches the frozen corpus.
#
#   already assigned  -> ignored, no cost
#   new + matches an existing canonical -> C places it there (cheap, pick-from-list)
#   new + matches nothing               -> B mints it a canonical
#   low confidence    -> E_review_queue.csv, for the existing curation flow
#
# ORDER MATTERS. Offering new strings to the existing registry BEFORE minting is
# what stops a new Novartis variant becoming a second Novartis. Minting first
# would fragment the registry exactly the way v1 did.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   - never runs A_block: it would rewrite data/sponsor_blocks.csv, which is
#     B_mint's members_sha cache-key input, triggering paid re-mints of unrelated
#     blocks. New strings get their own singleton work list instead.
#   - never runs D_consolidate: a wrong merge is the most expensive error the
#     pipeline can make and its mis-index guard is tuned against measured
#     failures. New canonicals are queued in N_new_entities.csv for a human.
#   - never uses --batch: llm_batch_wait() blocks on a 60s poll for up to 24h and
#     the nightly window is ~1h. At ~$0.0013/string, sync on 30 strings is four
#     cents; the 50% batch saving is not worth stalling the deploy.
#
# Usage
#   Rscript .../N_nightly_resolve.R              # what rebuild_cache.R runs
#   Rscript .../N_nightly_resolve.R --dry-run    # report the work list, no calls
#
# Exit codes (rebuild_cache.R branches on these)
#   0   nothing to do, or resolved. Abstentions are NOT failures.
#   10  no ANTHROPIC_API_KEY
#   11  per-run or project budget refused the run — backlog written
#   12  more new strings than the sync ceiling — backlog written
#   13  API failure, or most rows came back unparseable
#   14  a safety assertion failed — state restored from the snapshot

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
source(pp("helper_scripts", "llm_norm", "registry.R"))

args    <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args

# Tunables. Env vars so the server can differ from a laptop without a code edit.
MAX_SYNC     <- as.integer(Sys.getenv("SPONSOR_NIGHTLY_MAX_SYNC", "150"))
RUN_CAP_USD  <- as.numeric(Sys.getenv("SPONSOR_NIGHTLY_CAP_USD", "1.00"))
MAX_ATTEMPTS <- as.integer(Sys.getenv("SPONSOR_NIGHTLY_MAX_TRIES", "3"))
# MEASURED on the first live run: 132 strings cost $0.3358 (C_assign $0.2439 for
# 89 requests, B_mint $0.0919 for 72), i.e. $0.00254/string.
#
# The first estimate here was $0.0013, derived from the batch singleton mint. It
# was 2x low for two compounding reasons: sync bills at full rate where batch is
# half, and C_assign's system prompt is 622 tokens — below the 1,024-token
# minimum for Sonnet — so it does not cache and every request pays full input.
# llm_dry_run() prints "TOO SHORT TO CACHE" for exactly this, which is worth
# heeding if this pass ever gets expensive: padding that prompt past the minimum
# would cut its input cost roughly tenfold on repeat runs.
#
# Estimating from a constant rather than llm_dry_run() keeps the size decision
# OFFLINE — a cron job should not need a network round-trip to decide it is doing
# too much. At the 150-string ceiling this predicts ~$0.38, well under the cap,
# so the ceiling binds first and the cap is the backstop.
USD_PER_STRING <- as.numeric(Sys.getenv("SPONSOR_NIGHTLY_USD_PER_STRING", "0.0026"))

V2  <- Sys.getenv("SPONSOR_V2_DIR", unset = pp("config", "sponsor_norm_v2"))
REG <- file.path(V2, "registry.csv")
ASG <- file.path(V2, "assignments.csv")
MINT <- file.path(V2, "B_mint_clusters.csv")
CDEC <- file.path(V2, "C_assign_decisions.csv")
ABST <- file.path(V2, "C_abstained.csv")
NBLOCKS  <- file.path(V2, "N_blocks.csv")
NDEFER   <- file.path(V2, "N_deferred.csv")
NRUNS    <- file.path(V2, "N_nightly_runs.csv")
NBACKLOG <- file.path(V2, "N_backlog.csv")
NNEWENT  <- file.path(V2, "N_new_entities.csv")
SNAPDIR  <- file.path(V2, ".snapshot")
# DATA_DIR is the same override 1_export_trial_sponsors.R already honours, so a
# test run can point at a copied corpus without touching the tracked one.
DATA_DIR <- Sys.getenv("DATA_DIR", unset = pp("data"))
RAW      <- file.path(DATA_DIR, "trial_sponsors_raw.csv")
SENTINEL <- file.path(DATA_DIR, ".sponsor_nightly_failed")

RSCRIPT <- file.path(R.home("bin"), "Rscript")
if (!file.exists(RSCRIPT)) RSCRIPT <- "Rscript"
STATE_FILES <- c("registry.csv", "assignments.csv", "llm_spend.csv",
                 "B_mint_clusters.csv", "C_assign_decisions.csv")

# ── Run bookkeeping ───────────────────────────────────────────────────────────

RUN <- new.env(parent = emptyenv())
RUN$n_new <- 0L; RUN$n_assigned <- 0L; RUN$n_minted <- 0L
RUN$n_abstained <- 0L; RUN$n_failed <- 0L; RUN$est <- 0
RUN$started <- utc_now()

record_run <- function(status, code, message = "") {
  row <- tibble(
    run_utc = RUN$started, n_new = RUN$n_new, n_assigned = RUN$n_assigned,
    n_minted = RUN$n_minted, n_abstained = RUN$n_abstained,
    n_failed = RUN$n_failed, est_cost_usd = round(RUN$est, 4),
    actual_cost_usd = round(spend_total_safe(), 4),
    status = status, exit_code = code, message = message
  )
  # Read the history as ALL CHARACTER and coerce the new row to match. readr
  # otherwise parses run_utc back as <datetime> while the fresh row is
  # <character>, and bind_rows refuses to combine them — the same failure
  # llm_cache_merge() exists to prevent, and it would only ever fire on the
  # SECOND run, i.e. in production rather than in a first test.
  row <- dplyr::mutate(row, dplyr::across(dplyr::everything(), as.character))
  prior <- if (file.exists(NRUNS)) {
    suppressWarnings(read_csv(NRUNS, show_col_types = FALSE, progress = FALSE,
                              col_types = readr::cols(.default = readr::col_character())))
  } else NULL
  dir.create(dirname(NRUNS), recursive = TRUE, showWarnings = FALSE)
  write_csv(bind_rows(prior, row), NRUNS, na = "", eol = "\n")
  invisible(row)
}

spend_total_safe <- function() {
  p <- file.path(V2, "llm_spend.csv")
  if (!file.exists(p)) return(0)
  tryCatch(llm_spend_total(p), error = function(e) 0)
}

# A non-zero exit must be visible to the deploy script, which cannot read this
# process's status through `docker exec` reliably. A sentinel file can be tested.
finish <- function(status, code, msg = "") {
  record_run(status, code, msg)
  if (code == 0L) {
    if (file.exists(SENTINEL)) unlink(SENTINEL)
  } else {
    writeLines(sprintf("%s exit=%d %s", utc_now(), code, msg), SENTINEL)
    message(sprintf("*** SPONSOR NIGHTLY FAILED (exit %d) — %s ***", code, msg))
  }
  quit(save = "no", status = code)
}

snapshot_take <- function() {
  dir.create(SNAPDIR, recursive = TRUE, showWarnings = FALSE)
  for (f in STATE_FILES) {
    src <- file.path(V2, f)
    if (file.exists(src)) file.copy(src, file.path(SNAPDIR, f), overwrite = TRUE)
  }
}
snapshot_restore <- function() {
  for (f in STATE_FILES) {
    src <- file.path(SNAPDIR, f)
    if (file.exists(src)) file.copy(src, file.path(V2, f), overwrite = TRUE)
  }
  message("state restored from snapshot")
}

run_pass <- function(script, extra) {
  cmd <- c(pp("helper_scripts", "sponsor_norm_pipeline", script), extra)
  message(sprintf("\n--> %s %s", script, paste(extra, collapse = " ")))
  status <- system2(RSCRIPT, cmd)
  if (!identical(status, 0L)) {
    message(sprintf("    %s exited %s", script, status))
  }
  invisible(status)
}

# ── 1. What is new ────────────────────────────────────────────────────────────
# This block must stay ahead of llm_auth(), build_index() and any network call:
# on a normal night it is the whole program.

if (!file.exists(RAW)) {
  finish("no_raw", 13L, sprintf("%s missing — did 1_export run?", basename(RAW)))
}
if (!file.exists(REG) || !file.exists(ASG)) {
  finish("no_registry", 13L, "no registry/assignments — run the A-E passes first")
}

raw <- read_csv(RAW, show_col_types = FALSE, progress = FALSE)
asg <- assignments_read(ASG)

# EVERY column as character, then coerce what needs to be numeric.
#
# readr guesses, and it guessed <datetime> for the ISO timestamp this script had
# itself written. On the SECOND run coalesce(first_seen_utc, RUN$started) then
# refused to combine <datetime> with <character> and killed the whole sponsor
# pass — "Can't combine `..1` <datetime<UTC>> and `..2` <character>". The first
# run always works because the file does not exist yet, which is why this
# survived until a server had run twice. Same failure as llm_cache_merge.
deferred <- if (file.exists(NDEFER)) {
  read_csv(NDEFER, show_col_types = FALSE, progress = FALSE,
           col_types = cols(.default = col_character())) |>
    mutate(attempts = suppressWarnings(as.integer(attempts)))
} else tibble(raw_sponsor = character(), attempts = integer(),
              first_seen_utc = character(), last_attempt_utc = character(),
              last_reason = character())
stuck <- deferred$raw_sponsor[deferred$attempts >= MAX_ATTEMPTS]

todo <- raw |>
  filter(!is.na(raw_sponsor), nzchar(trimws(raw_sponsor))) |>
  count(raw_sponsor, name = "n_trials") |>
  filter(!raw_sponsor %in% asg$raw_sponsor, !raw_sponsor %in% stuck) |>
  arrange(desc(n_trials))

RUN$n_new <- nrow(todo)
RUN$est   <- RUN$n_new * USD_PER_STRING
message(sprintf("sponsor nightly: %d new string(s)%s", RUN$n_new,
                if (length(stuck)) sprintf(", %d deferred", length(stuck)) else ""))

if (!nrow(todo)) finish("clean", 0L, "nothing to do")

if (dry_run) {
  print(as.data.frame(head(todo, 25)))
  cat(sprintf("\nestimated $%.4f at $%s/string. No calls made.\n",
              RUN$est, format(USD_PER_STRING)))
  quit(save = "no", status = 0L)
}

# ── 2. Guard rails, cheapest first ────────────────────────────────────────────

write_backlog <- function() {
  write_csv(todo, NBACKLOG, na = "", eol = "\n")
  message("wrote ", basename(NBACKLOG), " — resolve by hand with:")
  message(sprintf("  Rscript .../C_assign.R --batch --blocks=%s", NBLOCKS))
  message("  Rscript .../B_mint.R --batch --singletons --only=", basename(ABST))
}

if (!nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
  write_backlog()
  finish("no_key", 10L,
         "ANTHROPIC_API_KEY unset in this environment — see README 'Nightly sponsor resolution'")
}

if (RUN$n_new > MAX_SYNC) {
  write_backlog()
  finish("above_ceiling", 12L, sprintf(
    "%d new strings exceeds SPONSOR_NIGHTLY_MAX_SYNC=%d — a spike this large means something structural changed; resolve by hand",
    RUN$n_new, MAX_SYNC))
}

capped <- tryCatch({
  llm_run_cap_guard(RUN$est, RUN_CAP_USD, "N_nightly")
  NULL
}, error = function(e) conditionMessage(e))
if (!is.null(capped)) {
  write_backlog()
  finish("run_cap", 11L, capped)
}

# Force the API-key branch in llm_auth() for every child process: the `ant` CLI
# fallback can block, and a cron job that blocks holds the deploy all day.
Sys.setenv(LLM_REQUIRE_API_KEY = "1")

# ── 3. Resolve ────────────────────────────────────────────────────────────────

snapshot_take()
reg_before <- registry_read(REG)
asg_before <- assignments_read(ASG)

# One singleton block per new string. Two spellings of one genuinely new
# organisation will mint separately, but registry_from_clusters collapses
# identical canonicals, so they fold into one entity for free.
todo |>
  mutate(block_id = sprintf("nb_%05d", row_number()), block_size = 1L) |>
  select(raw_sponsor, block_id, n_trials, block_size) |>
  write_csv(NBLOCKS, na = "", eol = "\n")

st_c <- run_pass("C_assign.R", c("--sync", paste0("--blocks=", NBLOCKS)))
st_b <- 0L
if (file.exists(ABST) && nrow(read_csv(ABST, show_col_types = FALSE, progress = FALSE))) {
  st_b <- run_pass("B_mint.R", c("--sync", "--singletons",
                                 paste0("--blocks=", NBLOCKS),
                                 paste0("--only=", ABST)))
}

# ── 4. Materialise ONLY tonight's clusters ────────────────────────────────────
# Not a second C_assign run: filtering to tonight's strings is what keeps this
# from rewriting decided_at_utc on all 16,594 assignment rows every night.

mint <- if (file.exists(MINT)) llm_cache_read(MINT) else NULL
fresh_clusters <- if (!is.null(mint)) {
  mint |> filter(raw_sponsor %in% todo$raw_sponsor, !is.na(canonical))
} else NULL
if (!is.null(fresh_clusters) && nrow(fresh_clusters)) {
  built <- registry_from_clusters(fresh_clusters, registry_read(REG), assignments_read(ASG))
  registry_write(built$registry, REG)
  assignments_write(built$assignments, ASG)
}

reg_after <- registry_read(REG)
asg_after <- assignments_read(ASG)
RUN$n_minted   <- nrow(reg_after) - nrow(reg_before)
RUN$n_assigned <- sum(todo$raw_sponsor %in% asg_after$raw_sponsor)
RUN$n_abstained <- RUN$n_new - RUN$n_assigned

# New canonicals are queued for a human rather than auto-merged.
if (RUN$n_minted > 0L) {
  new_ent <- reg_after |>
    filter(!entity_id %in% reg_before$entity_id) |>
    transmute(entity_id, canonical, entity_type, confidence, first_seen_utc = RUN$started)
  prior <- if (file.exists(NNEWENT)) {
    read_csv(NNEWENT, show_col_types = FALSE, progress = FALSE,
             col_types = cols(.default = col_character()))
  } else NULL
  if (!is.null(prior)) new_ent <- mutate(new_ent, across(everything(), as.character))
  write_csv(bind_rows(prior, new_ent), NNEWENT, na = "", eol = "\n")
  message(sprintf("%d new canonical(s) -> %s (run D_consolidate periodically)",
                  nrow(new_ent), basename(NNEWENT)))
}

# ── 5. Did the API actually work? ─────────────────────────────────────────────
# C_assign --sync exits 0 even if every request returned HTTP 401: per-row
# failures become cache rows with chosen_index = NA. Count them.

n_failed <- 0L
if (file.exists(CDEC)) {
  dec <- llm_cache_read(CDEC)
  if (!is.null(dec) && "raw_sponsor" %in% names(dec)) {
    tonight <- dec |> filter(raw_sponsor %in% todo$raw_sponsor)
    n_failed <- sum(is.na(tonight$chosen_index) | tonight$chosen_index == "")
  }
}
RUN$n_failed <- n_failed

# ── 6. Safety assertions ──────────────────────────────────────────────────────

violations <- character()
pin_before <- asg_before |> filter(decided_by %in% "human") |> arrange(raw_sponsor)
pin_after  <- asg_after  |> filter(decided_by %in% "human") |> arrange(raw_sponsor)
if (!identical(nrow(pin_before), nrow(pin_after)) ||
    !identical(pin_before$entity_id, pin_after$entity_id)) {
  violations <- c(violations, "a human-pinned assignment changed")
}
moved <- asg_before |>
  select(raw_sponsor, old = entity_id) |>
  inner_join(asg_after |> select(raw_sponsor, new = entity_id), by = "raw_sponsor") |>
  filter(old != new)
if (nrow(moved)) {
  violations <- c(violations, sprintf("%d existing assignment(s) re-pointed", nrow(moved)))
}
merge_before <- reg_before |> transmute(entity_id, merged_into) |> arrange(entity_id)
merge_after  <- reg_after  |> filter(entity_id %in% reg_before$entity_id) |>
  transmute(entity_id, merged_into) |> arrange(entity_id)
if (!identical(merge_before, merge_after)) {
  violations <- c(violations, "a merge record changed")
}
if (nrow(reg_after) < nrow(reg_before)) {
  violations <- c(violations, "the registry shrank")
}

if (length(violations)) {
  snapshot_restore()
  finish("assertion_failed", 14L, paste(violations, collapse = "; "))
}

# ── 7. Deferred list ──────────────────────────────────────────────────────────
# A string C abstains on AND B fails to mint would otherwise be re-asked every
# night forever: C's cache key includes the candidate-set hash, which shifts as
# the registry grows, so failures do not self-suppress.

unresolved <- setdiff(todo$raw_sponsor, asg_after$raw_sponsor)
if (length(unresolved)) {
  upd <- tibble(raw_sponsor = unresolved) |>
    left_join(deferred, by = "raw_sponsor") |>
    mutate(
      attempts = coalesce(attempts, 0L) + 1L,
      first_seen_utc = coalesce(first_seen_utc, RUN$started),
      last_attempt_utc = RUN$started,
      last_reason = "unassigned after C and B"
    )
  keep <- deferred |> filter(!raw_sponsor %in% unresolved)
  write_csv(bind_rows(keep, upd), NDEFER, na = "", eol = "\n")
  message(sprintf("%d string(s) still unassigned -> %s", length(unresolved), basename(NDEFER)))
}

if (!identical(st_c, 0L) || !identical(st_b, 0L) ||
    (RUN$n_new > 0L && n_failed > RUN$n_new / 2)) {
  finish("api_failure", 13L, sprintf(
    "C exit %s, B exit %s, %d of %d rows unparseable", st_c, st_b, n_failed, RUN$n_new))
}

message(sprintf("\nsponsor nightly: %d new, %d assigned, %d new canonical(s), %d unresolved",
                RUN$n_new, RUN$n_assigned, RUN$n_minted, length(unresolved)))
finish("resolved", 0L, "")
