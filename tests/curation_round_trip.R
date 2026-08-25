# Decision -> export -> registry -> E_emit. The whole loop, in scratch dirs.
#
#   tests/with_scratch_v2.sh Rscript tests/curation_round_trip.R
#
# This is the first thing in the branch that can change production data, so the
# properties checked here are the ones that make it safe to run unattended:
#
#   * a human pin actually reaches assignments.csv as decided_by = "human"
#   * a reject does NOT trip the regression gate (the fix that had to land first)
#   * running --write twice is BYTE-IDENTICAL, or the nightly churns forever
#   * an unchanged run takes no backup, which makes idempotence observable
#   * every failure path exits 0, or a curation hiccup costs the data refresh

suppressPackageStartupMessages({ library(DBI); library(readr); library(dplyr) })

SP <- Sys.getenv("SPONSOR_V2_DIR"); SB <- Sys.getenv("SUBSTANCE_V2_DIR")
DD <- Sys.getenv("DATA_DIR")
if (!nzchar(SP) || !nzchar(DD))
  stop("run me through tests/with_scratch_v2.sh", call. = FALSE)

source("curation_app/R/store.R")
cfg <- curation_db_config()
if (is.null(cfg)) { message("COULD NOT MEASURE: CURATION_DB_URL is not set."); quit(save="no", status=2L) }
con <- tryCatch(curation_connect(), error = function(e) NULL)
if (is.null(con)) { message("COULD NOT MEASURE: database unreachable"); quit(save="no", status=2L) }

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}
rscript <- file.path(R.home("bin"), "Rscript")
run_export <- function(domain, ...) {
  out <- suppressWarnings(system2(rscript,
    c("curation_app/export.R", paste0("--domain=", domain), ...),
    stdout = TRUE, stderr = TRUE))
  list(status = as.integer(attr(out, "status") %||% 0L), out = paste(out, collapse = "\n"))
}
`%||%` <- function(a,b) if (is.null(a)) b else a
sha <- function(p) if (file.exists(p)) unname(tools::md5sum(p)) else NA_character_

