#!/usr/bin/env Rscript
# Deploy the curation app to Posit Cloud.
#
#   Rscript curation_app/deploy.R            # dry run: show what would upload
#   Rscript curation_app/deploy.R --deploy   # actually deploy
#
# ── WHY THIS EXISTS INSTEAD OF A BARE deployApp() ────────────────────────────
#
# rsconnect::deployApp("curation_app") bundles the DIRECTORY, and that includes
# dotfiles. Verified with rsconnect::listBundleFiles(): a bare call uploads 13
# files and `.Renviron` is one of them — so the database URL, password included,
# would be shipped inside the bundle and live on Posit Cloud as an app file.
#
# Being on a private Posit account is not the same as being secret: a bundle can
# be downloaded, copied to another account, or restored from a snapshot, and the
# credential travels with it. The connection string belongs in the deployed
# app's ENVIRONMENT, set once in the Posit Cloud UI, and nowhere else.
#
# So this uses an ALLOWLIST, not an exclusion list. An exclusion list fails open:
# the day someone adds curation_app/secrets.json, a bare deploy ships it and
# nothing says so. An allowlist fails closed — a new file is simply not uploaded
# until it is named here.

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
do_deploy <- "--deploy" %in% args
# Connect Cloud by default, because it is the only target with a Vars pane —
# CURATION_DB_URL is set on the deployed app and never enters the bundle.
# shinyapps.io has no such UI, which is why --include-env exists at all.
server  <- arg_value("--server",  "connect.posit.cloud")
account <- arg_value("--account", NA_character_)
# Some targets have no way to set an environment variable on a deployed app —
# shinyapps.io in particular. Refusing outright there would just mean the app
# cannot connect at all, so bundling is allowed, deliberately and loudly, rather
# than by accident.
include_env <- "--include-env" %in% args

app_dir <- if (basename(getwd()) == "curation_app") "." else "curation_app"
if (!file.exists(file.path(app_dir, "app.R")))
  stop("run me from the repo root or from curation_app/", call. = FALSE)

# Everything the app needs at runtime, and nothing else.
APP_FILES <- c(
  "app.R",
  # MUST match what app.R sources. An allowlist fails closed, which is the safe
  # direction — but it means a file added to app.R and not added here is simply
  # absent at runtime and the app dies on startup. sample.R did exactly that.
  # tests/no_secrets.sh now cross-checks the two.
  file.path("R", c("util.R", "field_spec.R", "github.R", "store.R", "auth.R",
                   "norm_review.R", "sample.R", "trials.R", "stats.R", "admin.R")),
  file.path("sql", c("schema.sql", "seed_admin.sql.example"))
)

missing <- APP_FILES[!file.exists(file.path(app_dir, APP_FILES))]
if (length(missing))
  stop("these files are named for deployment but do not exist:\n  ",
       paste(missing, collapse = "\n  "), call. = FALSE)

# Belt and braces. The allowlist already excludes these, but a future edit that
# adds a pattern like "R/*" would quietly pull them back in, and the failure is
# invisible — the deploy succeeds and the secret is simply up there.
FORBIDDEN <- c("\\.env$", "secrets?", "credential", "password",
               "\\.pem$", "\\.key$", "rsconnect/")
bad <- APP_FILES[vapply(APP_FILES, function(f)
  any(vapply(FORBIDDEN, function(p) grepl(p, f, ignore.case = TRUE), logical(1))),
  logical(1))]
if (length(bad))
  stop("REFUSING TO DEPLOY — these look like credentials:\n  ",
       paste(bad, collapse = "\n  "), call. = FALSE)

