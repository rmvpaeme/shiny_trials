# The decision store, against a real Postgres.
#
#   Rscript tests/curation_store.R
#
# Needs CURATION_DB_URL. Skips (exit 2) without one, so a checkout with no
# database still runs the rest of the suite.
#
# ALL TEST DATA IS NAMESPACED AND DELETED AT THE END. Reviewer usernames and raw
# values are prefixed __test__ so a failure part-way through leaves something
# obviously disposable rather than plausible-looking curation decisions.

suppressPackageStartupMessages({ library(DBI) })
source("curation_app/R/store.R")

cfg <- curation_db_config()
if (is.null(cfg)) {
  message("COULD NOT MEASURE: CURATION_DB_URL is not set.")
  quit(save = "no", status = 2L)
}
con <- tryCatch(curation_connect(), error = function(e) e)
if (inherits(con, "error")) {
  message("COULD NOT MEASURE: cannot reach ", curation_db_label(), " — ", conditionMessage(con))
  quit(save = "no", status = 2L)
}
cat("connected to", curation_db_label(), "\n\n")

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

U1 <- "__test__alice"; U2 <- "__test__bob"
RV <- paste0("__test__RAW ", as.integer(Sys.time()))
TID <- "__test__2020-000001-11-BE"
SHA <- strrep("a", 40)

cleanup <- function() {
  try(dbExecute(con, "DELETE FROM norm_decisions  WHERE reviewer LIKE '__test__%'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM trial_decisions WHERE reviewer LIKE '__test__%'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM trial_reviews   WHERE reviewer LIKE '__test__%'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM admin_audit     WHERE actor    LIKE '__test__%'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM export_runs     WHERE host = '__test__host'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM reviewers       WHERE username LIKE '__test__%'"), silent = TRUE)
  invisible(NULL)
}
# NOT on.exit(). At the TOP LEVEL of an Rscript, on.exit() registers against a
# frame that is not unwound the way a function's is, so it silently never runs —
# this test left two reviewers and seven decisions in the live database before
# that was noticed. The body is a function and cleanup is in finally, which does
# run, including when a check errors part-way through.
cleanup()

run_tests <- function() {

# ── reviewers and login ──────────────────────────────────────────────────────
invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                VALUES ($1,$2,$3,'reviewer')",
          params = list(U1, "Alice Test", sodium::password_store("correct-horse"))))
invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role, active)
                VALUES ($1,$2,$3,'admin', FALSE)",
          params = list(U2, "Bob Test", sodium::password_store("hunter-two"))))

check(!is.null(reviewer_verify(con, U1, "correct-horse")), "a correct password authenticates")
check(is.null(reviewer_verify(con, U1, "wrong")),          "a wrong password does not")
check(is.null(reviewer_verify(con, "__test__nobody", "x")), "an unknown user does not")
check(is.null(reviewer_verify(con, U2, "hunter-two")),      "a DEACTIVATED user cannot log in even with the right password")
r <- reviewer_verify(con, U1, "correct-horse")
check(is.null(r$password_hash), "the hash never leaves reviewer_verify()")
check(identical(r$role, "reviewer"), "the role comes back")

# Timing: an unknown user must not be measurably faster than a wrong password,
# or the uniform error message is undone by the clock.
t_unknown <- system.time(for (i in 1:5) reviewer_verify(con, "__test__nobody", "x"))[["elapsed"]]
t_wrong   <- system.time(for (i in 1:5) reviewer_verify(con, U1, "wrong"))[["elapsed"]]
# The failure mode is unknown-user being FASTER, which leaks that the username
# does not exist. Allow generous jitter but not a 2x gap.
check(t_unknown > t_wrong * 0.6,
      sprintf("unknown-user timing does not leak (%.2fs unknown vs %.2fs wrong)", t_unknown, t_wrong))

# ── norm decisions and latest-wins ───────────────────────────────────────────
id1 <- append_norm_decision(con, "sponsor", RV, "accept", U1, SHA,
                            proposed = "Acme Pharma", final_canonical = "Acme Pharma",
                            n_trials_shown = 42, confidence_shown = 0.62,
                            review_reason = "low confidence", decision_ms = 4200)
check(is.numeric(id1) && id1 > 0, "append_norm_decision returns an id")

lat <- latest_norm_decisions(con, "sponsor")
row <- lat[lat$raw_value == RV, ]
check(nrow(row) == 1 && row$final_canonical == "Acme Pharma", "the decision is the latest")
check(identical(as.integer(row$n_trials_shown), 42L), "impact-at-decision-time is stored")

