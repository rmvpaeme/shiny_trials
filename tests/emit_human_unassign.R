# A human unassignment is not a regression — and a model one still is.
#
# Run through the scratch wrapper, which is what makes this safe:
#   tests/with_scratch_v2.sh Rscript tests/emit_human_unassign.R
#
# WHAT THIS PINS
#
# A reviewer rejecting a proposal writes entity_id = NA. That resolves to no
# label, which is indistinguishable from a pipeline failure unless decided_by is
# consulted. Classified as a regression it exits 1 under --assert-no-regressions,
# and rebuild_cache.R then keeps yesterday's labels FOREVER while reporting a
# pipeline fault. One reviewer rejecting one string would freeze sponsor labels
# permanently — so this has to hold before any writer exists.
#
# The second case is the one that gives the first its meaning. Exempting human
# rows is only correct if the gate still fires for everything else; without case
# B, case A would also pass if someone simply deleted the assertion.

suppressPackageStartupMessages({
  library(dplyr); library(readr)
})

SPONSOR_V2   <- Sys.getenv("SPONSOR_V2_DIR")
SUBSTANCE_V2 <- Sys.getenv("SUBSTANCE_V2_DIR")
DATA_DIR     <- Sys.getenv("DATA_DIR")

if (!nzchar(SPONSOR_V2) || !nzchar(SUBSTANCE_V2) || !nzchar(DATA_DIR))
  stop("Run me through tests/with_scratch_v2.sh — I rewrite assignments.csv.",
       call. = FALSE)

failures <- character()
ok   <- function(msg) cat(sprintf("  ok    %s\n", msg))
fail <- function(msg) { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
check <- function(cond, msg) if (isTRUE(cond)) ok(msg) else fail(msg)

rscript <- file.path(R.home("bin"), "Rscript")

# Runs the gate and captures both the exit status and the diff table, because
# the status alone cannot tell "passed because the class is exempt" from
# "passed because the assertion was removed".
run_gate <- function(script) {
  out <- suppressWarnings(system2(
    rscript, c(script, "--diff-only", "--assert-no-regressions"),
    stdout = TRUE, stderr = TRUE))
  list(status = as.integer(attr(out, "status") %||% 0L), out = paste(out, collapse = "\n"))
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# The victim: the raw string with the most trials that currently resolves AND
# has a label in the baseline. Picked from the data rather than hardcoded, so
# the test keeps working as the corpus moves.
pick_victim <- function(raw_path, asg_path, base_path, raw_col, label_col) {
  raw  <- read_csv(raw_path,  show_col_types = FALSE, progress = FALSE)
  asg  <- read_csv(asg_path,  show_col_types = FALSE, progress = FALSE)
  base <- read_csv(base_path, show_col_types = FALSE, progress = FALSE)
  labelled_ids <- base[[ "_id" ]][!is.na(base[[label_col]]) & nzchar(base[[label_col]])]
  raw |>
    filter(`_id` %in% labelled_ids) |>
    count(.data[[raw_col]], name = "n_trials") |>
    inner_join(asg |> filter(!is.na(entity_id)) |> select(all_of(raw_col)), by = raw_col) |>
    arrange(desc(n_trials)) |>
    slice(1)
}

# Rewrites one assignment row to an unassignment by the given actor.
unassign <- function(asg_path, raw_col, raw_value, actor) {
  asg <- read_csv(asg_path, show_col_types = FALSE, progress = FALSE,
                  col_types = cols(.default = col_character()))
  hit <- asg[[raw_col]] == raw_value
  stopifnot(sum(hit, na.rm = TRUE) == 1L)
  asg$entity_id[hit]  <- NA_character_
  asg$decided_by[hit] <- actor
  write_csv(asg, asg_path, na = "", eol = "\n")
}

domain_test <- function(label, v2_dir, script, raw_col, raw_file, base_file, label_col) {
  cat(sprintf("\n== %s ==\n", label))
  asg_path <- file.path(v2_dir, "assignments.csv")
  pristine <- read_csv(asg_path, show_col_types = FALSE, progress = FALSE,
                       col_types = cols(.default = col_character()))
  restore <- function() write_csv(pristine, asg_path, na = "", eol = "\n")

  victim <- pick_victim(file.path(DATA_DIR, raw_file), asg_path,
                        file.path(DATA_DIR, base_file), raw_col, label_col)
  if (!nrow(victim)) { fail(sprintf("%s: found no resolvable string to unassign", label)); return() }
  v_raw <- victim[[raw_col]][1]; v_n <- victim$n_trials[1]
  cat(sprintf("  victim: %s (%d trials)\n", v_raw, v_n))

  # A — a reviewer unassigned it. The gate must pass and must SAY so.
  unassign(asg_path, raw_col, v_raw, "human")
  a <- run_gate(script)
  check(a$status == 0L,
        sprintf("%s: human unassign exits 0 (got %d)", label, a$status))
  check(grepl("human unassign (intended)", a$out, fixed = TRUE),
        sprintf("%s: diff table names the human-unassign class", label))
  # The class must be absent from the diff table entirely, not merely
  # under-asserted: "REGRESSION" appearing anywhere means some trial still took
  # that branch, and the exit status would only stay 0 by accident.
  check(!grepl("REGRESSION", a$out, fixed = TRUE),
        sprintf("%s: the diff table reports no regressions at all", label))
  check(grepl("mistaken reject is visible here", a$out, fixed = TRUE),
        sprintf("%s: the unassigned string is printed, not merely counted", label))
  restore()

  # B — the same row, unassigned by the model. The gate must still fire, or
  # case A proves only that the assertion was deleted.
  unassign(asg_path, raw_col, v_raw, "model")
  b <- run_gate(script)
  check(b$status == 1L,
        sprintf("%s: a MODEL unassign still exits 1 (got %d)", label, b$status))
  check(grepl("REGRESSIONS — these must be zero", b$out, fixed = TRUE),
        sprintf("%s: the regression is reported for a model unassign", label))
  restore()
}

domain_test("sponsor", SPONSOR_V2,
            file.path("helper_scripts", "sponsor_norm_pipeline", "E_emit.R"),
            "raw_sponsor", "trial_sponsors_raw.csv",
            "trial_sponsor_labels_baseline.csv", "sponsor_clean")

domain_test("substance", SUBSTANCE_V2,
            file.path("helper_scripts", "substance_norm_pipeline_v2", "E_emit.R"),
            "raw_substance", "trial_substances_raw.csv",
            "trial_substance_labels_baseline.csv", "substance_label")

cat("\n")
if (length(failures)) {
  cat(sprintf("%d check(s) failed:\n", length(failures)))
  cat(paste0("  - ", failures, collapse = "\n"), "\n")
  quit(save = "no", status = 1L)
}
cat("all checks passed\n")
