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
#
# ── DEPLOYMENT IS NOT THE DASHBOARD'S ─────────────────────────────────────────
#
# The dashboard ships through the nightly: a push to the `deploy` branch, every
# night, because its data changes every night. This app does not. Its CODE is
# uploaded by hand from an R session (rsconnect::deployApp("curation_app")) when
# it actually changes, which is rarely.
#
# The two are independent on purpose, and it is why this app fetches DATA from
# the repo at runtime rather than being rebuilt with it: a nightly data refresh
# must not require redeploying an app, and redeploying the app must not wait for
# a nightly. There is no manifest.json here — deployApp() builds its own bundle
# — and the rsconnect/ directory it writes is gitignored, because it carries the
# account token.

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(DBI)
  library(dplyr)
  library(DT)
})

for (f in c("util.R", "field_spec.R", "github.R", "store.R", "auth.R",
            "norm_review.R", "trials.R", "stats.R", "admin.R")) {
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
  # R reads .Renviron from the STARTUP working directory, and this app starts in
  # curation_app/ — so a .Renviron at the REPO ROOT is invisible here and the
  # database silently does not connect. Same shape as the trap AGENTS/DEPLOY.md
  # records for rebuild_cache.R, where a setwd() after startup defeats a project
  # .Renviron. Hence the path in the message: the fix is never obvious from
  # "connection failed".
  message("No database pool: ", conditionMessage(e))
  message("  Reviewers cannot sign in and no decision can be recorded.")
  message("  Locally: put CURATION_DB_URL in curation_app/.Renviron")
  message("           (the repo-root one is NOT read — this app starts in curation_app/)")
  message("  On Posit: set it as an environment variable on the deployed app.")
  NULL
})
if (!is.null(DB_POOL)) message("Database: ", curation_db_label())

# Loaded once per process. Used for the sibling panel and, later, tab 1.
TRIALS_CACHE <- local({
  p <- snapshot_file("trials_cache.rds")
  if (is.na(p)) { message("No trials cache in the snapshot"); return(NULL) }
  d <- tryCatch(readRDS(p), error = function(e) NULL)
  if (!is.null(d)) message(sprintf("Trials cache: %s rows", format(nrow(d), big.mark = ",")))
  d
})

onStop(function() if (!is.null(DB_POOL)) pool::poolClose(DB_POOL))

# ── UI ────────────────────────────────────────────────────────────────────────
#
# The whole UI is a single uiOutput. An unauthenticated client is never sent the
# app's markup at all — not because that is the access control (it is not; every
# output guards itself) but because there is no reason to ship it.

ui <- bslib::page_fluid(
  theme = bslib::bs_theme(version = 5, preset = "flatly"),
  tags$head(
    tags$title("Curation — EU Paediatric Trial Monitor"),
    # DT has no built-in no-wrap class; without it a long title wraps and one
    # table row grows taller than the detail panel beside it.
    tags$style(HTML(
      ".dt-nowrap{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px;}
       table.dataTable td{padding-top:.25rem;padding-bottom:.25rem;}
       /* The field tables are dense by design; keep them inside their card. */
       .curation-fields table{margin-bottom:0;}
       .curation-fields td,.curation-fields th{word-break:break-word;}"))),
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
      bslib::nav_panel("Trial validation",     trials_ui("trials")),
      bslib::nav_panel("Normalisation review", norm_review_ui("norm")),
      bslib::nav_panel("Changes & statistics", uiOutput("tab_stats"))
    )
    # Cosmetic only. The admin outputs below refuse regardless of whether this
    # nav item was ever rendered.
    if (identical(a$role, "admin")) {
      panels <- c(panels, list(bslib::nav_panel("Admin", admin_ui("admin"))))
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

  # The module needs the identity, and gets it as a REACTIVE rather than a
  # value: when the session expires, session_user() becomes NULL and every
  # write inside the module refuses. Passing a snapshot of the user at mount
  # time would leave a module that keeps accepting decisions after logout.
  session_user <- reactive(auth_user(session))
  norm_review_server("norm", db = DB_POOL, session_user = session_user,
                     cache = TRIALS_CACHE)
  trials_server("trials", db = DB_POOL, session_user = session_user,
                cache = TRIALS_CACHE)
  stats_server("stats", db = DB_POOL, session_user = session_user)
  admin_server("admin", db = DB_POOL, session_user = session_user)

  output$banner <- renderUI({
    require_role(session)
    snapshot_banner(snapshot_current())
  })

  # ── Tabs ────────────────────────────────────────────────────────────────────
  # Placeholders until the screens land. The GUARD is the point of this commit:
  # every one of these refuses without a session, and the admin one refuses
  # without the admin role.

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