id2 <- append_norm_decision(con, "sponsor", RV, "edit", U2, SHA,
                            proposed = "Acme Pharma", final_canonical = "ACME Pharmaceuticals GmbH",
                            new_canonical = TRUE)
lat <- latest_norm_decisions(con, "sponsor")
row <- lat[lat$raw_value == RV, ]
check(nrow(row) == 1 && row$final_canonical == "ACME Pharmaceuticals GmbH",
      "a later decision on the same key wins")
check(nrow(dbGetQuery(con, "SELECT 1 FROM norm_decisions WHERE raw_value = $1",
                      params = list(RV))) == 2,
      "the superseded decision is KEPT, not overwritten")

# skip must not suppress a queue row
invisible(append_norm_decision(con, "sponsor", paste0(RV, "-skipme"), "skip", U1, SHA))
lat <- latest_norm_decisions(con, "sponsor")
check(!paste0(RV, "-skipme") %in% lat$raw_value, "a 'skip' does not become a decision")

# disagreement: two reviewers, two different values on one key
dis <- norm_disagreements(con)
check(RV %in% dis$raw_value, "two reviewers disagreeing shows up in the disagreement view")

check(inherits(try(append_norm_decision(con, "sponsor", RV, "not_a_substance", U1, SHA),
                   silent = TRUE), "try-error"),
      "not_a_substance is refused for the sponsor domain")

# ── trial decisions ──────────────────────────────────────────────────────────
invisible(append_trial_decision(con, TID, "phase", "override", U1, SHA,
                      raw_shown = "Therapeutic exploratory (Phase II)",
                      norm_shown = "Phase I", final_value = "Phase II",
                      value_type = "character", decision_ms = 900))
td <- latest_trial_decisions(con, TID)
check(nrow(td) == 1 && td$final_value == "Phase II", "a trial override is stored and read back")
check(identical(td$norm_shown, "Phase I"), "the BEFORE value is retained")
check(inherits(try(append_trial_decision(con, TID, "phase", "override", U1, SHA,
                                         value_type = "nonsense"), silent = TRUE), "try-error"),
      "an unknown value_type is refused")

invisible(append_trial_review(con, TID, "validated", U1, SHA, comment = "checked"))
check(nrow(latest_trial_reviews(con)) >= 1, "a whole-trial sign-off is stored")

# ── export bookkeeping ───────────────────────────────────────────────────────
eid <- export_run_start(con, "sponsor", host = "__test__host")
invisible(export_run_finish(con, eid, "ok", message = "test",
                  max_norm_decision_id = id2, n_sponsor_pins = 1))
lag <- export_lag(con)
check(as.numeric(lag$exported_norm) >= id2, "export high-water mark records what was exported")
check(as.numeric(lag$max_norm) >= as.numeric(lag$exported_norm), "lag is computable")

invisible(admin_audit_log(con, U1, "reset_pw", target = U2, detail = list(reason = "test")))
check(nrow(dbGetQuery(con, "SELECT 1 FROM admin_audit WHERE actor = $1", params = list(U1))) == 1,
      "an admin action is audited")

# ── injection ────────────────────────────────────────────────────────────────
# Not paranoia: raw registry strings genuinely contain apostrophes, and a
# comment box accepts anything at all.
nasty <- "Robert'); DROP TABLE reviewers;-- O'Brien & Co"
invisible(append_norm_decision(con, "substance", nasty, "accept", U1, SHA, final_canonical = nasty))
got <- dbGetQuery(con, "SELECT raw_value FROM norm_decisions WHERE raw_value = $1",
                  params = list(nasty))
check(nrow(got) == 1 && identical(got$raw_value[[1]], nasty), "a quote-laden string round-trips intact")
check(nrow(dbGetQuery(con, "SELECT 1 FROM information_schema.tables
                            WHERE table_schema='public' AND table_name='reviewers'")) == 1,
      "and the reviewers table still exists")

  invisible(NULL)
}

status <- tryCatch({ run_tests(); 0L },
  error = function(e) { cat("\nERROR during tests:", conditionMessage(e), "\n"); 1L },
  finally = { cleanup(); try(dbDisconnect(con), silent = TRUE) })

cat("\n")
if (length(failures) || status != 0L) {
  cat(sprintf("%d check(s) failed\n", length(failures)))
  quit(save = "no", status = 1L)
}
cat("all checks passed (database left clean)\n")
