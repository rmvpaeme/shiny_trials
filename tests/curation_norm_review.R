# The normalisation review queue: what a reviewer is shown, and what a decision
# records.
#
#   Rscript tests/curation_norm_review.R
#
# The pure parts (anti-join, live-registry filtering) run with no database and
# no network. The write path needs CURATION_DB_URL and is skipped without one.

suppressPackageStartupMessages({ library(shiny); library(DBI); library(dplyr) })

owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)
source("R/util.R"); source("R/github.R"); source("R/store.R")
source("R/auth.R"); source("R/norm_review.R")
APP_VERSION <- "test"

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

cat("1. the queue a reviewer sees\n")

q <- data.frame(
  raw_value     = c("ACME AG", "Beta Ltd", "Gamma SA", "Delta NV"),
  proposed      = c("Acme", "Beta", "Gamma", "Delta"),
  confidence    = c(0.4, 0.6, 0.5, 0.9),
  n_trials      = c(100L, 5L, 50L, 2L),
  review_reason = c("low confidence", "low confidence", "high impact", "low confidence"),
  stringsAsFactors = FALSE)

# Nothing decided yet
check(nrow(norm_pending(q, NULL, "sponsor")) == 4, "an empty decision set leaves the queue intact")

decided <- data.frame(domain = c("sponsor", "sponsor"),
                      raw_value = c("ACME AG", "Gamma SA"), stringsAsFactors = FALSE)
p <- norm_pending(q, decided, "sponsor")
check(nrow(p) == 2, "decided rows leave the queue")
check(!"ACME AG" %in% p$raw_value, "the specific decided row is gone")
check(all(c("Beta Ltd", "Delta NV") %in% p$raw_value), "undecided rows remain")

# A decision in the OTHER domain must not remove a row from this one. The two
# queues genuinely share raw strings — plenty of sponsors are also substances
# in the register's free text.
other <- data.frame(domain = "substance", raw_value = "Beta Ltd", stringsAsFactors = FALSE)
check(nrow(norm_pending(q, other, "sponsor")) == 4,
      "a substance decision does not clear a sponsor row")

cat("\n2. only live registry entities may be offered\n")

reg <- data.frame(
  entity_id   = c("ent_1", "ent_2", "ent_3"),
  canonical   = c("Acme", "Beta", "Gamma"),
  merged_into = c(NA, "ent_1", ""),
  stringsAsFactors = FALSE)
tmp <- tempfile(fileext = ".csv"); readr::write_csv(reg, tmp)
fake_snap <- list(dir = dirname(tmp), sha = strrep("b", 40))
# point the spec at our temp file
DOMAIN_SPEC$sponsor$registry <- basename(tmp)
live <- norm_registry_load(fake_snap, "sponsor")
check(nrow(live) == 2, "a merged entity is not offered")
check(!"Beta" %in% live$canonical, "the merged-away canonical specifically")
check(all(c("Acme", "Gamma") %in% live$canonical),
      "an empty merged_into counts as live, not merged")

cat("\n3. the domain contract\n")
check(!"not_a_substance" %in% DOMAIN_SPEC$sponsor$actions,
      "not_a_substance is not offered for sponsors")
check("not_a_substance" %in% DOMAIN_SPEC$substance$actions,
      "not_a_substance IS offered for substances")

cat("\n3b. the canonical picker suggests, and cannot invent\n")
regs <- c("Merck", "Merck Sharp & Dohme Animal Health", "Novartis", "Pfizer",
          "GlaxoSmithKline", "Bristol Myers Squibb", "Wyeth", "Biogen")
sg <- function(raw) canonical_suggestions(raw, regs)
check(identical(sg("Merck KGaA")[1], "Merck"),
      "'Merck KGaA' proposes 'Merck' first — the legal form is ignored")
check(identical(sg("Novartis Pharma AG")[1], "Novartis"),
      "'Novartis Pharma AG' proposes 'Novartis'")
check(identical(sg("GlaxoSmithKline AB")[1], "GlaxoSmithKline"),
      "'GlaxoSmithKline AB' proposes 'GlaxoSmithKline'")
check(identical(sg("MERCK SHARP & DOHME LTD")[1], "Merck Sharp & Dohme Animal Health"),
      "more matching words wins over the shorter name")
check(length(sg("Totally Unrelated Institute")) == 0,
      "an unrelated string proposes nothing rather than noise")
# Legal forms match everything, so they must not drive a suggestion.
check(length(sg("GmbH Ltd AG")) == 0,
      "a string of only legal forms proposes nothing")
check(!any(grepl("Biogen", sg("Merck KGaA"))),
      "and suggestions do not include unrelated canonicals")

src <- readLines("R/norm_review.R", warn = FALSE)
check(any(grepl("create = FALSE", src, fixed = TRUE)),
      "the box cannot create a canonical — minting is how near-duplicates began")
