#!/usr/bin/env Rscript
# Substance v2: registry materialisation must be IDEMPOTENT, and retrieval must
# keep proposing the right answer rather than only the closest-looking one.
#
# Two independent concerns in one file because they share a corpus and both are
# cheap. Neither needs credentials, a network or money.
#
#   1. IDEMPOTENCE. C_mint --materialise folds the cluster cache into the
#      registry, and it must be safe to run twice. The sponsor version of this
#      bug resurrected 284 merged-away entities and re-pointed 527 assignments
#      on a single re-run, silently undoing every applied merge.
#
#   2. RETRIEVAL. The slate that reaches the model must CONTAIN the right
#      substance. It does not have to rank it first — and it usually does not:
#
#        metotrexate -> ketotrexate[0.80] metotrexato[0.80] ketotrexato[0.64]
#                       methotrexate[0.58]
#
#      That is why this asserts on membership, never on the top hit. A test that
#      demanded rank 1 would be asserting the very behaviour that makes fuzzy
#      matching wrong for drug names, and would "pass" only once the pipeline
#      had been broken into picking ketotrexate.
#
# Usage
#   Rscript tests/substance_v2_idempotence.R
#
# Read-only: it writes nothing. Exits 1 on failure.

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(purrr); library(stringi); library(stringr)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
root <- if (!is.na(script_path)) {
  normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
} else normalizePath(".")
pp <- function(...) file.path(root, ...)

source(pp("helper_scripts", "llm_norm", "registry.R"))
source(pp("helper_scripts", "llm_norm", "retrieve.R"))
source(pp("helper_scripts", "substance_norm_pipeline_v2", "substance_common.R"))

V2  <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
REG <- file.path(V2, "registry.csv")
ASG <- file.path(V2, "assignments.csv")
CL  <- file.path(V2, "C_mint_clusters.csv")
CH  <- file.path(V2, "chembl_cache.csv")
EP  <- file.path(V2, "epar_cache.csv")

failures <- 0L
ok <- function(cond, label, detail = "") {
  if (isTRUE(cond)) {
    cat(sprintf("  PASS  %s\n", label))
  } else {
    failures <<- failures + 1L
    cat(sprintf("  FAIL  %s%s\n", label, if (nzchar(detail)) paste0("  — ", detail) else ""))
  }
}

# ── 1. Synthetic idempotence ──────────────────────────────────────────────────
cat("\nsynthetic: a merged-away canonical resolves to its winner\n")

reg <- registry_empty()
add <- registry_add(reg, canonical = c("Methotrexate", "Methotrexate sodium"),
                    entity_type = "small_molecule")
reg <- add$registry
win <- add$entity_ids[[1]]; lose <- add$entity_ids[[2]]
asg <- assignments_empty("raw_substance") |>
  add_row(raw_substance = "Methotrexat 10mg", entity_id = win,  decided_by = "model") |>
  add_row(raw_substance = "methotrexate sodium", entity_id = lose, decided_by = "model")

out <- registry_apply_merges(reg, asg,
                             tibble(loser_id = lose, winner_id = win, reason = "salt rollup"))
reg2 <- out$registry; asg2 <- out$assignments
ok(nrow(registry_live(reg2)) == 1L, "merge applied, one live entity left")

clusters <- tibble(
  block_id = "b1", cluster_no = 1L,
  canonical = "Methotrexate sodium",           # the MERGED-AWAY canonical
  raw_substance = "methotrexate sodium", confidence = 0.9,
  entity_type = "small_molecule", salt_form = "sodium", brand = NA_character_,
  reason = NA_character_, model_id = "m", prompt_version = "p"
)
built <- registry_from_clusters(clusters, reg2, asg2, raw_col = "raw_substance")
ok(nrow(built$registry) == nrow(reg2),
   "no entity resurrected for a merged-away canonical",
   sprintf("%d -> %d rows", nrow(reg2), nrow(built$registry)))
ok(identical(built$assignments$entity_id[built$assignments$raw_substance == "methotrexate sodium"],
             win),
   "its raw string resolves to the merge WINNER")

# ── 2. Junk filter: the cases it got wrong before ─────────────────────────────
cat("\njunk filter: real substances survive, dosage language does not\n")

keep_these <- c(
  "Pembrolizumab concentrate for solution for infusion",  # v1 rejected this
  "Humira 40 mg solution for injection",                  # v1 rejected this
  "Methotrexat 10mg Tabletten",                           # v1 rejected this
  "PF-06480605", "KT-621", "K201", "MK-3475A",            # compound code names
  "18F-RO948",                                            # PET tracer
  "metotrexate", "Botox", "California"                    # model's call, not the filter's
)
drop_these <- c(
  "mL concentrate for solution for infusion",
  "ml Konzentrat zur Herstellung einer Infusionslösung",
  "Not yet assigned", "Not available", "300 mg", "A", "-", "ml"
)
kept_wrongly    <- drop_these[is.na(junk_reason(drop_these))]
dropped_wrongly <- keep_these[!is.na(junk_reason(keep_these))]
ok(length(dropped_wrongly) == 0L, "no real substance is filtered out",
   paste(dropped_wrongly, collapse = "; "))
ok(length(kept_wrongly) == 0L, "dosage language and placeholders are filtered out",
   paste(kept_wrongly, collapse = "; "))

