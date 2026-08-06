# Replay the decision ledger onto the config files.
#
# Usage:
#   Rscript curation_app/apply.R            # dry run — report only
#   Rscript curation_app/apply.R --write    # apply
#
# Scope: the alias tiers only. Queue-tier decisions are already written into
# the queue CSVs by the app, and the existing exporters fan those out:
#   Rscript helper_scripts/sponsor_norm_pipeline/curate_sponsors.R --export
#   Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --export
#
# Idempotent: the ledger is replayed from scratch every run and the latest
# decision per (tier, row_key) wins, so running twice changes nothing the
# second time.
#
# What each action does to an alias row:
#   accept  source -> "manual"   (a human has now actually verified it)
#   edit    canonical + extra fields updated, source -> "manual"
#   reject  row removed from the alias table, alias added to negative aliases
#   skip    ignored

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

apply_main <- function(root, write = FALSE) {
  paths  <- store_paths(root)
  ledger <- latest_decisions(read_ledger(paths))
  if (!nrow(ledger)) {
    message("Ledger is empty — nothing to apply.")
    return(invisible(NULL))
  }

  alias_tiers <- list(
    sponsor_aliases = list(
      file      = file.path(root, "config", "sponsor_norm_pipeline", "manual_sponsor_aliases.csv"),
      key       = "alias_clean",
      canonical = "sponsor_clean",
      negatives = file.path(root, "config", "sponsor_norm_pipeline", "sponsor_negative_aliases.csv")
    ),
    substance_aliases = list(
      file      = file.path(root, "config", "substance_norm_pipeline", "manual_brand_to_substance.csv"),
      key       = "alias_clean",
      canonical = "substance_clean",
      negatives = file.path(root, "config", "substance_norm_pipeline", "negative_aliases.csv")
    ),
    substance_canonicals = list(
      file      = file.path(root, "config", "substance_norm_pipeline", "canonical_substances.csv"),
      key       = "substance_clean",
      canonical = "parent_substance",
      negatives = NULL
    ),
    # Not review tiers of their own — these receive "detach" rejections raised
    # from the sibling panel while reviewing some other row.
    sponsor_llm_reviewed = list(
      file      = file.path(root, "config", "sponsor_norm_pipeline", "sponsor_llm_reviewed.csv"),
      key       = "alias_clean",
      canonical = "sponsor_clean",
      negatives = file.path(root, "config", "sponsor_norm_pipeline", "sponsor_negative_aliases.csv")
    ),
    substance_llm_reviewed = list(
      file      = file.path(root, "config", "substance_norm_pipeline", "substance_llm_reviewed.csv"),
      key       = "alias_clean",
      canonical = "substance_clean",
      negatives = file.path(root, "config", "substance_norm_pipeline", "negative_aliases.csv")
    )
  )

  for (tier_id in names(alias_tiers)) {
    spec <- alias_tiers[[tier_id]]
    dec  <- ledger[ledger$tier == tier_id & ledger$action %in% c("accept", "edit", "reject"), , drop = FALSE]
    if (!nrow(dec)) next
    if (!file.exists(spec$file)) {
      warning("Missing target file, skipping tier ", tier_id, ": ", spec$file)
      next
    }

    d   <- readr::read_csv(spec$file, show_col_types = FALSE, progress = FALSE)
    eol <- detect_eol(spec$file)
    n_accept <- 0L; n_edit <- 0L; n_reject <- 0L
    rejected_aliases <- character()

    for (i in seq_len(nrow(dec))) {
      row <- dec[i, ]
      idx <- which(as.character(d[[spec$key]]) == row$row_key)
      if (!length(idx)) next

      if (identical(row$action, "reject")) {
        rejected_aliases <- c(rejected_aliases, row$row_key)
        d <- d[-idx, , drop = FALSE]
        n_reject <- n_reject + 1L
        next
      }

      if (identical(row$action, "edit") && !is.na(row$final_value)) {
        d[[spec$canonical]][idx] <- row$final_value
        # Extra editable fields travel as a JSON object in the ledger.
        if (!is.na(row$extra_fields) && nzchar(row$extra_fields)) {
          extras <- tryCatch(jsonlite::fromJSON(row$extra_fields), error = function(e) NULL)
          if (is.list(extras) || is.character(extras)) {
            for (f in names(extras)) {
              val <- as.character(extras[[f]])
              if (f %in% names(d) && length(val) == 1L && nzchar(val)) d[[f]][idx] <- val
            }
          }
        }
        n_edit <- n_edit + 1L
      } else {
        n_accept <- n_accept + 1L
      }

      # Verified by a person — this is the only place `manual` is ever written.
      if ("source" %in% names(d)) d[["source"]][idx] <- "manual"
    }

    message(sprintf("%-22s accept=%d edit=%d reject=%d", tier_id, n_accept, n_edit, n_reject))

    if (write) {
      write_csv_atomic(d, spec$file, eol = eol)
      if (length(rejected_aliases) && !is.null(spec$negatives) && file.exists(spec$negatives)) {
        neg <- readr::read_csv(spec$negatives, show_col_types = FALSE, progress = FALSE)
        add <- tibble::tibble(
          alias_clean = setdiff(unique(rejected_aliases), neg$alias_clean),
          reason      = "rejected during human review"
        )
        if (nrow(add)) {
          write_csv_atomic(dplyr::bind_rows(neg, add), spec$negatives,
                           eol = detect_eol(spec$negatives))
        }
      }
    }
  }

  if (!write) {
    message("\nDry run — nothing written. Re-run with --write to apply.")
  } else {
    message("\nApplied. Rebuild the indexes to pick the changes up:")
    message("  Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror")
    message("  Rscript helper_scripts/substance_norm_pipeline/build_substance_index.R --use-chembl-cache")
  }
  invisible(NULL)
}

# Run standalone (not when sourced by Shiny, which has no --file= argument
# pointing at this script).
if (!interactive() && any(grepl("apply\\.R$", commandArgs(FALSE)))) {
  file_arg <- commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1]
  here <- dirname(normalizePath(sub("^--file=", "", file_arg)))
  root <- normalizePath(file.path(here, ".."))
  source(file.path(here, "R", "store.R"), local = FALSE)
  source(file.path(here, "R", "tiers.R"), local = FALSE)
  apply_main(root, write = "--write" %in% commandArgs(trailingOnly = TRUE))
}