check(any(grepl('actionButton(ns("no_canonical")', src, fixed = TRUE)),
      "and offers 'No canonical fits' as its own BUTTON, not a list entry")
check(any(grepl('observeEvent(input$no_canonical, record("reject"))', src, fixed = TRUE)),
      "which records a reject, so E_emit treats it as an intended unassignment")
check(!any(grepl("NO_CANONICAL", src, fixed = TRUE)),
      "and the pseudo-choice is gone from the canonical list entirely")

cat("\n3c. one save button, and the action follows the value\n")
src2 <- readLines("R/norm_review.R", warn = FALSE)
# Two buttons differing only by something already visible in the box above them
# add nothing except the chance to record "accept" while the reviewer had typed
# a correction.
check(!any(grepl('ns("accept")', src2, fixed = TRUE)) &&
      !any(grepl('ns("edit")', src2, fixed = TRUE)),
      "the separate Accept and Save-edit buttons are gone")
check(any(grepl("pending_action", src2, fixed = TRUE)),
      "accept vs edit is derived from whether the value changed")
check(any(grepl('record(a, trimws(input$canonical))', src2, fixed = TRUE)),
      "and the derived action is what gets recorded")
check(any(grepl('output$save_button', src2, fixed = TRUE)),
      "the button label says which it will be, before the click")

# The derivation itself, on the shapes that matter.
decide <- function(proposed, chosen) {
  cn <- trimws(chosen %||% "")
  if (!nzchar(cn)) return(NULL)
  if (identical(cn, trimws(proposed %||% ""))) "accept" else "edit"
}
check(identical(decide("Merck", "Merck"), "accept"),
      "leaving the proposal untouched records an accept")
check(identical(decide("Merck", "Merck KGaA"), "edit"),
      "changing it records an edit")
check(identical(decide("Merck", " Merck "), "accept"),
      "whitespace alone is not a change")
check(is.null(decide("Merck", "")), "an empty box records nothing at all")
check(identical(decide(NA_character_, "Merck"), "edit"),
      "choosing a canonical where the pipeline proposed none is an edit")

cat("\n4. what a decision records\n")
cfg <- curation_db_config()
if (is.null(cfg)) {
  cat("  SKIP  no CURATION_DB_URL — write path not exercised\n")
} else {
  con <- tryCatch(curation_connect(), error = function(e) NULL)
  if (is.null(con)) {
    cat("  SKIP  database unreachable\n")
  } else {
    U <- "__test__nr"
    cleanup <- function() {
      try(dbExecute(con, "DELETE FROM norm_decisions WHERE reviewer LIKE '__test__%'"), silent = TRUE)
      try(dbExecute(con, "DELETE FROM reviewers WHERE username LIKE '__test__%'"), silent = TRUE)
      invisible(NULL)
    }
    cleanup()
    invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                              VALUES ($1,'NR',$2,'reviewer')",
                        params = list(U, sodium::password_store("x"))))
    tryCatch({
      # Everything tab 3 needs must be captured AT DECISION TIME. The pipeline
      # moves on; "what did it propose and how sure was it" is unanswerable
      # afterwards if it is not stored now.
      id <- append_norm_decision(con, "sponsor", "ACME AG", "edit", U, strrep("c", 40),
                                 proposed = "Acme", final_canonical = "ACME Pharmaceuticals",
                                 new_canonical = TRUE, n_trials_shown = 100L,
                                 confidence_shown = 0.4, review_reason = "low confidence",
                                 decision_ms = 12000L, app_version = "test")
      got <- dbGetQuery(con, "SELECT * FROM norm_decisions WHERE decision_id = $1",
                        params = list(id))
      check(identical(got$proposed[[1]], "Acme"), "the BEFORE value is recorded")
      check(identical(got$final_canonical[[1]], "ACME Pharmaceuticals"), "the AFTER value is recorded")
      check(isTRUE(got$new_canonical[[1]]), "minting a new canonical is flagged")
      check(as.numeric(got$n_trials_shown[[1]]) == 100, "impact at decision time is recorded")
      check(abs(as.numeric(got$confidence_shown[[1]]) - 0.4) < 1e-6, "confidence at decision time is recorded")
      check(identical(got$review_reason[[1]], "low confidence"), "why it was queued is recorded")
      check(as.numeric(got$decision_ms[[1]]) == 12000, "time on the card is recorded")
      check(nchar(got$snapshot_sha[[1]]) == 40, "the snapshot is recorded as provenance")

      # And the row must now disappear from the queue the reviewer sees.
      dec <- latest_norm_decisions(con, "sponsor")
      check(nrow(norm_pending(q, dec, "sponsor")) == 3,
            "the decided row leaves the queue immediately, without a nightly")
    }, finally = { cleanup(); dbDisconnect(con) })
  }
}

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
