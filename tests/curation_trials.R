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
check(length(reg) == 2, "sponsor and substance go to a registry")
check(length(ovr) == length(ed) - 2, "everything else is a per-trial override")
check(all(vapply(reg, function(f) is.na(f$override_col), logical(1))),
      "a registry-routed field has NO override column")
check(all(vapply(ovr, function(f) !is.na(f$override_col), logical(1))),
      "an override-routed field names the column it writes")

cat("\n1b. the widget matches where the decision goes\n")
# "Sponsor type > edit shows all sponsors, not the type."
#
# The editor picked its choices by ROUTE, so a registry-routed field drawn as a
# plain select had its two options replaced by 6,954 sponsor canonicals. Worse,
# saving it wrote final_canonical = "academic" and export.R mints any
# final_canonical it cannot match — a registry sponsor named "academic".
for (f in TRIAL_FIELD_SPEC) {
  if (f$route %in% c("sponsor_registry", "substance_registry")) {
    check(identical(f$control, "entity"),
          sprintf("%s is registry-routed, so it must be an entity picker (is '%s')",
                  f$label, f$control))
  }
  if (identical(f$control, "entity")) {
    check(f$route %in% c("sponsor_registry", "substance_registry"),
          sprintf("%s is an entity picker, so it must be registry-routed", f$label))
  }
}
src0 <- readLines("R/trials.R", warn = FALSE)
check(any(grepl('!identical(f$control, "entity")', src0, fixed = TRUE)),
      "and the editor gates the registry choices on the CONTROL, not the route")

# sponsor_type specifically: the pipeline resets it from the register's own
# commercial flag every run, so an edit could never stick.
st <- Filter(function(f) f$id == "sponsor_type", TRIAL_FIELD_SPEC)[[1]]
check(!isTRUE(st$editable),
      "sponsor type is not editable — E_emit resets it from the commercial flag")
check(is.na(st$route), "and it routes nowhere, so it cannot reach the registry")

cat("\n1c. MedDRA is a list, not a free-text box\n")
# 29 organ classes and 4,076 terms are already in use. A text box invites a
# 4,077th spelling of one that exists, which is the problem the substance and
# sponsor registries were built to solve.
for (fid in c("organ_class", "meddra_term")) {
  f <- Filter(function(x) x$id == fid, TRIAL_FIELD_SPEC)[[1]]
  check(identical(f$control, "select"), sprintf("%s is a dropdown", f$label))
  check(isTRUE(f$vocab_from_cache),
        sprintf("%s draws its choices from the values already in use", f$label))
}
src1 <- readLines("R/trials.R", warn = FALSE)
check(any(grepl("cache_vocab", src1, fixed = TRUE)),
      "the editor resolves those choices from the cache")
check(any(grepl("server = TRUE", src1, fixed = TRUE)),
      "server-side, because 4,076 terms must not ship to the browser")
check(!any(grepl("create = TRUE", src1, fixed = TRUE)),
      "and no editor box can invent a value")

cat("\n1d. reviewed trials are out of the way by default\n")
check(any(grepl('ns("only_undecided"), "Hide trials I have reviewed",\n                             value = TRUE', paste(src1, collapse = "\n"), fixed = TRUE)) ||
      any(grepl('value = TRUE', grep("only_undecided", src1, value = TRUE), fixed = TRUE)) ||
      any(grepl("only_undecided", src1, fixed = TRUE)) &&
      any(grepl("value = TRUE", src1[grep("only_undecided", src1) + 1], fixed = TRUE)),
      "a reviewer sees what is left, not what they have already done")

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
    # scope = "all": this test has no database, so "my assigned sample" is
    # correctly empty and there would be no row to select.
    session$setInputs(`trials-scope` = "all", `trials-search` = "",
                      `trials-register` = "All", `trials-only_undecided` = FALSE)
    session$setInputs(`trials-table_rows_selected` = 1L)
    h <- paste(as.character(output$`trials-detail`), collapse = "")
    check(grepl("What the register said", h) && grepl("What the app shows", h),
          "the register's value and the app's are shown side by side")
    check(!grepl("Highlighted rows", h, fixed = TRUE),
          "no highlight instruction — the feature was removed on review")
    check(!grepl("fff8e1", h, fixed = TRUE),
          "and no row tinting remains")
    for (jargon in c("normalised", "pipeline", "registry", "canonical"))
      check(!grepl(jargon, h, ignore.case = TRUE),
            sprintf("the table uses no jargon: '%s' does not appear", jargon))
    # Count the actual links by their input id. ">edit<" also matches the word
    # "edit" in the instruction sentence above the table.
    n_edit <- length(gregexpr('id="trials-edit_', h, fixed = TRUE)[[1]])
    check(n_edit == length(ed),
          sprintf("every editable field is clickable (%d links, %d editable fields)", n_edit, length(ed)))
    n_fixed <- length(TRIAL_FIELD_SPEC) - length(ed)
    check(length(gregexpr("text-muted small\">—<", h)[[1]]) == n_fixed,
          sprintf("the %d non-editable fields are NOT clickable", n_fixed))
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
check(identical(raw_txt, "Bristol Myers Squibb"),
      "an unmatched sponsor is shown PLAIN — the Processing column says the rest")
