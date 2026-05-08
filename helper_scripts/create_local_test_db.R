# Creates a smaller random SQLite database for local cache rebuild testing.
# Usage:
#   Rscript helper_scripts/create_local_test_db.R
#   Rscript helper_scripts/create_local_test_db.R --target-gb=4 --output=./data/trials_local.sqlite

args <- commandArgs(trailingOnly = TRUE)

get_opt <- function(name, default) {
  prefix <- paste0("--", name, "=")
  hit <- args[startsWith(args, prefix)]
  if (length(hit) == 0L) return(default)
  sub(prefix, "", hit[[length(hit)]], fixed = TRUE)
}

input_db <- get_opt("input", "./data/trials.sqlite")
output_db <- get_opt("output", "./data/trials_local.sqlite")
collection <- get_opt("collection", "trials")
target_gb <- as.numeric(get_opt("target-gb", "4"))
sample_fraction_arg <- get_opt("fraction", NA_character_)

if (is.na(target_gb) || target_gb <= 0) {
  stop("--target-gb must be a positive number")
}
if (!file.exists(input_db)) {
  stop("Input database not found: ", input_db)
}
if (!requireNamespace("DBI", quietly = TRUE)) {
  stop("Package DBI is required")
}
if (!requireNamespace("RSQLite", quietly = TRUE)) {
  stop("Package RSQLite is required")
}

input_size <- file.info(input_db)$size
target_size <- target_gb * 1024^3
sample_fraction <- if (!is.na(sample_fraction_arg)) {
  as.numeric(sample_fraction_arg)
} else {
  min(1, target_size / input_size)
}
if (is.na(sample_fraction) || sample_fraction <= 0 || sample_fraction > 1) {
  stop("--fraction must be > 0 and <= 1")
}

if (!dir.exists(dirname(output_db))) {
  dir.create(dirname(output_db), recursive = TRUE)
}
if (file.exists(output_db)) {
  stop("Output database already exists: ", output_db,
       "\nDelete it first or pass a different --output path.")
}

quote_id <- function(x) DBI::dbQuoteIdentifier(DBI::ANSI(), x)
quoted_collection <- as.character(quote_id(collection))
quoted_input <- DBI::dbQuoteString(DBI::ANSI(), normalizePath(input_db))

message("Input:  ", input_db, " (", round(input_size / 1024^3, 2), " GB)")
message("Output: ", output_db)
message("Sampling approximately ", round(sample_fraction * 100, 1), "% of rows")

con <- DBI::dbConnect(RSQLite::SQLite(), output_db)
on.exit(DBI::dbDisconnect(con), add = TRUE)

invisible(DBI::dbExecute(con, "PRAGMA journal_mode = OFF"))
invisible(DBI::dbExecute(con, "PRAGMA synchronous = OFF"))
invisible(DBI::dbExecute(con, "PRAGMA temp_store = MEMORY"))
invisible(DBI::dbExecute(con, paste("ATTACH DATABASE", quoted_input, "AS source_db")))

source_table <- paste0("source_db.", quoted_collection)

source_count <- DBI::dbGetQuery(
  con,
  paste("SELECT COUNT(*) AS n FROM", source_table)
)$n
message("Source rows: ", format(source_count, big.mark = ","))

invisible(DBI::dbExecute(
  con,
  paste("CREATE TABLE", quoted_collection, "(_id TEXT PRIMARY_KEY NOT NULL, json JSONB)")
))

insert_sql <- paste(
  "INSERT INTO", quoted_collection, "(_id, json)",
  "SELECT _id, json FROM", source_table,
  "WHERE (abs(random()) / 9223372036854775807.0) <", sample_fraction
)
inserted <- DBI::dbExecute(con, insert_sql)

invisible(DBI::dbExecute(con, "DETACH DATABASE source_db"))
invisible(DBI::dbExecute(con, "VACUUM"))

output_size <- file.info(output_db)$size
message("Sample rows: ", format(inserted, big.mark = ","))
message("Output size: ", round(output_size / 1024^3, 2), " GB")
message("Done.")