U <- "__test__rt"
cleanup <- function() {
  for (t in c("norm_decisions","trial_decisions","trial_reviews","export_runs"))
    try(dbExecute(con, sprintf("DELETE FROM %s WHERE reviewer LIKE '__test__%%'", t)), silent = TRUE)
  try(dbExecute(con, "DELETE FROM export_runs WHERE domain IS NOT NULL AND host IS NOT NULL AND export_id IN (SELECT export_id FROM export_runs ORDER BY started_at_utc DESC LIMIT 20)"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM reviewers WHERE username LIKE '__test__%'"), silent = TRUE)
  invisible(NULL)
}

run <- function() {
  cleanup()
  invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                            VALUES ($1,'RT',$2,'reviewer')",
                      params = list(U, sodium::password_store("x"))))

  asg_path <- file.path(SP, "assignments.csv")
  reg_path <- file.path(SP, "registry.csv")
  asg0 <- read_csv(asg_path, show_col_types = FALSE, progress = FALSE)
  # A raw string that already resolves, so a reject is a real change.
  victim <- asg0$raw_sponsor[!is.na(asg0$entity_id)][1]
  # And one the registry has never been given an assignment for.
  unassigned <- setdiff(
    read_csv(file.path(SP, "E_review_queue.csv"), show_col_types = FALSE, progress = FALSE)$raw_sponsor,
    asg0$raw_sponsor)[1]

  cat("1. an accept becomes a human pin\n")
  target <- read_csv(reg_path, show_col_types = FALSE, progress = FALSE)$canonical[1]
  invisible(append_norm_decision(con, "sponsor", victim, "accept", U, strrep("a", 40),
                                 proposed = target, final_canonical = target))
  r <- run_export("sponsor", "--write")
  check(r$status == 0L, "export exits 0")
  a1 <- read_csv(asg_path, show_col_types = FALSE, progress = FALSE)
  row <- a1[a1$raw_sponsor == victim, ]
  check(nrow(row) == 1 && identical(row$decided_by[[1]], "human"),
        "the assignment is now decided_by = 'human'")
  check(identical(row$channel[[1]], "review"), "channel records where it came from")
  check(grepl("^curation:", row$reason[[1]]),
        "reason traces back to the Postgres decision")
  check(as.numeric(row$confidence[[1]]) == 1, "a human decision has confidence 1")

  cat("\n2. running it again changes nothing at all\n")
  before <- c(sha(asg_path), sha(reg_path))
  n_backups_before <- length(list.dirs(file.path(SP, "backups"), recursive = FALSE))
  r2 <- run_export("sponsor", "--write")
  check(r2$status == 0L, "the second run also exits 0")
  check(identical(before, c(sha(asg_path), sha(reg_path))),
        "both files are BYTE-IDENTICAL after a second --write")
  check(length(list.dirs(file.path(SP, "backups"), recursive = FALSE)) == n_backups_before,
        "and no second backup was taken — idempotence is observable, not asserted")
  check(grepl("Already up to date", r2$out), "and it says so")

  cat("\n3. a string with no assignment row is INSERTED, not dropped\n")
  if (!is.na(unassigned)) {
    invisible(append_norm_decision(con, "sponsor", unassigned, "accept", U, strrep("a", 40),
                                   proposed = target, final_canonical = target))
    invisible(run_export("sponsor", "--write"))
    a2 <- read_csv(asg_path, show_col_types = FALSE, progress = FALSE)
    check(unassigned %in% a2$raw_sponsor,
          "a queued string with no existing assignment gains one")
  } else cat("  SKIP  no unassigned queue string available\n")

  cat("\n4. a reject does not trip the regression gate\n")
  invisible(append_norm_decision(con, "sponsor", victim, "reject", U, strrep("a", 40)))
  invisible(run_export("sponsor", "--write"))
  a3 <- read_csv(asg_path, show_col_types = FALSE, progress = FALSE)
  rj <- a3[a3$raw_sponsor == victim, ]
  check(is.na(rj$entity_id[[1]]) && identical(rj$decided_by[[1]], "human"),
        "a reject clears entity_id and keeps decided_by = human")
  g <- suppressWarnings(system2(rscript,
    c("helper_scripts/sponsor_norm_pipeline/E_emit.R", "--diff-only", "--assert-no-regressions"),
    stdout = TRUE, stderr = TRUE))
  gs <- as.integer(attr(g, "status") %||% 0L)
  check(gs == 0L, "the gate PASSES after a human reject (this is the whole point)")
  check(any(grepl("human unassign (intended)", g, fixed = TRUE)),
        "and the diff names the class rather than hiding it")

  cat("\n5. a new canonical is minted once, never twice\n")
  novel <- paste0("__Test__ Curation Entity ", as.integer(Sys.time()))
  invisible(append_norm_decision(con, "sponsor", victim, "edit", U, strrep("a", 40),
                                 proposed = target, final_canonical = novel,
                                 new_canonical = TRUE))
  invisible(run_export("sponsor", "--write"))
  reg1 <- read_csv(reg_path, show_col_types = FALSE, progress = FALSE)
  check(sum(reg1$canonical == novel) == 1, "the canonical is created")
  check(identical(reg1$decided_by[reg1$canonical == novel][1], "human"),
        "and attributed to a human")
  s_before <- sha(reg_path)
  invisible(run_export("sponsor", "--write"))
  reg2 <- read_csv(reg_path, show_col_types = FALSE, progress = FALSE)
  check(sum(reg2$canonical == novel) == 1, "a re-run does NOT mint a second copy")
  check(identical(s_before, sha(reg_path)), "and the registry is unchanged")

  cat("\n6. trial overrides\n")
  invisible(append_trial_decision(con, "__test__T1", "phase", "override", U, strrep("a", 40),
                                  norm_shown = "Phase I", final_value = "Phase II",
                                  value_type = "character"))
  # A field that routes to a REGISTRY must never reach the override file.
  invisible(append_trial_decision(con, "__test__T2", "sponsor", "override", U, strrep("a", 40),
                                  norm_shown = "X", final_value = "Y", value_type = "character"))
  invisible(run_export("trial", "--write"))
  ov_path <- file.path(DD, "trial_overrides.csv")
  check(file.exists(ov_path), "trial_overrides.csv is written")
  ov <- read_csv(ov_path, show_col_types = FALSE, progress = FALSE)
  check(any(ov$`_id` == "__test__T1" & ov$column == "phase"), "a phase override is exported")
  check(!any(ov$field_id == "sponsor"),
        "a registry-routed field is DROPPED, not written as a per-trial override")
  s_ov <- sha(ov_path)
  invisible(run_export("trial", "--write"))
  check(identical(s_ov, sha(ov_path)), "a second run is byte-identical")

  cat("\n7. failure never costs the data refresh\n")
  # R_ENVIRON_USER is load-bearing here. R reads ./.Renviron at startup and it
  # OVERRIDES the inherited environment, so passing a bad CURATION_DB_URL alone
  # is silently undone and the export connects successfully — the first version
  # of this check tested nothing and reported the working sentinel as broken.
  bad <- suppressWarnings(system2(rscript,
    c("curation_app/export.R", "--domain=sponsor", "--write"),
    env = c("R_ENVIRON_USER=/dev/null",
            "CURATION_DB_URL=postgresql://nobody:nope@127.0.0.1:1/none"),
    stdout = TRUE, stderr = TRUE))
  check(as.integer(attr(bad, "status") %||% 0L) == 0L,
        "an unreachable database still exits 0")
  check(file.exists(file.path(DD, ".curation_export_failed")),
        "and raises the sentinel the nightly reads")
  unlink(file.path(DD, ".curation_export_failed"))
  invisible(NULL)
}

status <- tryCatch({ run(); 0L },
  error = function(e) { cat("\nERROR:", conditionMessage(e), "\n"); 1L },
  finally = { cleanup(); try(dbDisconnect(con), silent = TRUE) })

cat("\n")
if (length(failures) || status != 0L) {
  cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L)
}
cat("all checks passed\n")