check(grepl("human", fmt_sponsor(mk(sponsor_label = "GSK", sponsor_label_source = "human"))),
      "a human decision is marked")
check(identical(fmt_status(mk(status = "Completed", status_raw = "Completed")), "Completed"),
      "status does not repeat itself when category and wording agree")
check(identical(fmt_status(mk(status = "Administrative", status_raw = "Gb - no longer in eu/eea")),
                "Administrative"),
      "status shows the grouped value alone — the register's wording is in the column beside it")

cat("\n8. the Processing column classifies what the pipeline did\n")
# The app exists to validate the processing, and neither the raw nor the
# normalised value says what happened between them.
cl <- function(...) Filter(function(x) x$id == "phase", field_rows(data.frame(..., stringsAsFactors = FALSE)))[[1]]$change
check(identical(cl(phase = "Phase II", phase_raw = "Therapeutic exploratory (Phase II)"), "changed"),
      "a value the pipeline rewrote reads 'changed' — the row worth checking")
check(identical(cl(phase = "Phase II", phase_raw = "Phase II"), "unchanged"),
      "a value it agreed with reads 'unchanged'")
check(identical(cl(phase = "Phase II", phase_raw = NA_character_), "derived"),
      "a value with no raw counterpart reads 'derived', not 'missing data'")
check(identical(cl(phase = NA_character_, phase_raw = "Phase II"), "dropped"),
      "a raw value the pipeline discarded reads 'dropped'")