# ── 3. Retrieval reaches the right substance ──────────────────────────────────
if (file.exists(CH)) {
  cat("\nretrieval: the right substance is IN the slate (not necessarily first)\n")
  ch <- read_csv(CH, show_col_types = FALSE, progress = FALSE)
  ep <- if (file.exists(EP)) read_csv(EP, show_col_types = FALSE, progress = FALSE) else NULL
  ref <- bind_rows(ep, ch) |>
    filter(nchar(alias_clean) >= 3, nchar(substance_clean) >= 3) |>
    distinct(alias_clean, substance_clean)

  vocab <- bind_rows(
    ref |> distinct(label = substance_clean) |> mutate(canon = label),
    ref |> transmute(label = alias_clean, canon = substance_clean)
  ) |> distinct(label, .keep_all = TRUE)

  idx <- build_index(vocab$label, ids = seq_len(nrow(vocab)), ngram_n = 3L,
                     generic = SUBSTANCE_GENERIC_TOKENS, drop_numeric = TRUE)

  # `expect` is matched as a PREFIX, because a salt or ester of the right INN is
  # the right answer at this stage — "TAGRISSO" reaching "osimertinib mesilate"
  # is retrieval working, and D_consolidate rolls the salt up afterwards. An
  # earlier version of this test demanded the bare INN and recorded two false
  # failures on exactly that.
  #
  # BNT162b2 expects "tozinameran" and not "bnt162b2": tozinameran IS the INN,
  # and ChEMBL's pref_name for that molecule. Also a false failure once.
  cases <- tribble(
    ~query,                              ~expect,
    "metotrexate",                       "methotrexate",
    "SODIO ASCORBATO",                   "sodium ascorbate",
    "PEGINTERFERON ALFA 2A",             "peginterferon alfa-2a",
    "Olopatadin Micro Labs 1 mg",        "olopatadine",
    "Dexamethason 4 mg JENAPHARM",       "dexamethasone",
    "BNT162b2",                          "tozinameran",
    "VELCADE 3.5 mg powder for solution for injection", "bortezomib",
    "TAGRISSO 80 mg film-coated tablets", "osimertinib"
  )
  for (i in seq_len(nrow(cases))) {
    hits <- retrieve(cases$query[[i]], idx, k = 10L, extra_channels = TRUE,
                     ngram_threshold = 0.30, interleave = TRUE,
                     use_ngram = TRUE, use_acronym = FALSE)
    got <- if (!nrow(hits)) character() else tolower(vocab$canon[hits$label_id])
    ok(any(startsWith(got, cases$expect[[i]])),
       sprintf("'%s' retrieves '%s'", cases$query[[i]], cases$expect[[i]]),
       if (!length(got)) "empty slate" else paste(head(got, 4), collapse = " | "))
  }

  # The trap, asserted explicitly: a top-ranked hit is NOT the answer. If this
  # ever starts passing by rank, someone has reintroduced fuzzy auto-accept.
  h <- retrieve("metotrexate", idx, k = 10L, extra_channels = TRUE,
                ngram_threshold = 0.30, interleave = TRUE,
                use_ngram = TRUE, use_acronym = FALSE)
  top <- if (nrow(h)) tolower(vocab$canon[h$label_id[[1L]]]) else ""
  ok(top != "methotrexate",
     "the metotrexate trap still holds (top hit is a DIFFERENT drug)",
     sprintf("top hit is '%s' — if this is now methotrexate, re-read why the model picks", top))
} else {
  cat("\nno chembl_cache.csv — retrieval checks skipped\n")
}

# ── 4. The live registry, if present ──────────────────────────────────────────
if (all(file.exists(REG, ASG, CL))) {
  cat("\nlive registry: full re-materialisation changes nothing\n")
  reg <- registry_read(REG)
  asg <- assignments_read(ASG, raw_col = "raw_substance")
  cl  <- read_csv(CL, show_col_types = FALSE, progress = FALSE)
  if ("prompt_version" %in% names(cl) && nrow(cl)) {
    newest <- sort(unique(stats::na.omit(cl$prompt_version)))
    cl <- cl |> filter(prompt_version == newest[[length(newest)]])
  }
  if ("substance_type" %in% names(cl)) cl <- cl |> rename(entity_type = substance_type)
  cl <- cl |> filter(!entity_type %in% "not_a_substance")

  # Mirror C_mint --materialise exactly: it re-joins minted canonicals onto
  # existing entities BEFORE materialising, and that step is what makes the pass
  # idempotent. Testing registry_from_clusters() alone tested a path the
  # pipeline never runs, and reported 159 phantom new entities because of it.
  cl <- rejoin_minted_canonicals(cl, reg, file.path(V2, "registry_aliases.csv"),
                                 verbose = FALSE)

  built <- registry_from_clusters(cl, reg, asg, raw_col = "raw_substance")
  ok(nrow(built$registry) == nrow(reg), "registry row count unchanged",
     sprintf("%d -> %d", nrow(reg), nrow(built$registry)))
  ok(nrow(registry_live(built$registry)) == nrow(registry_live(reg)),
     "live entity count unchanged")
  moved <- asg |> select(raw_substance, old = entity_id) |>
    inner_join(built$assignments |> select(raw_substance, new = entity_id),
               by = "raw_substance") |>
    filter(old != new)
  ok(nrow(moved) == 0L, "no existing assignment re-pointed",
     sprintf("%d re-pointed", nrow(moved)))
} else {
  cat("\nno mint clusters yet — live re-materialisation check skipped\n")
}

cat(sprintf("\n%s (%d failure%s)\n",
            if (failures == 0L) "ALL CHECKS PASSED" else "CHECKS FAILED",
            failures, if (failures == 1L) "" else "s"))
quit(save = "no", status = if (failures == 0L) 0L else 1L)
