# ══════════════════════════════════════════════════════════════════════════════
# SNAPSHOT FETCH — the curation app's only source of data
# ══════════════════════════════════════════════════════════════════════════════
#
# The app runs on Posit Cloud: read-only filesystem, no database, no pipeline
# state. Everything it displays is fetched at process start from the PUBLIC repo.
#
# ── Why the `deploy` branch and not `main` ────────────────────────────────────
#
# The registries live outside the work tree on the server (SPONSOR_V2_DIR), so
# `main` carries whatever was last committed by hand and does not move. `deploy`
# is regenerated nightly and is the only ref that tracks the live backlog.
#
# ── Why by resolved SHA and never by ref ──────────────────────────────────────
#
# Fetching seven files by ref means seven independent reads of a moving target:
# a nightly push landing mid-fetch yields a snapshot that is half one commit and
# half another, with a registry that does not contain the entities its own queue
# proposes. Resolving the SHA once and fetching every file at that SHA makes the
# snapshot atomic.
#
# BUT A SHA IS NOT A DURABLE HANDLE HERE. `deploy` is force-pushed every night,
# so yesterday's SHA becomes unreachable and is eventually garbage-collected, at
# which point raw.githubusercontent.com returns 404. Re-resolve on every fetch.
# Never store a SHA expecting to retrieve it later — decisions record it as
# PROVENANCE ("this is the state the reviewer was looking at"), not as a
# retrieval key.
#
# ── Only data is fetched, never code ──────────────────────────────────────────
#
# Sourcing R from a branch at runtime is a remote code execution path. Every
# entry below is a data file and the list is fixed here, not derived from
# anything the fetch returns.

GITHUB_REPO <- Sys.getenv("CURATION_GITHUB_REPO", unset = "rmvpaeme/shiny_trials")
GITHUB_REF  <- Sys.getenv("CURATION_GITHUB_REF",  unset = "deploy")

# required = FALSE means "not an error if absent". data/trial_overrides.csv does
# not exist until the first reviewer decision is exported, and an app that
# refuses to start before anyone has curated anything is not much use.
SNAPSHOT_FILES <- list(
  list(path = "trials_cache.rds",                            mode = "wb", required = TRUE),
  list(path = "config/sponsor_norm_v2/E_review_queue.csv",   mode = "w",  required = TRUE),
  list(path = "config/sponsor_norm_v2/registry.csv",         mode = "w",  required = TRUE),
  list(path = "config/substance_norm_v2/E_review_queue.csv", mode = "w",  required = TRUE),
  list(path = "config/substance_norm_v2/registry.csv",       mode = "w",  required = TRUE),
  list(path = "data/trial_sponsors_raw.csv",                 mode = "w",  required = TRUE),
  list(path = "data/trial_substances_raw.csv",               mode = "w",  required = TRUE),
  list(path = "data/trial_overrides.csv",                    mode = "w",  required = FALSE)
)

# A PAT is used only for rate-limit headroom. The repo is public and the app
# must work without one; if it is ever required, that is a bug.
#
# Everything below goes through base R's download.file() rather than httr. Two
# reasons, and the second is the one that matters: it is one dependency fewer,
# and it means the API call and the file fetches share a single HTTP path — so
# a proxy, a TLS quirk or a corporate MITM either breaks both or neither, rather
# than leaving the app able to fetch files but unable to resolve the ref it
# needs them at. (Observed: an environment where httr could not CONNECT to
# api.github.com while download.file handled both hosts.)
gh_headers <- function() {
  pat <- Sys.getenv("GITHUB_PAT", unset = "")
  h <- c(Accept = "application/vnd.github+json",
         `User-Agent` = "shiny-trials-curation")
  if (nzchar(pat)) h <- c(h, Authorization = paste("Bearer", pat))
  h
}

gh_download <- function(url, dest, mode = "w", headers = gh_headers(), quiet = TRUE) {
  suppressWarnings(
    utils::download.file(url, dest, mode = mode, quiet = quiet, headers = headers))
  file.exists(dest) && file.size(dest) > 0
}

resolve_sha <- function(repo = GITHUB_REPO, ref = GITHUB_REF) {
  url <- sprintf("https://api.github.com/repos/%s/commits/%s", repo, ref)
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp), add = TRUE)
  ok <- tryCatch(gh_download(url, tmp), error = function(e) {
    stop("GitHub unreachable resolving ", repo, "@", ref, ": ", conditionMessage(e),
         call. = FALSE)
  })
  if (!ok) stop("GitHub returned nothing resolving ", repo, "@", ref, call. = FALSE)
  body <- tryCatch(jsonlite::fromJSON(tmp, simplifyVector = TRUE),
                   error = function(e) NULL)
  sha <- body$sha
  if (is.null(sha) || !nzchar(sha)) stop("GitHub returned no sha for ", ref, call. = FALSE)
  list(sha = sha,
       committed_at = body$commit$committer$date %||% NA_character_,
       message = sub("\n.*$", "", body$commit$message %||% ""))
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

