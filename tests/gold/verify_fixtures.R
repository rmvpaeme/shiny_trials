#!/usr/bin/env Rscript
# Verify the frozen gold fixtures against their manifest.
#
# Run this before any scoring run. A benchmark whose bytes have drifted since it
# was frozen is not a benchmark, and the failure is silent unless something
# checks — so this is the thing that checks.
#
# Usage
#   Rscript tests/gold/verify_fixtures.R
#
# Exits non-zero on any mismatch, so it can gate a scoring run in a shell chain.

suppressPackageStartupMessages({
  library(readr)
  library(openssl)
})

script_path <- local({
  a <- commandArgs(FALSE)
  hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
fixture_dir <- file.path(if (!is.na(script_path)) dirname(script_path) else getwd(), "fixtures")

manifest_path <- file.path(fixture_dir, "sponsor_gold_v1_manifest.csv")
if (!file.exists(manifest_path)) {
  stop("No manifest at ", manifest_path, " — run build_gold_sample.R first.", call. = FALSE)
}

# Force character on every column: a 64-char hex string is character, but a
# manifest column that happened to be all digits would be guessed as numeric and
# compare unequal against the string it was written from.
manifest <- read_csv(manifest_path, show_col_types = FALSE, progress = FALSE,
                     col_types = cols(.default = col_character()))

# openssl::sha256() returns a classed object and as.character() KEEPS the class
# attribute, so identical() against a plain string from the manifest fails even
# when the bytes are equal. Strip attributes explicitly rather than falling back
# to ==, which would paper over a genuine type mismatch.
file_sha256 <- function(path) {
  con <- file(path, "rb")
  on.exit(close(con), add = TRUE)
  hex <- as.character(openssl::sha256(con))
  attributes(hex) <- NULL
  hex
}

ok <- TRUE
cat("verifying ", nrow(manifest), " fixtures against the manifest\n\n", sep = "")
for (i in seq_len(nrow(manifest))) {
  name     <- manifest$file[[i]]
  expected <- manifest$sha256[[i]]
  path     <- file.path(fixture_dir, name)

  if (!file.exists(path)) {
    cat(sprintf("  %-40s MISSING\n", name)); ok <- FALSE; next
  }
  actual <- file_sha256(path)
  if (identical(actual, expected)) {
    cat(sprintf("  %-40s ok    %s\n", name, substr(actual, 1L, 12L)))
  } else {
    cat(sprintf("  %-40s DRIFT\n      expected %s\n      actual   %s\n", name, expected, actual))
    ok <- FALSE
  }
}

if (!ok) {
  cat("\nFixtures have drifted from the manifest. Do not score against them.\n")
  quit(status = 1L)
}
cat("\nAll fixtures match the manifest.\n")
