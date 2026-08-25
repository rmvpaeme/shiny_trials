# The statistics queries, against a real Postgres with seeded decisions.
#
#   Rscript tests/curation_stats.R
#
# Every metric here is SQL, and SQL that returns a plausible-looking wrong
# number is the failure mode — so each is checked against decisions whose
# expected answer is known by construction.

suppressPackageStartupMessages({ library(shiny); library(DBI) })
owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)
source("R/util.R"); source("R/store.R"); source("R/auth.R"); source("R/stats.R")

cfg <- curation_db_config()
if (is.null(cfg)) { message("COULD NOT MEASURE: CURATION_DB_URL is not set."); quit(save="no", status=2L) }
con <- tryCatch(curation_connect(), error = function(e) NULL)
if (is.null(con)) { message("COULD NOT MEASURE: database unreachable"); quit(save="no", status=2L) }

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

A <- "__test__sa"; B <- "__test__sb"; SHA <- strrep("e", 40)
cleanup <- function() {
  for (t in c("norm_decisions", "trial_decisions", "trial_reviews"))
    try(dbExecute(con, sprintf("DELETE FROM %s WHERE reviewer LIKE '__test__%%'", t)), silent = TRUE)
  try(dbExecute(con, "DELETE FROM export_runs WHERE host = '__test__h'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM reviewers WHERE username LIKE '__test__%'"), silent = TRUE)
  invisible(NULL)
}

