# ══════════════════════════════════════════════════════════════════════════════
# AUTHENTICATION AND ROLE GATING
# ══════════════════════════════════════════════════════════════════════════════
#
# Hand-rolled rather than shinymanager. That package pulls four more
# dependencies for a login form, wraps the whole UI with secure_app() and brings
# its own admin screen — this app has its own, and two admin screens is worse
# than one. What is here is small enough to read in one sitting, which is the
# only reason owning an auth implementation is defensible at all.
#
# ── The rule ──────────────────────────────────────────────────────────────────
#
# IDENTITY COMES ONLY FROM THE SESSION. There is no reviewer text box anywhere
# in this app and there must never be one: v1 had a free-text name field, which
# meant every attribution in its ledger was a claim rather than a fact.
# tests/no_secrets.sh greps for the reintroduction.
#
# ── Why every output guards itself ────────────────────────────────────────────
#
# Hiding a nav panel is not access control. A Shiny client can set any input
# with Shiny.setInputValue() from the browser console and can subscribe to any
# output over the websocket, so the panel being invisible stops nobody. The
# guard is that each render and each observer calls require_role() and REFUSES
# TO PRODUCE ANYTHING otherwise.

IDLE_MINUTES <- as.integer(Sys.getenv("CURATION_IDLE_MINUTES", unset = "60"))
# How often the server re-checks whether a session has gone idle. Expiry is
# therefore accurate to within this window, which is the right trade: exact
# expiry would need a timer per session firing every second.
AUTH_POLL_MS <- as.integer(Sys.getenv("CURATION_AUTH_POLL_MS", unset = "30000"))

# ── Why the identity is a reactiveVal and last_seen is not ────────────────────
#
# Outputs must STOP RENDERING the moment a session expires or an account is
# deactivated. Shiny outputs are cached and only re-run when a reactive
# dependency changes, so holding the identity in a plain list means an expired
# session keeps serving whatever it had already rendered — auth_user() returns
# NULL and nothing asks it. Caught by testServer, which is exactly the position
# a client with an open websocket is in.
#
# last_seen deliberately stays OUT of the reactive value. It is bumped on every
# input change, and making that reactive would invalidate every output on every
# keystroke.

auth_init <- function(session) {
  session$userData$auth_rv   <- shiny::reactiveVal(NULL)
  session$userData$auth_seen <- new.env(parent = emptyenv())
  session$userData$auth_seen$last <- Sys.time()
  invisible(TRUE)
}

auth_login <- function(session, reviewer) {
  session$userData$auth_seen$last <- Sys.time()
  session$userData$auth_rv(list(
    username       = reviewer$username,
    display_name   = reviewer$display_name,
    role           = reviewer$role,
    active         = isTRUE(reviewer$active),
    must_change_pw = isTRUE(reviewer$must_change_pw),
    logged_in_at   = Sys.time()
  ))
  invisible(TRUE)
}

auth_logout <- function(session) {
  session$userData$auth_rv(NULL)
  invisible(TRUE)
}

auth_touch <- function(session) {
  if (!is.null(session$userData$auth_seen)) session$userData$auth_seen$last <- Sys.time()
  invisible(TRUE)
}

auth_last_seen <- function(session) {
  session$userData$auth_seen$last %||% Sys.time()
}

auth_expired <- function(session, minutes = IDLE_MINUTES) {
  if (is.null(shiny::isolate(session$userData$auth_rv()))) return(FALSE)
  as.numeric(difftime(Sys.time(), auth_last_seen(session), units = "mins")) > minutes
}

# The single source of truth for "who is this". Reading the reactiveVal is what
# makes every caller re-evaluate when the session ends.
#
# Returns NULL when nobody is logged in, when the account was deactivated
# mid-session, or when the session has gone idle — so a caller cannot treat an
# expired session as valid by checking only for non-NULL.
auth_user <- function(session, minutes = IDLE_MINUTES) {
  a <- session$userData$auth_rv()
  if (is.null(a)) return(NULL)
  if (!isTRUE(a$active)) return(NULL)
  if (auth_expired(session, minutes)) return(NULL)
  a
}

# Clears the identity once the idle window passes, which invalidates every
# output that depends on it. Without this the expiry is only noticed the next
# time something else happens to invalidate an output.
auth_watch <- function(session, minutes = IDLE_MINUTES, poll_ms = AUTH_POLL_MS) {
  shiny::observe({
    shiny::invalidateLater(poll_ms, session)
    if (auth_expired(session, minutes)) auth_logout(session)
  })
}

# For tests and for callers that must not create a reactive dependency.
auth_set_last_seen <- function(session, when) {
  session$userData$auth_seen$last <- when
  invisible(TRUE)
}

auth_deactivate_local <- function(session) {
  a <- shiny::isolate(session$userData$auth_rv())
  if (!is.null(a)) { a$active <- FALSE; session$userData$auth_rv(a) }
  invisible(TRUE)
}

auth_is_admin <- function(session) {
  a <- auth_user(session)
  !is.null(a) && identical(a$role, "admin")
}

# req(FALSE) is deliberate: the output renders NOTHING rather than erroring.
# An error would be visible to the client and would confirm the output exists.
require_role <- function(session, role = "reviewer") {
  a <- auth_user(session)
  shiny::req(!is.null(a))
  if (identical(role, "admin")) shiny::req(identical(a$role, "admin"))
  invisible(a)
}

# ── Login UI ──────────────────────────────────────────────────────────────────

login_ui <- function(message = NULL, ns = identity) {
  shiny::div(
    class = "container", style = "max-width:420px;margin-top:8vh;",
    shiny::div(
      class = "card shadow-sm",
      shiny::div(
        class = "card-body",
        shiny::h4("Curation", class = "card-title mb-1"),
        shiny::p(class = "text-muted small",
                 "EU Paediatric Trial Monitor — reviewer access"),
        shiny::textInput(ns("login_user"), "Username"),
        shiny::passwordInput(ns("login_pw"), "Password"),
        shiny::actionButton(ns("login_go"), "Sign in", class = "btn-primary w-100"),
        if (!is.null(message))
          shiny::div(class = "alert alert-danger mt-3 mb-0 py-2 small", message)
      )
    )
  )
}

# One message for every failure. Distinguishing "no such user" from "wrong
# password" turns the form into a username oracle; store.R keeps the two
# indistinguishable in time as well.
LOGIN_FAILED_MESSAGE <- "Sign-in failed. Check your username and password."
