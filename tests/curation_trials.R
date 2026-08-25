# Trial validation: a correction must reach the right store.
#
#   Rscript tests/curation_trials.R
#
# The routing split is the design, so this is mostly about proving a sponsor
# edit does NOT become a per-trial override and a phase edit does NOT become a
# registry pin. Needs CURATION_DB_URL for the write half.

suppressPackageStartupMessages({ library(shiny); library(DBI); library(dplyr) })

owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)
source("R/util.R"); source("R/field_spec.R"); source("R/github.R")
source("R/store.R"); source("R/auth.R"); source("R/trials.R")
APP_VERSION <- "test"

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

cat("1. the spec routes every editable field somewhere\n")
ed <- Filter(function(f) isTRUE(f$editable), TRIAL_FIELD_SPEC)
check(length(ed) > 10, sprintf("%d editable fields", length(ed)))
check(all(vapply(ed, function(f) !is.na(f$route), logical(1))),
      "every editable field has a route")
reg <- Filter(function(f) f$route %in% c("sponsor_registry", "substance_registry"), ed)
ovr <- Filter(function(f) identical(f$route, "trial_override"), ed)
check(length(reg) == 3, "sponsor, sponsor_type and substance go to a registry")
check(length(ovr) == length(ed) - 3, "everything else is a per-trial override")
check(all(vapply(reg, function(f) is.na(f$override_col), logical(1))),
      "a registry-routed field has NO override column")
check(all(vapply(ovr, function(f) !is.na(f$override_col), logical(1))),
      "an override-routed field names the column it writes")

cat("\n2. value types are declared, not guessed\n")
check(identical(spec_value_type(list(control = "number")), "numeric"), "number -> numeric")
check(identical(spec_value_type(list(control = "date")),   "date"),    "date -> date")
check(identical(spec_value_type(list(control = "bool")),   "logical"), "bool -> logical")
check(identical(spec_value_type(list(control = "text")),   "character"), "text -> character")
# participants_n is numeric in the cache; an override written as character
# would be applied with the wrong cast by attach_trial_overrides().
pf <- Filter(function(f) identical(f$id, "participants"), TRIAL_FIELD_SPEC)[[1]]
check(identical(spec_value_type(pf), "numeric"), "participants is declared numeric")
df <- Filter(function(f) identical(f$id, "start_date"), TRIAL_FIELD_SPEC)[[1]]
check(identical(spec_value_type(df), "date"), "start_date is declared date")

cat("\n3. every editable field warns the reviewer about scope\n")
for (f in ed) {
  scope_ok <- if (f$route %in% c("sponsor_registry", "substance_registry"))
                grepl("EVERY|every trial", f$note) else grepl("This trial only", f$note)
  if (!scope_ok) check(FALSE, sprintf("%s: note does not state the scope (%s)", f$id, f$note))
}
check(all(vapply(ed, function(f)
  if (f$route %in% c("sponsor_registry","substance_registry")) grepl("EVERY|every trial", f$note)
  else grepl("This trial only", f$note), logical(1))),
  "each note states whether the edit hits one trial or all of them")

cat("\n4. a correction lands in the right table\n")
cfg <- curation_db_config()
if (is.null(cfg)) { cat("  SKIP  no CURATION_DB_URL\n") } else {
con <- tryCatch(curation_connect(), error = function(e) NULL)
if (is.null(con)) { cat("  SKIP  database unreachable\n") } else {
  U <- "__test__tv"; TID <- "__test__2021-000123-45-BE"; SHA <- strrep("d", 40)
  cleanup <- function() {
    for (t in c("trial_decisions", "trial_reviews", "norm_decisions"))
      try(dbExecute(con, sprintf("DELETE FROM %s WHERE reviewer LIKE '__test__%%'", t)), silent = TRUE)
    try(dbExecute(con, "DELETE FROM reviewers WHERE username LIKE '__test__%'"), silent = TRUE)
    invisible(NULL)
  }
  cleanup()
  invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                            VALUES ($1,'TV',$2,'reviewer')",
                      params = list(U, sodium::password_store("x"))))
  tryCatch({
    # A per-trial field
    append_trial_decision(con, TID, "phase", "override", U, SHA,
                          raw_shown = "Therapeutic exploratory (Phase II)",
                          norm_shown = "Phase I", final_value = "Phase II",
                          value_type = "character")
    # A registry field, keyed on the RAW STRING and not on the trial
    append_norm_decision(con, "sponsor", "NOVARTIS PHARMA AG", "edit", U, SHA,
                         proposed = "Novartis", final_canonical = "Novartis Pharma AG")

    td <- dbGetQuery(con, "SELECT * FROM trial_decisions WHERE reviewer = $1", params = list(U))
    nd <- dbGetQuery(con, "SELECT * FROM norm_decisions  WHERE reviewer = $1", params = list(U))

    check(nrow(td) == 1 && td$field_id[[1]] == "phase",
          "a phase edit becomes a TRIAL decision")
    check(nrow(nd) == 1 && nd$raw_value[[1]] == "NOVARTIS PHARMA AG",
          "a sponsor edit becomes a NORM decision keyed on the raw string")
    check(!"sponsor" %in% td$field_id,
          "the sponsor edit did NOT also become a per-trial override")
    check(is.na(nd$final_entity_id[[1]]) || nzchar(nd$final_entity_id[[1]]),
          "the norm decision carries an entity slot")
    check(identical(td$norm_shown[[1]], "Phase I"),
          "the trial decision keeps the before value")

    # The two live in different tables and neither leaks into the other's key.
    check(!any(grepl("__test__2021", nd$raw_value)),
          "no trial id leaked into a registry decision's key")
  }, finally = { cleanup(); dbDisconnect(con) })
}}

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
