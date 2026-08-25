# Small shared helpers for the curation app.

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