run <- function() {
  cleanup()
  for (u in c(A, B))
    invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                              VALUES ($1,$1,$2,'reviewer')",
                        params = list(u, sodium::password_store("x"))))

  # A: 2 accepts, 1 edit. B: 1 edit on the SAME key as A's edit but different
  # value -> a disagreement by construction.
  invisible(append_norm_decision(con, "sponsor", "__t__K1", "accept", A, SHA,
                                 proposed = "P1", final_canonical = "P1",
                                 review_reason = "low confidence", confidence_shown = 0.4,
                                 decision_ms = 1000))
  invisible(append_norm_decision(con, "sponsor", "__t__K2", "accept", A, SHA,
                                 proposed = "P2", final_canonical = "P2",
                                 review_reason = "low confidence", confidence_shown = 0.5,
                                 decision_ms = 3000))
  invisible(append_norm_decision(con, "sponsor", "__t__K3", "edit", A, SHA,
                                 proposed = "P3", final_canonical = "A-choice",
                                 new_canonical = TRUE,
                                 review_reason = "high impact", confidence_shown = 0.85,
                                 decision_ms = 5000))
  invisible(append_norm_decision(con, "sponsor", "__t__K3", "edit", B, SHA,
                                 proposed = "P3", final_canonical = "B-choice",
                                 review_reason = "high impact", confidence_shown = 0.85,
                                 decision_ms = 7000))
  invisible(append_norm_decision(con, "sponsor", "__t__K4", "skip", A, SHA))

  cat("1. totals\n")
  t <- metrics_totals(con)
  check(as.numeric(t$norm_all) == 4, "skips are excluded from the decision count")
  check(as.numeric(t$norm_keys) == 3, "latest-wins collapses the two decisions on K3")

  cat("\n2. by reviewer\n")
  br <- metrics_by_reviewer(con)
  ra <- br[br$reviewer == A, ]; rb <- br[br$reviewer == B, ]
  check(as.numeric(ra$decisions) == 3, "A's skip is not counted")
  check(as.numeric(ra$accepted) == 2, "A's accepts")
  check(as.numeric(ra$changed) == 1, "A's edit")
  check(as.numeric(rb$decisions) == 1, "B has one decision")
  # median of 1000, 3000, 5000 = 3000
  check(abs(as.numeric(ra$median_ms) - 3000) < 1, "median seconds-per-decision is the MEDIAN, not the mean")

  cat("\n3. disagreements\n")
  d <- norm_disagreements(con)
  d <- d[d$raw_value == "__t__K3", ]
  check(nrow(d) == 1, "the two-reviewer conflict is reported")
  check(as.numeric(d$n_reviewers) == 2, "both reviewers named")
  check(as.numeric(d$n_distinct_values) == 2, "both distinct answers counted")
  # A key decided twice by the SAME reviewer is not a disagreement.
  invisible(append_norm_decision(con, "sponsor", "__t__K5", "edit", A, SHA, final_canonical = "x1"))
  invisible(append_norm_decision(con, "sponsor", "__t__K5", "edit", A, SHA, final_canonical = "x2"))
  check(!"__t__K5" %in% norm_disagreements(con)$raw_value,
        "one reviewer changing their own mind is NOT a disagreement")

  cat("\n4. by reason and confidence\n")
  br2 <- metrics_by_reason(con)
  hi <- br2[br2$review_reason == "high impact", ]
  check(as.numeric(hi$changed) == 2, "both edits land in the high-impact bucket")
  check(abs(as.numeric(hi$change_rate) - 1) < 1e-9, "a bucket where everything was changed reads 100%")
  lo <- br2[br2$review_reason == "low confidence", ]
  check(as.numeric(lo$accepted) == 2 && abs(as.numeric(lo$change_rate)) < 1e-9,
        "a bucket where everything was accepted reads 0%")
  cb <- metrics_by_confidence(con)
  check(nrow(cb) >= 2, "confidence bands are populated")

  cat("\n5. new canonicals\n")
  nc <- metrics_new_canonicals(con)
  check(sum(nc$raw_value == "__t__K3") == 1, "the minted canonical is listed")
  check("A-choice" %in% nc$final_canonical, "with the name that was created")

  cat("\n6. per-field change rate\n")
  for (i in 1:4) invisible(append_trial_review(con, paste0("__t__T", i), "validated", A, SHA))
  invisible(append_trial_decision(con, "__t__T1", "phase", "override", A, SHA,
                                  norm_shown = "Phase I", final_value = "Phase II"))
  invisible(append_trial_decision(con, "__t__T2", "phase", "override", A, SHA,
                                  norm_shown = "Phase I", final_value = "Phase III"))
  invisible(append_trial_decision(con, "__t__T3", "meddra_term", "override", A, SHA,
                                  norm_shown = "x", final_value = "y"))
  fr <- metrics_field_change_rate(con, min_n = 1L)
  ph <- fr[fr$field_id == "phase", ]
  check(as.numeric(ph$n_changed) == 2, "phase was changed on 2 trials")
  check(as.numeric(ph$n_trials_reviewed) == 4, "denominator is trials SIGNED OFF, not decisions")
  check(abs(as.numeric(ph$change_rate) - 0.5) < 1e-9, "2 of 4 reads as 50%")
  md <- fr[fr$field_id == "meddra_term", ]
  check(abs(as.numeric(md$change_rate) - 0.25) < 1e-9, "1 of 4 reads as 25%")
  check(which(fr$field_id == "phase") < which(fr$field_id == "meddra_term"),
        "the least trustworthy field sorts first")

  cat("\n7. retirable overrides\n")
  invisible(append_trial_decision(con, "__t__T4", "status", "override", A, SHA,
                                  norm_shown = "Ongoing", final_value = "Ongoing"))
  st <- metrics_stale_overrides(con)
  check(any(st$trial_id == "__t__T4"), "an override that now equals the pipeline is flagged")
  check(!any(st$trial_id == "__t__T1"), "one that still differs is NOT flagged")

  cat("\n8. pipeline lag\n")
  eid <- export_run_start(con, "sponsor", host = "__test__h")
  mx <- as.numeric(dbGetQuery(con, "SELECT max(decision_id) m FROM norm_decisions")$m)
  export_run_finish(con, eid, "ok", max_norm_decision_id = mx)
  lag <- export_lag(con)
  check(as.numeric(lag$exported_norm) == mx, "the high-water mark is recorded")
  invisible(append_norm_decision(con, "sponsor", "__t__K9", "accept", A, SHA))
  lag2 <- export_lag(con)
  check(as.numeric(lag2$max_norm) > as.numeric(lag2$exported_norm),
        "a decision made after the export shows as not-yet-live")
  invisible(NULL)
}

status <- tryCatch({ run(); 0L },
  error = function(e) { cat("\nERROR:", conditionMessage(e), "\n"); 1L },
  finally = { cleanup(); try(dbDisconnect(con), silent = TRUE) })

cat("\n")
if (length(failures) || status != 0L) {
  cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L)
}
cat("all checks passed (database left clean)\n")