if (include_env) {
  if (!file.exists(file.path(app_dir, ".Renviron")))
    stop("--include-env given but curation_app/.Renviron does not exist", call. = FALSE)
  APP_FILES <- c(APP_FILES, ".Renviron")
  cat("\n!! .Renviron WILL BE UPLOADED with the bundle.\n")
  cat("   App users never see it, but anyone with access to the account, the\n")
  cat("   deployment history, or a downloaded bundle can read it.\n")
  cat("   Use a least-privilege role, NOT the postgres superuser:\n")
  cat("     psql \"$CURATION_DB_URL\" -f curation_app/sql/app_role.sql\n")
  cat("   A leaked superuser string reads every password hash in `reviewers`\n")
  cat("   and can disable the audit trail. The app role can do neither.\n\n")
}

# What a bare deployApp() would have sent, for comparison.
bare <- tryCatch({
  b <- rsconnect::listBundleFiles(app_dir)
  if (is.list(b) && !is.null(b$contents)) b$contents else unlist(b)
}, error = function(e) character())
extra <- setdiff(bare, APP_FILES)

# Fail here, with instructions, rather than inside deployApp() with a stack
# trace about a missing account.
accts <- tryCatch(rsconnect::accounts(), error = function(e) NULL)
have <- !is.null(accts) && nrow(accts) && any(accts$server == server)
if (!have) {
  cat("\nNo account registered for '", server, "'.\n", sep = "")
  if (identical(server, "connect.posit.cloud")) {
    cat("Authorise it once:\n")
    cat("  1. https://connect.posit.cloud -> your avatar -> API Keys -> New key\n")
    cat("  2. In R:\n")
    cat("       rsconnect::connectApiUser(\n")
    cat("         account = \"<your-connect-username>\",\n")
    cat("         server  = \"connect.posit.cloud\",\n")
    cat("         apiKey  = \"<the key>\")\n")
    cat("\nOr deploy to the account you already have:\n")
    cat("  Rscript curation_app/deploy.R --server=shinyapps.io --deploy --include-env\n")
    cat("  (shinyapps.io has no Vars pane, so the connection string must be\n")
    cat("   bundled — apply sql/app_role.sql first so it is not the superuser.)\n")
  }
  if (do_deploy) quit(save = "no", status = 1L)
} else if (is.na(account)) {
  account <- accts$name[accts$server == server][1]
}

cat("Deploying from: ", normalizePath(app_dir), "\n", sep = "")
cat("Target:         ", server, if (!is.na(account)) paste0(" (", account, ")") else "", "\n", sep = "")
cat("Files to upload (", length(APP_FILES), "):\n", sep = "")
for (f in APP_FILES) cat("   ", f, "\n")
if (length(extra)) {
  cat("\nEXCLUDED (a bare deployApp() would have uploaded these):\n")
  for (f in extra) cat("   ", f, "\n")
}

if (!include_env) {
  cat("\nCURATION_DB_URL is NOT uploaded. The app reads it from the environment,\n")
  cat("so set it on the deployed app:\n")
  cat("  Posit Connect / Connect Cloud -> the app -> Vars -> CURATION_DB_URL\n")
  cat("If the target has no way to set one (shinyapps.io does not), re-run with\n")
  cat("  --include-env   and read the warning it prints.\n")
}
cat("\nUse the SESSION pooler string (port 5432, user postgres.<ref> or the\n")
cat("curation_app role); the direct endpoint is IPv6-only and may be unreachable.\n")

if (!do_deploy) {
  cat("\nDry run. Re-run with --deploy to upload.\n")
  quit(save = "no", status = 0L)
}

rsconnect::deployApp(
  appDir      = app_dir,
  appFiles    = APP_FILES,
  appName     = Sys.getenv("CURATION_APP_NAME", unset = "pedtrials-curation"),
  appTitle    = "Curation — EU Paediatric Trial Monitor",
  server      = server,
  account     = if (is.na(account)) NULL else account,
  forceUpdate = TRUE
)

cat("\nDeployed. ONE STEP REMAINS — the app cannot sign anyone in until it has\n")
cat("a connection string:\n")
cat("  Connect Cloud -> this app -> Vars -> CURATION_DB_URL = <session pooler URL>\n")
cat("Use the curation_app role from sql/app_role.sql, not the postgres superuser.\n")
