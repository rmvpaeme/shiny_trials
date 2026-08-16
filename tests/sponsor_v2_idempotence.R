#!/usr/bin/env Rscript
# Registry materialisation must be IDEMPOTENT.
#
# `C_assign.R` re-materialises the entire mint cache into the registry on every
# invocation. That is fine only if doing so twice changes nothing. It did not:
# `registry_from_clusters()` built its canonical -> entity map from
# `registry_live()` alone, so a canonical whose entity had been merged away was
# not "known", was treated as fresh, and was minted again as a live duplicate.
#
# Measured on the real 7,238-row registry before the fix:
#
#     NEW entities created  : 284      (exactly the merged-away set)
#     assignments RE-POINTED: 527
#
# — i.e. one re-run silently undid every `D_consolidate --apply`, with no error
# and no visible symptom beyond the registry growing back. This script fails
# loudly on that class of regression.
#
# Usage
#   Rscript tests/sponsor_v2_idempotence.R
#
# Read-only: it writes nothing. Exits 1 on failure so CI or a pre-commit hook
# can use it.

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})

# Same root-resolution idiom as the pipeline scripts, so this runs from anywhere.
script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
root <- if (!is.na(script_path)) {
  normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
} else normalizePath(".")
pp <- function(...) file.path(root, ...)

source(pp("helper_scripts", "llm_norm", "registry.R"))

V2 <- Sys.getenv("SPONSOR_V2_DIR", unset = pp("config", "sponsor_norm_v2"))
REG <- file.path(V2, "registry.csv")
ASG <- file.path(V2, "assignments.csv")
CL  <- file.path(V2, "B_mint_clusters.csv")

failures <- 0L
ok <- function(cond, label, detail = "") {
  if (isTRUE(cond)) {
    cat(sprintf("  PASS  %s\n", label))
  } else {
    failures <<- failures + 1L
    cat(sprintf("  FAIL  %s%s\n", label, if (nzchar(detail)) paste0("  — ", detail) else ""))
  }
}

# ── 1. Synthetic fixture: runs anywhere, no live data needed ──────────────────
# Two entities with the same canonical, one merged into the other. Re-minting
# that canonical must resolve to the WINNER, not resurrect the loser.
cat("\nsynthetic: a merged-away canonical resolves to its winner\n")

reg <- registry_empty()
add <- registry_add(reg, canonical = c("Acme", "Acme Corp"), entity_type = "industry")
reg <- add$registry
win <- add$entity_ids[[1]]; lose <- add$entity_ids[[2]]
asg <- assignments_empty() |>
  add_row(raw_sponsor = "Acme Inc.", entity_id = win, decided_by = "model") |>
  add_row(raw_sponsor = "ACME CORP", entity_id = lose, decided_by = "model")

out <- registry_apply_merges(reg, asg,
                            tibble(loser_id = lose, winner_id = win, reason = "same"))
reg2 <- out$registry; asg2 <- out$assignments
ok(nrow(registry_live(reg2)) == 1L, "merge applied, one live entity left")

clusters <- tibble(
  block_id = "b1", cluster_no = 1L,
  canonical = "Acme Corp",                      # the MERGED-AWAY canonical
  raw_sponsor = "ACME CORP", confidence = 0.9,
  entity_type = "industry", legal_entity = NA_character_, parent = NA_character_,
  reason = NA_character_, model_id = "m", prompt_version = "p"
)
built <- registry_from_clusters(clusters, reg2, asg2)
ok(nrow(built$registry) == nrow(reg2),
   "no entity resurrected for a merged-away canonical",
   sprintf("%d -> %d rows", nrow(reg2), nrow(built$registry)))
ok(identical(built$assignments$entity_id[built$assignments$raw_sponsor == "ACME CORP"], win),
   "its raw string resolves to the merge WINNER")

# ── 2. The real registry, if present: full re-materialisation is a no-op ──────
if (all(file.exists(REG, ASG, CL))) {
  cat("\nlive registry: full re-materialisation changes nothing\n")
  reg <- registry_read(REG)
  asg <- assignments_read(ASG)
  cl  <- read_csv(CL, show_col_types = FALSE, progress = FALSE)
  if ("prompt_version" %in% names(cl)) {
    newest <- sort(unique(stats::na.omit(cl$prompt_version)))
    cl <- cl |> filter(prompt_version == newest[[length(newest)]])
  }

  built <- registry_from_clusters(cl, reg, asg)

  ok(nrow(built$registry) == nrow(reg),
     "registry row count unchanged",
     sprintf("%d -> %d (+%d)", nrow(reg), nrow(built$registry),
             nrow(built$registry) - nrow(reg)))
  ok(nrow(registry_live(built$registry)) == nrow(registry_live(reg)),
     "live entity count unchanged",
     sprintf("%d -> %d", nrow(registry_live(reg)), nrow(registry_live(built$registry))))

  moved <- asg |>
    select(raw_sponsor, old = entity_id) |>
    inner_join(built$assignments |> select(raw_sponsor, new = entity_id), by = "raw_sponsor") |>
    filter(old != new)
  ok(nrow(moved) == 0L, "no existing assignment re-pointed",
     sprintf("%d re-pointed", nrow(moved)))

  merged_before <- sum(!is.na(reg$merged_into) & nzchar(reg$merged_into))
  merged_after  <- sum(!is.na(built$registry$merged_into) & nzchar(built$registry$merged_into))
  ok(merged_before == merged_after, "merge records intact",
     sprintf("%d -> %d", merged_before, merged_after))
} else {
  cat("\nlive registry not present — synthetic checks only\n")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (failures == 0L) "ALL CHECKS PASSED" else "CHECKS FAILED",
            failures, if (failures == 1L) "" else "s"))
quit(save = "no", status = if (failures == 0L) 0L else 1L)
