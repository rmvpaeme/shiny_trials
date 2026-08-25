# The admin panel: privileged writes, their refusals, and the audit trail.
#
#   Rscript tests/curation_admin.R
#
# Drives the module server directly — the position a client with an open
# websocket is in, with no UI to hide anything.

suppressPackageStartupMessages({ library(shiny); library(DBI); library(DT); library(bslib) })
owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)
source("R/util.R"); source("R/github.R"); source("R/store.R")
source("R/auth.R"); source("R/admin.R")

cfg <- curation_db_config()
if (is.null(cfg)) { message("COULD NOT MEASURE: CURATION_DB_URL is not set."); quit(save="no", status=2L) }
con <- tryCatch(curation_connect(), error = function(e) NULL)
if (is.null(con)) { message("COULD NOT MEASURE: database unreachable"); quit(save="no", status=2L) }

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}
blocked <- function(expr) {
  v <- tryCatch(force(expr), error = function(e) structure(list(), class = "__b__"))
  inherits(v, "__b__") || is.null(v)
}

ADM <- "__test__adm1"; ADM2 <- "__test__adm2"; REV <- "__test__rev1"
cleanup <- function() {
  try(dbExecute(con, "DELETE FROM admin_audit WHERE actor LIKE '__test__%'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM reviewers WHERE username LIKE '__test__%'"), silent = TRUE)
  invisible(NULL)
}

mk_server <- function() function(input, output, session) {
  auth_init(session); auth_watch(session)
  observeEvent(input$login, {
    r <- reviewer_get(con, input$login_as)
    auth_login(session, r)
  })
  admin_server("admin", db = con, session_user = reactive(auth_user(session)),
               snapshot = function() list(sha = strrep("a", 40), fetched_at = Sys.time(),
                                          files = character(), missing_optional = character()),
               refresh = function() invisible(NULL))
}

run <- function() {
  cleanup()
  invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                            VALUES ($1,'A1',$2,'admin')", params = list(ADM, sodium::password_store("x"))))
  invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                            VALUES ($1,'R1',$2,'reviewer')", params = list(REV, sodium::password_store("x"))))

  cat("1. a reviewer gets nothing from the admin module\n")
  testServer(mk_server(), {
    session$setInputs(login_as = REV, login = 1)
    check(identical(auth_user(session)$role, "reviewer"), "signed in as a reviewer")
    check(blocked(output$`admin-accounts`), "the accounts table refuses to render")
    check(blocked(output$`admin-audit`),    "the audit table refuses to render")
    check(blocked(output$`admin-lag`),      "export lag refuses to render")
    before <- nrow(admin_audit_recent(con))
    # Forge every privileged input a reviewer could reach for.
    session$setInputs(`admin-pw_user` = ADM, `admin-pw_new` = "aaaaaaaaaaaa",
                      `admin-pw_confirm` = "aaaaaaaaaaaa", `admin-pw_go` = 1)
    session$setInputs(`admin-new_user` = "__test__forged", `admin-new_name` = "X",
                      `admin-new_role` = "admin", `admin-new_pw` = "aaaaaaaaaaaa",
                      `admin-new_go` = 1)
    session$setInputs(`admin-act_user` = ADM, `admin-act_off` = 1)
    check(is.null(reviewer_get(con, "__test__forged")),
          "a forged create-user input creates NOTHING")
    check(!is.null(reviewer_verify(con, ADM, "x")),
          "a forged password reset does NOT change the admin's password")
    check(isTRUE(reviewer_get(con, ADM)$active),
          "a forged deactivate does NOT disable the admin")
    check(nrow(admin_audit_recent(con)) == before,
          "and none of it reached the audit log, because none of it ran")
  })

  cat("\n2. an admin can do the work\n")
  testServer(mk_server(), {
    session$setInputs(login_as = ADM, login = 1)
    check(!blocked(output$`admin-accounts`), "the accounts table renders for an admin")

    session$setInputs(`admin-new_user` = REV, `admin-new_name` = "dup",
                      `admin-new_pw` = "aaaaaaaaaaaa", `admin-new_role` = "reviewer",
                      `admin-new_go` = 1)
    check(nrow(dbGetQuery(con, "SELECT 1 FROM admin_audit WHERE action='create_user_refused'")) >= 1,
          "a duplicate username is refused AND the refusal is audited")

    session$setInputs(`admin-new_user` = "__test__new1", `admin-new_name` = "New One",
                      `admin-new_pw` = "short", `admin-new_role` = "reviewer",
                      `admin-new_go` = 2)
    check(is.null(reviewer_get(con, "__test__new1")), "a short password is refused")

    session$setInputs(`admin-new_user` = "__test__new1", `admin-new_pw` = "abcdefghijkl",
                      `admin-new_go` = 3)
    check(!is.null(reviewer_get(con, "__test__new1")), "a valid account is created")
    check(isTRUE(reviewer_get(con, "__test__new1")$must_change_pw),
          "and is flagged to change its password")

    session$setInputs(`admin-pw_user` = REV, `admin-pw_new` = "newpassword12",
                      `admin-pw_confirm` = "mismatched123", `admin-pw_go` = 1)
    check(!is.null(reviewer_verify(con, REV, "x")),
          "mismatched confirmation does not change the password")

    session$setInputs(`admin-pw_new` = "newpassword12", `admin-pw_confirm` = "newpassword12",
                      `admin-pw_go` = 2)
    check(is.null(reviewer_verify(con, REV, "x")), "the old password stops working")
    check(!is.null(reviewer_verify(con, REV, "newpassword12")), "the new one works")
    aud <- dbGetQuery(con, "SELECT * FROM admin_audit WHERE action = 'reset_pw'")
    check(nrow(aud) >= 1, "the reset is audited")
    check(!any(grepl("newpassword12", paste(unlist(aud), collapse = " "))),
          "and the audit does NOT contain the password")
  })

  cat("\n3. the two refusals that would lock everyone out\n")
  testServer(mk_server(), {
    session$setInputs(login_as = ADM, login = 1)
    session$setInputs(`admin-act_user` = ADM, `admin-act_off` = 1)
    check(isTRUE(reviewer_get(con, ADM)$active),
          "an admin cannot deactivate their OWN account")
    check(nrow(dbGetQuery(con,
      "SELECT 1 FROM admin_audit WHERE action='deactivate_refused' AND detail->>'reason'='self'")) >= 1,
      "the self-lockout attempt is audited")
  })
  # With a second admin present, deactivating the first is allowed; with only
  # one left it must be refused.
  invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                            VALUES ($1,'A2',$2,'admin')", params = list(ADM2, sodium::password_store("x"))))
  testServer(mk_server(), {
    session$setInputs(login_as = ADM2, login = 1)
    session$setInputs(`admin-act_user` = ADM, `admin-act_off` = 1)
    check(isFALSE(reviewer_get(con, ADM)$active),
          "with two admins, one can be deactivated")
    session$setInputs(`admin-act_user` = ADM2, `admin-act_off` = 2)
    check(isTRUE(reviewer_get(con, ADM2)$active),
          "the LAST active admin cannot be deactivated")
  })

  cat("\n4. the export never carries a password hash\n")
  ex <- decisions_export(con)
  check(!"password_hash" %in% names(ex), "the decisions export has no password_hash column")
  check(all(!grepl("^\\$7\\$", unlist(lapply(ex, as.character)))),
        "and no scrypt hash appears in any of its values")
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