check(identical(cl(phase = "Phase II"), "old snapshot"),
      "a column absent from the CACHE reads 'old snapshot', not 'no raw' — the
      register sent a value and this build simply predates the column")
# Case and whitespace must not read as a change; they are not one.
check(identical(cl(phase = "Phase II", phase_raw = " phase ii "), "unchanged"),
      "case and padding alone do not count as a change")
sp <- Filter(function(f) f$id == "sponsor", TRIAL_FIELD_SPEC)[[1]]
check(!is.na(sp$pipeline) && nzchar(sp$pipeline),
      "each field says WHICH pipeline stage processed it")

cat("\n8b. every field says where its value came from\n")
# "The data has to come from somewhere." Four fields showed a bare dash in the
# register column purely because the spec never named their source, even though
# the columns were sitting in the cache: start date, decision date, trial end
# date and register. A dash must mean the register did not supply it, never
# that nobody wired it up.
no_src <- Filter(function(f) !length(f$raw_cols) && is.null(f$no_source), TRIAL_FIELD_SPEC)
check(length(no_src) == 0,
      sprintf("every field declares a source or says why it has none%s",
              if (length(no_src)) paste0(" (missing: ",
                paste(vapply(no_src, function(f) f$id, character(1)), collapse = ", "), ")") else ""))
cache_cols <- names(readRDS(cache_path))
bad_src <- unlist(lapply(TRIAL_FIELD_SPEC, function(f)
  f$raw_cols[!f$raw_cols %in% cache_cols]))
check(length(bad_src) == 0,
      sprintf("and every declared source exists in the cache%s",
              if (length(bad_src)) paste0(" (missing: ", paste(bad_src, collapse=", "), ")") else ""))
src2b <- readLines("R/trials.R", warn = FALSE)
check(any(grepl("x$no_source", src2b, fixed = TRUE)),
      "and the reason is rendered, not just stored")

cat("\n9. a missing COLUMN is not the same as a missing VALUE\n")
# Both render as NA, and a reviewer acts differently on each: "the register
# sent nothing" is a fact about the trial; "not in this snapshot" is a fact
# about the cache. The deployed v0.21 cache lacks five _raw columns, so five
# rows read as empty on every trial unless this is distinguished.
full  <- data.frame(phase = "Phase II", phase_raw = "Therapeutic exploratory (Phase II)",
                    stringsAsFactors = FALSE)
blank <- data.frame(phase = "Phase II", phase_raw = NA_character_, stringsAsFactors = FALSE)
older <- data.frame(phase = "Phase II", stringsAsFactors = FALSE)   # no phase_raw at all
gs <- function(d) Filter(function(x) x$id == "phase", field_rows(d))[[1]]$raw_status
check(identical(gs(full),  "present"), "a populated raw column reads 'present'")
check(identical(gs(blank), "empty"),   "an empty value in an EXISTING column reads 'empty'")
check(identical(gs(older), "absent"),  "a column missing from the cache reads 'absent'")
dur_row <- Filter(function(x) x$id == "trial_duration", field_rows(full))[[1]]
check(identical(dur_row$raw_status, "none"),
      "a computed field reads 'none', not 'absent'")
check(!is.na(dur_row$no_source),
      "and says what it was computed from, so the dash is not read as missing data")
src2 <- readLines("R/trials.R", warn = FALSE)
check(any(grepl("missing_sources", src2, fixed = TRUE)),
      "a data file older than the spec is reported ONCE, not on every affected row")

cat("\nsign-off lands on the trial the reviewer opened\n")
# The review log showed one comment on three or four ADJACENT trials within two
# seconds: the selection was a row number, a sign-off removed the trial from
# the list, and the next click recorded the neighbour that slid into its place.
local({
  source("R/sample.R")
  cache <- data.frame(`_id` = c("A", "B", "C"), CT_number = c("A", "B", "C"),
                      Full_title = "t", sponsor_label = "s", substance_label = "x",
                      register = "EUCTR", check.names = FALSE)
  signed <- character()
  env <- environment(trials_server)
  old <- list(a = env$append_trial_review, l = env$my_reviewed_trials,
              c = env$sample_choices_for_reviewer, s = env$sample_for_reviewer)
  env$append_trial_review <- function(con, trial_id, ...) { signed <<- c(signed, trial_id); 1 }
  env$my_reviewed_trials <- function(con, username) signed
  env$sample_choices_for_reviewer <- function(...) NULL
  env$sample_for_reviewer <- function(...) NULL
  on.exit({ env$append_trial_review <- old$a; env$my_reviewed_trials <- old$l
            env$sample_choices_for_reviewer <- old$c; env$sample_for_reviewer <- old$s })
  shiny::testServer(trials_server,
    args = list(db = list(), session_user = function() list(username = "ann"), cache = cache), {
      session$setInputs(scope = "all", search = "", register = "All", only_undecided = TRUE)
      session$setInputs(table_rows_selected = 1)
      check(identical(row()$`_id`, "A"), "the opened trial is the selected one")
      session$setInputs(comment = "note", flag = 1)
      check(is.null(row()), "after a sign-off nothing is selected, not the next trial")
      session$setInputs(flag = 2)
      check(identical(signed, "A"), "a rapid second click signs off nothing else")
    })
})

cat("\nthe flagged list is where a flag goes\n")
local({
  source("R/sample.R")
  cache <- data.frame(`_id` = c("A", "B", "C"), CT_number = c("A", "B", "C"),
                      Full_title = "t", sponsor_label = "s", substance_label = "x",
                      register = "EUCTR", check.names = FALSE)
  reviews <- data.frame(trial_id = "B", status = "flagged", reviewer = "ann",
                        comment = "end date wrong", stringsAsFactors = FALSE)
  env <- environment(trials_server)
  keep <- mget(c("append_trial_review", "my_reviewed_trials", "open_trial_flags",
                 "sample_choices_for_reviewer", "sample_for_reviewer"), envir = env)
  env$append_trial_review <- function(con, trial_id, status, reviewer, ...) {
    reviews <<- rbind(reviews, data.frame(trial_id = trial_id, status = status,
      reviewer = reviewer, comment = NA, stringsAsFactors = FALSE)); 1 }
  env$my_reviewed_trials <- function(con, username) reviews$trial_id[reviews$reviewer == username]
  env$open_trial_flags <- function(con) {
    last <- reviews[!duplicated(reviews$trial_id, fromLast = TRUE), ]
    last[last$status == "flagged", c("trial_id", "reviewer", "comment")] }
  env$sample_choices_for_reviewer <- function(...) NULL
  env$sample_for_reviewer <- function(...) NULL
  on.exit(for (n in names(keep)) assign(n, keep[[n]], envir = env))
  shiny::testServer(trials_server,
    args = list(db = list(), session_user = function() list(username = "bob"), cache = cache), {
      session$setInputs(scope = "flagged", search = "", register = "All", only_undecided = TRUE)
      check(identical(filtered()$`_id`, "B"), "another reviewer's flag is listed for me")
      session$setInputs(table_rows_selected = 1)
      check(identical(row()$`_id`, "B"), "and opens")
      session$setInputs(validate = 1)
      check(nrow(filtered()) == 0, "validating it takes it off the flagged list")
    })
})

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
