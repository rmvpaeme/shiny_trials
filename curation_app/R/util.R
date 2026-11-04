# Small shared helpers for the curation app.

# ── Why this is here and not in app.R ─────────────────────────────────────────
#
# app.R sources these files with source(), which defaults to local = FALSE and
# therefore evaluates them into globalenv(). But app.R's OWN top level is not
# necessarily globalenv: Posit Connect evaluates the app file in its own
# environment, so a constant assigned there is invisible to a function defined
# in globalenv.
#
# The result was "object 'APP_VERSION' not found" the moment a reviewer saved a
# decision — only on the deployed app, never locally, and never in the tests,
# which set it themselves. Anything the modules need lives in a sourced file.
APP_VERSION <- "0.22.3"

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# Where a snapshot came from and how stale it is, for the persistent banner.
# Degraded mode has to be VISIBLE: a reviewer working against yesterday's queue
# is fine, but only if they know that is what they are doing.
snapshot_banner <- function(snap) {
  if (is.null(snap)) {
    return(shiny::div(class = "alert alert-danger mb-0 py-2 small",
      shiny::strong("No data. "),
      "The app could not fetch a snapshot from GitHub and has nothing cached. ",
      "Review is unavailable until a refresh succeeds."))
  }
  age <- as.numeric(difftime(Sys.time(), snap$fetched_at, units = "hours"))
  sha <- substr(snap$sha, 1, 8)
  if (isTRUE(snap$degraded)) {
    shiny::div(class = "alert alert-warning mb-0 py-2 small",
      shiny::strong("Showing a cached snapshot. "),
      sprintf("The last refresh failed, so this is %s from %.1f hours ago. ", sha, age),
      shiny::span(class = "text-muted", snap$degraded_reason %||% ""))
  } else {
    shiny::div(class = "text-muted small py-1",
      sprintf("Snapshot %s · %s · fetched %.1f h ago",
              sha, snap$committed_at %||% "?", age))
  }
}

fmt_int <- function(x) formatC(as.numeric(x), format = "d", big.mark = ",")

# ── Polling without redrawing ─────────────────────────────────────────────────
#
# A reactive with invalidateLater() notifies everything downstream on EVERY
# tick, whether or not the value changed. Both review tabs poll the database so
# a second reviewer's work shows up, and each tick rebuilt the table — which
# clears the selected row, the detail panel and any comment half-typed in it.
# Reported as "a refresh every 30 seconds" and as "my comments will not save".
#
# This reads on the same schedule but only passes the value on when it differs
# from the last one. read() may depend on other reactives (the user, the chosen
# round); those still re-run it immediately.
poll_changes <- function(session, ms, read) {
  rv <- shiny::reactiveVal(NULL)
  shiny::observe({
    shiny::invalidateLater(ms, session)
    v <- read()
    if (!identical(v, shiny::isolate(rv()))) rv(v)
  })
  shiny::reactive(rv())
}
