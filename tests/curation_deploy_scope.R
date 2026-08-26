# Constants the modules need must survive being run the way Posit runs the app.
#
#   Rscript tests/curation_deploy_scope.R
#
# Needs no database and no network.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
#
# app.R sources R/*.R with source(), which defaults to local = FALSE and so
# evaluates them into globalenv(). app.R's OWN top level is not necessarily
# globalenv — Posit Connect evaluates the app file in its own environment — so a
# constant assigned in app.R is invisible to a function defined in globalenv.
#
# That shipped: "object 'APP_VERSION' not found" the moment a reviewer saved a
# decision. Only on the deployed app. Never locally, and never in the other
# tests, because every one of them assigns APP_VERSION itself before calling a
# module — which is exactly the assumption the bug violates.

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

owd <- setwd("curation_app"); on.exit(setwd(owd), add = TRUE)

cat("1. every symbol the modules reference is defined in a SOURCED file\n")
mod_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
mod_src   <- unlist(lapply(mod_files, readLines, warn = FALSE))
app_src   <- readLines("app.R", warn = FALSE)

# Anything SHOUTY is a constant by this codebase's convention.
used <- unique(unlist(regmatches(mod_src, gregexpr("\\b[A-Z][A-Z0-9_]{3,}\\b", mod_src))))
defined_in_modules <- unique(unlist(regmatches(mod_src, gregexpr("^[A-Z][A-Z0-9_]{3,}(?= *<-)", mod_src, perl = TRUE))))
defined_in_app     <- unique(unlist(regmatches(app_src, gregexpr("^[A-Z][A-Z0-9_]{3,}(?= *<-)", app_src, perl = TRUE))))

# R keywords and things that come from packages, not from us.
known <- c("TRUE","FALSE","NULL","NA","INT","NA_character_","UTF","HTML","DT","SQL","JSON","CSV","URL","API")
orphans <- setdiff(intersect(used, defined_in_app), c(defined_in_modules, known))
check(length(orphans) == 0,
      sprintf("no module depends on a constant defined only in app.R%s",
              if (length(orphans)) paste0(" (found: ", paste(orphans, collapse = ", "), ")") else ""))

cat("\n2. the modules work when app.R's top level is NOT globalenv\n")
# Reproduce Connect's arrangement exactly: source the modules into globalenv,
# evaluate the app file's constants somewhere else, then call a module function.
e <- new.env(parent = globalenv())
for (f in mod_files) source(f)          # -> globalenv, as app.R does
local({
  # Whatever app.R assigns at its top level lands HERE, not in globalenv.
  SOMETHING_APP_LOCAL <- "x"
  v <- tryCatch(get("APP_VERSION"), error = function(e) NULL)
  check(!is.null(v) && nzchar(v),
        "APP_VERSION resolves from a module's scope, not app.R's")
}, envir = e)

check(exists("APP_VERSION", envir = globalenv(), inherits = FALSE),
      "and it is defined in a sourced file, so source() puts it in globalenv")

cat("\n3. the app file does not define anything the modules read\n")
check(!any(grepl("^APP_VERSION *<-", app_src)),
      "APP_VERSION is no longer assigned in app.R")

cat("\n4. every tab actually mounts something\n")
# The statistics tab shipped BLANK: the nav panel still held
# uiOutput("tab_stats") after the module was wired in and output$tab_stats was
# deleted. The server ran, nothing was mounted, and the tab rendered empty with
# no error anywhere. A module is only reachable if BOTH halves are present.
app_txt <- paste(app_src, collapse = "\n")
panels <- unlist(regmatches(app_txt, gregexpr('nav_panel\\("[^"]+", *[a-zA-Z_]+\\("[^"]+"\\)', app_txt)))
check(length(panels) >= 3, sprintf("found %d nav panels", length(panels)))
for (pn in panels) {
  fn  <- sub('.*, *([a-zA-Z_]+)\\(".*', "\\1", pn)
  arg <- sub('.*\\("([^"]+)"\\)$', "\\1", pn)
  tab <- sub('nav_panel\\("([^"]+)".*', "\\1", pn)
  if (identical(fn, "uiOutput")) {
    # A uiOutput panel needs a matching output$<id> in app.R.
    check(any(grepl(paste0("output\\$", arg, " *<-"), app_src)),
          sprintf("tab '%s' uses uiOutput('%s') and app.R defines it", tab, arg))
  } else {
    # A module panel needs its *_server called with the same id.
    srv <- sub("_ui$", "_server", fn)
    check(any(grepl(paste0(srv, '\\("', arg, '"'), app_src)),
          sprintf("tab '%s' mounts %s('%s') and %s is called with that id",
                  tab, fn, arg, srv))
  }
}

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
