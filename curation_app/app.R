# Normalisation reviewer — human verification of low-confidence normalisations.
#
# Standalone from the main dashboard app.R: this one writes to config/, is not
# part of the deployed bundle (manifest.json is an explicit 7-file allowlist),
# and exists so the sponsor/substance normalisations that were only ever
# LLM-curated can actually be checked by a person.
#
# Run:  Rscript -e 'shiny::runApp("curation_app")'
#
# Environment:
#   REVIEWER  default reviewer name (falls back to the OS user)

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(dplyr)
  library(readr)
})

# Shiny auto-sources curation_app/R/*.R before this file runs.

find_project_root <- function(start = getwd()) {
  d <- normalizePath(start, mustWork = TRUE)
  for (i in 1:6) {
    if (dir.exists(file.path(d, "config", "sponsor_norm_pipeline"))) return(d)
    parent <- dirname(d)
    if (identical(parent, d)) break
    d <- parent
  }
  stop("Could not locate the project root (no config/sponsor_norm_pipeline above ", start, ")")
}

ROOT   <- find_project_root()
PATHS  <- store_paths(ROOT)
POOLS  <- list(
  sponsor   = canonical_pool(ROOT, DOMAIN_SPONSOR),
  substance = canonical_pool(ROOT, DOMAIN_SUBSTANCE)
)

default_reviewer <- function() {
  from_env <- Sys.getenv("REVIEWER", unset = "")
  if (nzchar(from_env)) return(from_env)
  unname(Sys.info()[["user"]] %||% "unknown")
}

# ── UI ────────────────────────────────────────────────────────────────────────

tier_panel <- function(tier) {
  bslib::nav_panel(title = tier$label, value = tier$id, review_card_ui(tier$id))
}

ui <- bslib::page_navbar(
  title = "Normalisation reviewer",
  id = "nav",
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  header = shiny::tagList(
    shiny::tags$style(shiny::HTML("
      .raw-value { font-size: 1.35rem; font-weight: 600; word-break: break-word; }
      .table td { padding: .25rem .5rem; }
    ")),
    shiny::div(
      class = "container-fluid py-2",
      shiny::div(
        class = "d-flex align-items-center gap-3",
        shiny::tags$label("Reviewer", class = "form-label mb-0"),
        shiny::div(style = "width: 220px;",
                   shiny::textInput("reviewer", NULL, value = default_reviewer(),
                                    width = "100%")),
        shiny::tags$small(class = "text-muted",
                          "Recorded against every decision in the ledger.")
      )
    )
  ),
  !!!unname(lapply(TIERS, tier_panel)),
  bslib::nav_spacer(),
  bslib::nav_panel(
    title = "Progress", value = "progress",
    bslib::layout_columns(
      col_widths = c(4, 8),
      bslib::card(
        bslib::card_header("Totals"),
        bslib::card_body(shiny::tableOutput("summary_totals"))
      ),
      bslib::card(
        bslib::card_header("By tier"),
        bslib::card_body(shiny::tableOutput("summary_by_tier"))
      )
    ),
    bslib::card(
      bslib::card_header("Decision ledger"),
      bslib::card_body(
        shiny::downloadButton("download_ledger", "Download ledger CSV",
                              class = "btn-sm btn-outline-primary mb-3"),
        DT::DTOutput("ledger_table")
      )
    )
  )
)

# ── server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  reviewer <- shiny::reactive({
    r <- trimws(input$reviewer %||% "")
    if (nzchar(r)) r else default_reviewer()
  })

  ledger_bump <- shiny::reactiveVal(0L)
  on_decision <- function() ledger_bump(ledger_bump() + 1L)

  for (tier in TIERS) {
    review_card_server(
      id          = tier$id,
      tier        = tier,
      root        = ROOT,
      paths       = PATHS,
      reviewer    = reviewer,
      canonicals  = POOLS[[tier$domain]],
      on_decision = on_decision
    )
  }

  ledger <- shiny::reactive({
    ledger_bump()
    read_ledger(PATHS)
  })

  output$summary_totals <- shiny::renderTable({
    led <- latest_decisions(ledger())
    if (!nrow(led)) return(data.frame(metric = "decisions", value = 0L))
    data.frame(
      metric = c("rows decided", "accepted", "edited", "rejected", "skipped",
                 "new canonicals created", "reviewers"),
      value  = c(
        nrow(led),
        sum(led$action == "accept"),
        sum(led$action == "edit"),
        sum(led$action == "reject"),
        sum(led$action == "skip"),
        sum(led$created_new_canonical == "TRUE", na.rm = TRUE),
        dplyr::n_distinct(led$reviewer)
      ),
      stringsAsFactors = FALSE
    )
  }, colnames = FALSE, width = "100%")

  output$summary_by_tier <- shiny::renderTable({
    led <- latest_decisions(ledger())
    totals <- data.frame(
      tier  = vapply(TIERS, `[[`, character(1), "id"),
      label = vapply(TIERS, `[[`, character(1), "label"),
      stringsAsFactors = FALSE
    )
    totals$rows <- vapply(TIERS, function(t) {
      tryCatch(nrow(t$loader(ROOT)), error = function(e) NA_integer_)
    }, numeric(1))
    if (nrow(led)) {
      counts <- led |>
        dplyr::filter(action %in% c("accept", "edit", "reject")) |>
        dplyr::count(tier, name = "decided")
      totals <- dplyr::left_join(totals, counts, by = "tier")
    } else {
      totals$decided <- 0L
    }
    totals$decided <- dplyr::coalesce(totals$decided, 0L)
    totals$remaining <- totals$rows - totals$decided
    totals[, c("label", "rows", "decided", "remaining")]
  }, width = "100%")

  output$ledger_table <- DT::renderDT({
    led <- ledger()
    if (!nrow(led)) {
      return(DT::datatable(data.frame(message = "No decisions recorded yet."),
                           rownames = FALSE, options = list(dom = "t")))
    }
    DT::datatable(
      led[rev(seq_len(nrow(led))),
          c("decided_at_utc", "reviewer", "tier", "row_key", "proposed_value",
            "final_value", "action", "created_new_canonical", "comment")],
      rownames = FALSE,
      filter   = "top",
      options  = list(pageLength = 25, scrollX = TRUE)
    )
  })

  output$download_ledger <- shiny::downloadHandler(
    filename = function() sprintf("review_decisions_%s.csv", format(Sys.Date())),
    content  = function(file) readr::write_csv(ledger(), file, na = "")
  )
}

shiny::shinyApp(ui, server)
