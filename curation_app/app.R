# ══════════════════════════════════════════════════════════════════════════════
# CURATION APP — the reviewer-facing companion to the dashboard
# ══════════════════════════════════════════════════════════════════════════════
#
# Deployed separately from app.R at the repo root, with its own manifest. It
# runs on Posit Cloud: read-only filesystem, no database of its own, no pipeline
# state. Everything it displays is fetched from the public repo at process
# start; everything it records goes to Postgres.
#
#   R/github.R     the snapshot fetch (data only, never code)
#   R/store.R      the decision store
#   R/auth.R       login and role gating
#   R/field_spec.R the recoded-field catalogue, SHARED with ../app.R
#
# Four screens: trial validation, normalisation review, changes & statistics,
# and an admin panel that only admins can reach — enforced server-side, in every
# output, not by hiding the nav item.

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(DBI)
  library(dplyr)
  library(DT)
})

for (f in c("util.R", "field_spec.R", "github.R", "store.R", "auth.R")) {
  source(file.path("R", f))
}

APP_VERSION <- "0.22.0"

# ── Startup ───────────────────────────────────────────────────────────────────
#
# Fetched once per PROCESS, not per session: Posit keeps the process warm and
# reviewers hit it once a day, so a 20-30s cold start nobody sees twice is not
# worth promises/future for.
message("Curation app ", APP_VERSION, " starting")
snapshot_refresh()

# The pool is opened once and shared. Several concurrent sessions each opening
# their own connection is how a free-tier database runs out of them.
DB_POOL <- tryCatch(curation_pool(), error = function(e) {
  message("No database pool: ", conditionMessage(e))
  NULL
})
if (!is.null(DB_POOL)) message("Database: ", curation_db_label())

onStop(function() if (!is.null(DB_POOL)) pool::poolClose(DB_POOL))

# ── UI ────────────────────────────────────────────────────────────────────────
#
# The whole UI is a single uiOutput. An unauthenticated client is never sent the
# app's markup at all — not because that is the access control (it is not; every
# output guards itself) but because there is no reason to ship it.

ui <- bslib::page_fluid(
  theme = bslib::bs_theme(version = 5, preset = "flatly"),
  tags$head(tags$title("Curation — EU Paediatric Trial Monitor")),
  uiOutput("shell")
)

# ── Server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {
  auth_init(session)
  # Clears the identity once the idle window passes, which invalidates every
  # output depending on it. Without it, expiry is only noticed the next time
  # something else happens to invalidate an output.
  auth_watch(session)
  login_error <- reactiveVal(NULL)
  # Bumped on any client activity so a long read does not expire mid-decision.
  observe({ reactiveValuesToList(input); auth_touch(session) })

  observeEvent(input$login_go, {
    login_error(NULL)
    user <- isolate(input$login_user %||% "")
    pw   <- isolate(input$login_pw   %||% "")
    if (!nzchar(user) || !nzchar(pw)) { login_error(LOGIN_FAILED_MESSAGE); return() }
    if (is.null(DB_POOL))             { login_error("The database is unavailable."); return() }
    r <- tryCatch(reviewer_verify(DB_POOL, user, pw), error = function(e) NULL)
    if (is.null(r)) { login_error(LOGIN_FAILED_MESSAGE); return() }
    auth_login(session, r)
    login_error(NULL)
  })

  observeEvent(input$logout, auth_logout(session))

  # Re-evaluated whenever auth changes, so an expiry or a logout swaps the whole
  # UI back to the login form rather than leaving a dead shell on screen.
  output$shell <- renderUI({
    a <- auth_user(session)
    if (is.null(a)) return(login_ui(login_error()))
    app_shell(a)
  })

  app_shell <- function(a) {
    panels <- list(
      bslib::nav_panel("Trial validation",     uiOutput("tab_trials")),
      bslib::nav_panel("Normalisation review", uiOutput("tab_norm")),
      bslib::nav_panel("Changes & statistics", uiOutput("tab_stats"))
    )
    # Cosmetic only. The admin outputs below refuse regardless of whether this
    # nav item was ever rendered.
    if (identical(a$role, "admin")) {
      panels <- c(panels, list(bslib::nav_panel("Admin", uiOutput("tab_admin"))))
    }
    do.call(bslib::page_navbar, c(
      list(
        title = "Curation",
        id = "main_nav",
        header = div(class = "px-3 pt-2", uiOutput("banner")),
        footer = div(class = "px-3 py-2 text-muted small",
                     sprintf("v%s · signed in as %s (%s)", APP_VERSION,
                             a$display_name, a$role),
                     actionLink("logout", "Sign out", class = "ms-3"))
      ),
      panels
    ))
  }

  output$banner <- renderUI({
    require_role(session)
    snapshot_banner(snapshot_current())
  })

  # ── Tabs ────────────────────────────────────────────────────────────────────
  # Placeholders until the screens land. The GUARD is the point of this commit:
  # every one of these refuses without a session, and the admin one refuses
  # without the admin role.

  output$tab_trials <- renderUI({
    require_role(session)
    div(class = "p-3", h5("Trial validation"),
        p(class = "text-muted", "Browse every trial and check its recoding."))
  })

  output$tab_norm <- renderUI({
    require_role(session)
    div(class = "p-3", h5("Normalisation review"),
        p(class = "text-muted", "The sponsor and substance queues."))
  })

  output$tab_stats <- renderUI({
    require_role(session)
    div(class = "p-3", h5("Changes & statistics"),
        p(class = "text-muted", "What changed, by whom, and how often."))
  })

  output$tab_admin <- renderUI({
    require_role(session, "admin")
    div(class = "p-3", h5("Admin"),
        p(class = "text-muted", "Accounts, snapshot refresh, export status."))
  })

  # Admin-only action. Re-checks the role INSIDE the handler: this input is
  # forgeable from the browser console with Shiny.setInputValue(), so the fact
  # that no button was rendered for a reviewer is not a defence.
  observeEvent(input$admin_refresh_snapshot, {
    a <- auth_user(session)
    if (is.null(a) || !identical(a$role, "admin")) return()
    snapshot_refresh()
    if (!is.null(DB_POOL)) {
      try(admin_audit_log(DB_POOL, a$username, "refresh_snapshot",
                          target = snapshot_current()$sha %||% NA), silent = TRUE)
    }
  })
}

shinyApp(ui, server)