raw_url <- function(repo, sha, path) {
  sprintf("https://raw.githubusercontent.com/%s/%s/%s", repo, sha, path)
}

# Downloads into a FRESH directory and only returns once every required file has
# landed and validated. The caller swaps its pointer to the result, so a failed
# or partial fetch can never become the live snapshot.
fetch_snapshot <- function(sha, repo = GITHUB_REPO, files = SNAPSHOT_FILES,
                           dest = NULL, quiet = TRUE) {
  dir <- dest %||% file.path(tempdir(), paste0("snapshot-", substr(sha, 1, 12)))
  if (dir.exists(dir)) unlink(dir, recursive = TRUE)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  got <- character()
  missing_optional <- character()
  for (f in files) {
    target <- file.path(dir, f$path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    url <- raw_url(repo, sha, f$path)
    # mode="wb" matters: text mode corrupts the .rds on any platform that
    # rewrites line endings, and the corruption is silent until readRDS fails.
    ok <- tryCatch(gh_download(url, target, mode = f$mode, quiet = quiet),
                   error = function(e) FALSE)

    if (!ok) {
      if (isTRUE(f$required)) {
        unlink(dir, recursive = TRUE)
        stop(sprintf("could not fetch required file %s at %s", f$path, substr(sha, 1, 8)),
             call. = FALSE)
      }
      missing_optional <- c(missing_optional, f$path)
      unlink(target)
      next
    }
    got <- c(got, f$path)
  }

  # Validate before anyone can use it. A truncated download is a plausible file
  # of the wrong length, and the cache is the one where that matters most.
  cache <- file.path(dir, "trials_cache.rds")
  if (file.exists(cache)) {
    d <- tryCatch(readRDS(cache), error = function(e) NULL)
    if (is.null(d) || !"_id" %in% names(d) || !nrow(d)) {
      unlink(dir, recursive = TRUE)
      stop("fetched trials_cache.rds did not read back as trial data", call. = FALSE)
    }
  }

  list(dir = dir, sha = sha, repo = repo,
       fetched_at = as.POSIXct(Sys.time(), tz = "UTC"),
       files = got, missing_optional = missing_optional, degraded = FALSE)
}

# The pointer the app reads. Held in an environment rather than a global so a
# failed refresh cannot half-replace it.
.snapshot <- new.env(parent = emptyenv())
.snapshot$current <- NULL

snapshot_current <- function() .snapshot$current

# Fetch and swap. On failure KEEPS the last good snapshot and marks it degraded,
# because a reviewer working against yesterday's queue is far better than an app
# that will not load — as long as the banner says which it is.
snapshot_refresh <- function(repo = GITHUB_REPO, ref = GITHUB_REF, ...) {
  prev <- .snapshot$current
  out <- tryCatch({
    r <- resolve_sha(repo, ref)
    snap <- fetch_snapshot(r$sha, repo, ...)
    snap$committed_at <- r$committed_at
    snap$message <- r$message
    snap
  }, error = function(e) e)

  if (inherits(out, "error")) {
    msg <- conditionMessage(out)
    if (!is.null(prev)) {
      prev$degraded <- TRUE
      prev$degraded_reason <- msg
      prev$degraded_at <- as.POSIXct(Sys.time(), tz = "UTC")
      .snapshot$current <- prev
      message("Snapshot refresh FAILED, keeping the previous one: ", msg)
    } else {
      message("Snapshot fetch FAILED and there is nothing to fall back to: ", msg)
    }
    return(invisible(.snapshot$current))
  }

  # Only now does the live pointer move.
  .snapshot$current <- out
  message(sprintf("Snapshot %s (%s), %d file(s)%s",
                  substr(out$sha, 1, 8), out$committed_at, length(out$files),
                  if (length(out$missing_optional))
                    sprintf(", %d optional absent", length(out$missing_optional)) else ""))
  invisible(out)
}

snapshot_file <- function(path, snap = snapshot_current()) {
  if (is.null(snap)) return(NA_character_)
  p <- file.path(snap$dir, path)
  if (file.exists(p)) p else NA_character_
}
