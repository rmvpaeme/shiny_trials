# Trial validation: a correction must reach the right store.
#
#   Rscript tests/curation_trials.R
#
# The routing split is the design, so this is mostly about proving a sponsor
# edit does NOT become a per-trial override and a phase edit does NOT become a
# registry pin. Needs CURATION_DB_URL for the write half.

suppressPackageStartupMessages({ library(shiny); library(DBI); library(dplyr); library(DT); library(bslib) })

owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)
source("R/util.R"); source("R/field_spec.R"); source("R/github.R")
source("R/store.R"); source("R/auth.R"); source("R/norm_review.R"); source("R/trials.R")
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

cat("\n5. the overview renders as a readable table, not a form\n")
# Defaults to the gitignored local build (rebuild with:
#   DB_PATH=data/trials_small.sqlite CACHE_PATH=trials_cache_local.rds Rscript -e 'source("app.R")')
cache_path <- Sys.getenv("CACHE_TEST", unset = file.path(owd, "trials_cache_local.rds"))
if (!nzchar(cache_path) || !file.exists(cache_path)) {
  cat("  SKIP  set CACHE_TEST to a current trials cache to exercise the render\n")
} else {
  cache <- readRDS(cache_path)
  testServer(function(input, output, session) {
    auth_init(session)
    auth_login(session, list(username = "u", display_name = "U", role = "reviewer", active = TRUE))
    trials_server("trials", db = NULL, session_user = reactive(auth_user(session)),
                  cache = cache, snapshot = function() list(sha = strrep("f", 40)))
  }, {
    session$setInputs(`trials-search` = "", `trials-register` = "All",
                      `trials-only_undecided` = FALSE)
    session$setInputs(`trials-table_rows_selected` = 1L)
    h <- paste(as.character(output$`trials-detail`), collapse = "")
    check(grepl("Registry raw / source value", h) && grepl("Normalised dashboard value", h),
          "raw and normalised are shown side by side, as in the dashboard")
    n_edit <- length(gregexpr(">edit<", h)[[1]])
    check(n_edit == length(ed),
          sprintf("every editable field is clickable (%d links, %d editable fields)", n_edit, length(ed)))
    check(length(gregexpr("text-muted small\">—<", h)[[1]]) == 3,
          "the three derived fields are NOT clickable")
    for (lbl in c("Sponsor", "Phase", "Age group", "Orphan designation", "Countries"))
      check(grepl(paste0(">", lbl, "<"), h), sprintf("the %s row is present", lbl))
  })
}

cat("\n6. sponsor and substance edits offer the existing canonicals\n")
ent <- Filter(function(f) identical(f$control, "entity"), TRIAL_FIELD_SPEC)
check(length(ent) == 2, "sponsor and substance use the entity control")
check(all(vapply(ent, function(f) f$route %in% c("sponsor_registry","substance_registry"), logical(1))),
      "both entity fields are registry-routed")
# The bug: the editor's switch() had NO entity branch, so both fell through to a
# plain text box. A reviewer typed canonicals free-hand against no list, which is
# the surest way to create the near-duplicates the registry already suffers from.
src <- readLines("R/trials.R", warn = FALSE)
check(any(grepl("entity = shiny::selectizeInput", src, fixed = TRUE)),
      "the editor has an entity branch, not a text fallback")
check(any(grepl("updateSelectizeInput", src, fixed = TRUE)),
      "choices are populated server-side, after the modal exists")
check(any(grepl("new_canonical_warning", src, fixed = TRUE)),
      "minting a canonical is warned about before the save")
reg2 <- data.frame(entity_id = c("e1","e2"), canonical = c("Live Co","Merged Co"),
                   merged_into = c(NA, "e1"), stringsAsFactors = FALSE)
tmp2 <- tempfile(fileext = ".csv"); readr::write_csv(reg2, tmp2)
DOMAIN_SPEC$sponsor$registry <- basename(tmp2)
check(identical(norm_registry_load(list(dir = dirname(tmp2)), "sponsor")$canonical, "Live Co"),
      "the picker pool excludes merged-away canonicals")

cat("\n7. the normalised column shows the answer, not a restatement of the raw\n")
mk <- function(...) { r <- data.frame(..., stringsAsFactors = FALSE); r }
check(identical(fmt_sponsor(mk(sponsor_label = "GSK", sponsor_label_source = "pipeline")), "GSK"),
      "a pipeline label is shown plain, with no '(final label: ...)' echo")
# Nearly half of all trials take this path and most of those names are already
# clean, so it must read as a fact and never as a warning.
raw_txt <- fmt_sponsor(mk(sponsor_label = "Bristol Myers Squibb", sponsor_label_source = "raw"))
check(grepl("not in the sponsor registry", raw_txt, fixed = TRUE),
      "a raw fallback says it is not registry-backed")
check(!grepl("\u26a0", raw_txt) && !grepl("unresolved", raw_txt),
      "and does NOT flag it as an error — 47% of trials take this path")
check(startsWith(raw_txt, "Bristol Myers Squibb"),
      "the label itself still leads")
check(grepl("human", fmt_sponsor(mk(sponsor_label = "GSK", sponsor_label_source = "human"))),
      "a human decision is marked")
check(identical(fmt_status(mk(status = "Completed", status_raw = "Completed")), "Completed"),
      "status does not repeat itself when category and wording agree")
check(grepl("register:", fmt_status(mk(status = "Administrative", status_raw = "Gb - no longer in eu/eea"))),
      "the register's wording is shown only when it differs")

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
