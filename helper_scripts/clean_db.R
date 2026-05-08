library(ctrdata); library(nodbi); library(DBI); library(RSQLite)

DB_PATH <- "./data/trials.sqlite"
DB_COLLECTION <- "trials"

db <- nodbi::src_sqlite(dbname = DB_PATH, collection = DB_COLLECTION)
raw_con <- DBI::dbConnect(RSQLite::SQLite(), DB_PATH)

# ── 1. Remove known garbage IDs ───────────────────────────────────────────────
n_uuid <- DBI::dbExecute(raw_con,
  "DELETE FROM trials WHERE _id GLOB '????????-????-????-????-????????????'")
n_meta <- DBI::dbExecute(raw_con,
  "DELETE FROM trials WHERE _id = 'meta-info'")
n_3rd  <- DBI::dbExecute(raw_con,
  "DELETE FROM trials WHERE _id GLOB '*-3RD'")
message(sprintf("Removed: %d UUID(s), %d meta-info, %d -3RD", n_uuid, n_meta, n_3rd))

# ── 2. Remove records without a valid ctrname field ───────────────────────────
# ctrdata's dbFindIdsUniqueTrials fails when any record has ctrname=NA.
# These are records imported by an older method that did not set ctrname.
readable <- ctrdata:::.dbGetFieldsIntoDf(
  fields = c("_id", "ctrname"), con = db, verbose = FALSE)
message(sprintf("ctrdata-readable records: %d", nrow(readable)))

all_ids <- DBI::dbGetQuery(raw_con, "SELECT _id FROM trials")[[1]]
message(sprintf("Total SQL records: %d", length(all_ids)))

orphans <- setdiff(all_ids, readable[["_id"]])
message(sprintf("Records without valid ctrname: %d", length(orphans)))

if (length(orphans) > 0) {
  message("Sample orphan IDs: ", paste(head(orphans, 5), collapse = ", "))
  for (id in orphans)
    DBI::dbExecute(raw_con, "DELETE FROM trials WHERE _id = ?", list(id))
  message(sprintf("Deleted %d orphan records.", length(orphans)))
}

message(sprintf("Remaining records: %d",
                DBI::dbGetQuery(raw_con, "SELECT COUNT(*) FROM trials")[[1]]))
DBI::dbDisconnect(raw_con)
