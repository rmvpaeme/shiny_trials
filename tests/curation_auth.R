# Role gating is enforced SERVER-SIDE, in every output.
#
#   Rscript tests/curation_auth.R
#
# Hiding a nav panel is not access control: a Shiny client can set any input
# from the browser console and subscribe to any output over the websocket. These
# tests drive the server function directly with shiny::testServer, which is
# exactly the position a hostile client is in — no UI, just inputs and outputs.
#
# Needs CURATION_DB_URL for the login path; skips (exit 2) without one.

suppressPackageStartupMessages({ library(shiny); library(DBI) })

owd <- setwd("curation_app")
on.exit(setwd(owd), add = TRUE)

source("R/util.R"); source("R/auth.R"); source("R/store.R")

cfg <- curation_db_config()
if (is.null(cfg)) { message("COULD NOT MEASURE: CURATION_DB_URL is not set."); quit(save="no", status=2L) }
con <- tryCatch(curation_connect(), error = function(e) e)
if (inherits(con, "error")) {
  message("COULD NOT MEASURE: cannot reach ", curation_db_label()); quit(save="no", status=2L)
}

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

# req(FALSE) inside a render makes the output produce nothing. Under
# testServer, reading such an output RAISES a shiny.silent.error rather than
# returning NULL — that error IS the refusal, and treating it as a test failure
# would invert the whole meaning of these checks. Anything that is not a
# successfully produced value counts as blocked.
blocked <- function(expr) {
  v <- tryCatch(force(expr), error = function(e) structure(list(), class = "__blocked__"))
  inherits(v, "__blocked__") || is.null(v)
}

REV <- "__test__rev"; ADM <- "__test__adm"; PW <- "s3cret-pass"
cleanup <- function() {
  try(dbExecute(con, "DELETE FROM admin_audit WHERE actor LIKE '__test__%'"), silent = TRUE)
  try(dbExecute(con, "DELETE FROM reviewers  WHERE username LIKE '__test__%'"), silent = TRUE)
  invisible(NULL)
}
cleanup()
invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                          VALUES ($1,'Rev Test',$2,'reviewer')",
                    params = list(REV, sodium::password_store(PW))))
invisible(dbExecute(con, "INSERT INTO reviewers (username, display_name, password_hash, role)
                          VALUES ($1,'Adm Test',$2,'admin')",
                    params = list(ADM, sodium::password_store(PW))))

# A cut-down server with the same guards as app.R. The real one calls
# snapshot_refresh() and opens a pool at startup, neither of which belongs in a
# unit test; the GUARDS are identical and they are what is under test.
DB <- con
test_server <- function(input, output, session) {
  auth_init(session)
  auth_watch(session)          # same watcher app.R starts
  login_error <- reactiveVal(NULL)
  observeEvent(input$login_go, {
    r <- tryCatch(reviewer_verify(DB, input$login_user %||% "", input$login_pw %||% ""),
                  error = function(e) NULL)
    if (is.null(r)) { login_error(LOGIN_FAILED_MESSAGE) } else { auth_login(session, r); login_error(NULL) }
  })
  output$tab_trials <- renderText({ require_role(session); "TRIALS" })
  output$tab_admin  <- renderText({ require_role(session, "admin"); "ADMIN" })
  output$who        <- renderText({ a <- require_role(session); a$username })
  observeEvent(input$admin_action, {
    a <- auth_user(session)
    if (is.null(a) || !identical(a$role, "admin")) return()
    admin_audit_log(DB, a$username, "test_privileged_action", target = "x")
  })
}

