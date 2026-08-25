# The review sample: representative, reproducible, and actually split.
#
#   Rscript tests/curation_sample.R
#
# The draw is a pure function, so most of this needs no database. The storage
# and per-reviewer lookup need one and skip without it.

suppressPackageStartupMessages({ library(DBI) })
owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)
source("R/util.R"); source("R/store.R"); source("R/sample.R")

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

cache_path <- file.path(owd, "trials_cache_local.rds")
if (!file.exists(cache_path)) {
  message("COULD NOT MEASURE: no trials_cache_local.rds"); quit(save = "no", status = 2L)
}
d <- readRDS(cache_path)
REVS <- c("laurevm", "levih", "rubenvp")

cat("1. shape\n")
p <- draw_review_sample(d, REVS, n = 300L, overlap = 0.10, sample_id = "t-1")
check(length(unique(p$trial_id)) == 300, "exactly N distinct trials are drawn")
check(sum(p$is_overlap) == 30, "10% of them are assigned a second time")
check(nrow(p) == 330, "which is 330 assignment rows")
check(all(p$reviewer %in% REVS), "every row goes to a real reviewer")
spread <- table(p$reviewer)
check(max(spread) - min(spread) <= 2, "the work is split evenly across reviewers")

cat("\n2. the overlap measures something\n")
ov <- p[p$is_overlap, ]; base <- p[!p$is_overlap, ]
m <- merge(ov, base, by = "trial_id", suffixes = c("_a", "_b"))
check(nrow(m) == 30, "every overlap row pairs with an original")
check(all(m$reviewer_a != m$reviewer_b),
      "an overlap trial goes to a DIFFERENT reviewer — the same one measures nothing")

cat("\n3. representative, not merely random\n")
rep <- sample_representativeness(d, p)
worst <- max(abs(rep$diff_pp))
check(worst < 2, sprintf("every stratum is within 2 percentage points (worst %.2f)", worst))
check(all(rep$sample_pct[rep$corpus_pct > 1] > 0),
      "no stratum above 1% of the corpus is missing from the sample")
# Both stratification variables must actually be in play.
check(any(grepl("CTIS", rep$stratum)) && any(grepl("EUCTR", rep$stratum)),
      "both registers appear as strata")
check(length(unique(sub(".* / ", "", rep$stratum))) > 1, "several eras appear as strata")

cat("\n4. reproducible\n")
check(identical(p, draw_review_sample(d, REVS, n = 300L, overlap = 0.10, sample_id = "t-1")),
      "the same sample_id yields byte-identical assignments")
p2 <- draw_review_sample(d, REVS, n = 300L, overlap = 0.10, sample_id = "t-2")
check(!identical(sort(p$trial_id), sort(p2$trial_id)), "a different id yields a different draw")

cat("\n5. edge cases\n")
tiny <- draw_review_sample(d, REVS, n = 10L, overlap = 0, sample_id = "t-3")
check(sum(tiny$is_overlap) == 0, "zero overlap draws no duplicates")
check(length(unique(tiny$trial_id)) == 10, "a small N still draws exactly N")
one <- draw_review_sample(d, REVS[1], n = 20L, overlap = 0.5, sample_id = "t-4")
check(all(one$reviewer == REVS[1]) && sum(one$is_overlap) == 0,
      "with a single reviewer there is no one to double-assign to")
# Every non-empty stratum must be reachable even when N is small.
small <- draw_review_sample(d, REVS, n = 5L, overlap = 0, sample_id = "t-5")
check(nrow(small) >= 5, "a tiny N still covers each stratum at least once")

cat("\n6. storage and per-reviewer lookup\n")
cfg <- curation_db_config()
if (is.null(cfg)) { cat("  SKIP  no CURATION_DB_URL\n") } else {
con <- tryCatch(curation_connect(), error = function(e) NULL)
if (is.null(con)) { cat("  SKIP  database unreachable\n") } else {
  U <- paste0("__test__s", 1:3)
  cleanup <- function() {
    try(dbExecute(con, "DELETE FROM review_sample WHERE reviewer LIKE '__test__%'"), silent = TRUE)
    try(dbExecute(con, "DELETE FROM trial_reviews WHERE reviewer LIKE '__test__%'"), silent = TRUE)
    try(dbExecute(con, "DELETE FROM reviewers WHERE username LIKE '__test__%'"), silent = TRUE)
    invisible(NULL)
  }
  cleanup()
  for (u in U) invisible(dbExecute(con,
    "INSERT INTO reviewers (username, display_name, password_hash, role) VALUES ($1,$1,$2,'reviewer')",
    params = list(u, sodium::password_store("x"))))
  tryCatch({
    pk <- draw_review_sample(d, U, n = 60L, overlap = 0.10, sample_id = "__test__smp")
    n <- sample_store(con, pk)
    check(n == nrow(pk), "the assignment is stored")
    got <- sample_for_reviewer(con, U[1], "__test__smp")
    check(nrow(got) == sum(pk$reviewer == U[1]), "a reviewer sees exactly their own rows")
    check(all(got$reviewer == U[1]), "and nobody else's")
    prog <- sample_progress(con)
    prog <- prog[prog$sample_id == "__test__smp", ]
    check(nrow(prog) == 3 && all(as.numeric(prog$reviewed) == 0), "progress starts at zero")
    invisible(append_trial_review(con, got$trial_id[1], "validated", U[1], strrep("a", 40)))
    prog2 <- sample_progress(con)
    prog2 <- prog2[prog2$sample_id == "__test__smp" & prog2$reviewer == U[1], ]
    check(as.numeric(prog2$reviewed) == 1, "signing a trial off advances that reviewer's progress")
  cat("\n7. undoing a draw\n")
  pk2 <- draw_review_sample(d, U, n = 20L, overlap = 0, sample_id = "__test__smp2")
  sample_store(con, pk2)
  w <- sample_ids_with_work(con)
  w2 <- w[w$sample_id == "__test__smp2", ]
  check(nrow(w2) == 1 && as.numeric(w2$assignments) == 20,
        "a draw is listed with its assignment count")
  check(as.numeric(w2$reviewed) == 0, "and with no work against it yet")

  res <- sample_delete(con, "__test__smp2")
  check(res$deleted == 20, "an untouched draw deletes freely")
  check(nrow(sample_for_reviewer(con, U[1], "__test__smp2")) == 0, "and its rows are gone")

  # A draw with work behind it must NOT be silently erased: sign-offs and the
  # overlap the agreement figures are computed from would be orphaned.
  pk3 <- draw_review_sample(d, U, n = 20L, overlap = 0, sample_id = "__test__smp3")
  sample_store(con, pk3)
  invisible(append_trial_review(con, pk3$trial_id[1], "validated", pk3$reviewer[1], strrep("a", 40)))
  refused <- tryCatch({ sample_delete(con, "__test__smp3"); FALSE },
                      error = function(e) grepl("already been reviewed", conditionMessage(e)))
  check(isTRUE(refused), "a draw with reviews behind it is REFUSED")
  check(nrow(sample_for_reviewer(con, pk3$reviewer[1], "__test__smp3")) > 0,
        "and nothing was deleted")
  forced <- sample_delete(con, "__test__smp3", force = TRUE)
  check(forced$deleted == 20 && forced$reviews_orphaned == 1,
        "forcing works and REPORTS what it orphaned")
  }, finally = { cleanup(); dbDisconnect(con) })
}}

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