run <- function() {

# ── 1. Nobody is logged in ───────────────────────────────────────────────────
testServer(test_server, {
  check(is.null(auth_user(session)), "no session = no user")
  check(blocked(output$tab_trials),  "unauthenticated: a reviewer output renders NOTHING")
  check(blocked(output$tab_admin),   "unauthenticated: the admin output renders NOTHING")
})

# ── 2. Wrong credentials ─────────────────────────────────────────────────────
testServer(test_server, {
  session$setInputs(login_user = REV, login_pw = "wrong", login_go = 1)
  check(is.null(auth_user(session)), "a wrong password does not create a session")
  check(blocked(output$tab_trials),  "and the outputs stay empty")
})
testServer(test_server, {
  session$setInputs(login_user = "__test__ghost", login_pw = PW, login_go = 1)
  check(is.null(auth_user(session)), "an unknown username does not create a session")
})

# ── 3. A reviewer signs in ───────────────────────────────────────────────────
testServer(test_server, {
  session$setInputs(login_user = REV, login_pw = PW, login_go = 1)
  a <- auth_user(session)
  check(!is.null(a) && identical(a$role, "reviewer"), "a reviewer can sign in")
  check(identical(output$tab_trials, "TRIALS"), "a reviewer gets the reviewer output")
  check(identical(output$who, REV), "identity comes from the SESSION, not an input")

  # THE CENTRAL TEST. A reviewer subscribing to the admin output over the
  # websocket must get nothing, whether or not a nav panel was rendered.
  check(blocked(output$tab_admin), "a REVIEWER is refused the admin output")

  # And a forged privileged input must not act.
  before <- dbGetQuery(DB, "SELECT count(*) n FROM admin_audit WHERE actor = $1",
                       params = list(REV))$n
  session$setInputs(admin_action = 1)
  after <- dbGetQuery(DB, "SELECT count(*) n FROM admin_audit WHERE actor = $1",
                      params = list(REV))$n
  check(identical(as.numeric(before), as.numeric(after)),
        "a reviewer forging an admin input writes NOTHING")
})

# ── 4. An admin signs in ─────────────────────────────────────────────────────
testServer(test_server, {
  session$setInputs(login_user = ADM, login_pw = PW, login_go = 1)
  check(identical(output$tab_admin, "ADMIN"), "an admin gets the admin output")
  check(identical(output$tab_trials, "TRIALS"), "an admin also gets the reviewer outputs")
  session$setInputs(admin_action = 1)
  n <- dbGetQuery(DB, "SELECT count(*) n FROM admin_audit WHERE actor = $1",
                  params = list(ADM))$n
  check(as.numeric(n) == 1, "an admin action runs and is audited")
})

# ── 5. Idle timeout, server-side ─────────────────────────────────────────────
testServer(test_server, {
  session$setInputs(login_user = ADM, login_pw = PW, login_go = 1)
  check(!is.null(auth_user(session)), "session is live immediately after login")
  # Age last_seen past the window. The CLIENT IS NOT CONSULTED — this is what a
  # browser tab left open overnight looks like from the server's side.
  auth_set_last_seen(session, Sys.time() - as.difftime(IDLE_MINUTES + 1, units = "mins"))
  check(is.null(auth_user(session)),  "an idle session expires SERVER-SIDE")
  # Advance past one poll so auth_watch() fires and clears the identity. That
  # write is what invalidates the outputs; last_seen alone is deliberately not
  # reactive, or every keystroke would re-render the app.
  session$elapse(AUTH_POLL_MS + 1000)
  session$flushReact()
  check(blocked(output$tab_trials),   "expired: reviewer output stops rendering")
  check(blocked(output$tab_admin),    "expired: admin output stops rendering")
})

# ── 6. Deactivated mid-session ───────────────────────────────────────────────
testServer(test_server, {
  session$setInputs(login_user = REV, login_pw = PW, login_go = 1)
  check(!is.null(auth_user(session)), "signed in")
  auth_deactivate_local(session)
  session$flushReact()
  check(is.null(auth_user(session)), "a deactivated account loses access mid-session")
  check(blocked(output$tab_trials),  "and its outputs stop rendering")
})

# ── 7. No free-text reviewer field anywhere ──────────────────────────────────
src <- unlist(lapply(list.files(".", pattern = "\\.R$", recursive = TRUE, full.names = TRUE),
                     function(f) readLines(f, warn = FALSE)))
bad <- grep("input\\$[A-Za-z_.]*reviewer", src, value = TRUE)
check(length(bad) == 0,
      "no input$*reviewer* anywhere — identity cannot come from the client")

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
