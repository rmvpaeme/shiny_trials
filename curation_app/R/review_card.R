# The review card: one raw value, the normalisation proposed for it, the
# evidence behind that proposal, and the four things a reviewer can do about it.
#
# The proposed value is a selectize over existing canonical names rather than a
# free text box. Typing a name that does not exist offers to create it, but that
# path is flagged in the UI and recorded in the ledger — uncontrolled canonical
# creation is how near-duplicate canonicals accumulated in the first place.

# Sibling detach buttons need a fixed set of observers, so the number of
# sibling rows shown has to be bounded and known up front.
MAX_SIBLINGS <- 12L

review_card_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 330, position = "right", open = TRUE,
      shiny::h6("Decide"),
      shiny::actionButton(ns("accept"), "Accept", class = "btn-success w-100 mb-2"),
      shiny::actionButton(ns("save_edit"), "Save edit", class = "btn-primary w-100 mb-2"),
      shiny::actionButton(ns("reject"), "Reject", class = "btn-danger w-100 mb-2"),
      shiny::actionButton(ns("skip"), "Skip", class = "btn-outline-secondary w-100 mb-3"),
      shiny::textAreaInput(ns("comment"), "Comment", rows = 3,
                           placeholder = "Required when rejecting"),
      shiny::hr(),
      shiny::div(class = "d-flex gap-2",
        shiny::actionButton(ns("prev"), "← Prev", class = "btn-sm btn-outline-secondary"),
        shiny::actionButton(ns("nxt"), "Next →", class = "btn-sm btn-outline-secondary")
      ),
      shiny::hr(),
      shiny::checkboxInput(ns("hide_decided"), "Hide decided rows", value = TRUE),
      shiny::uiOutput(ns("scope_controls")),
      shiny::uiOutput(ns("progress"))
    ),
    shiny::uiOutput(ns("empty_notice")),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(
        bslib::card_header("Raw"),
        bslib::card_body(shiny::div(class = "raw-value", shiny::textOutput(ns("raw"))))
      ),
      bslib::card(
        bslib::card_header("Proposed"),
        bslib::card_body(
          shiny::selectizeInput(ns("proposed"), NULL, choices = NULL,
                                width = "100%",
                                options = list(
                                  create = TRUE,
                                  createOnBlur = TRUE,
                                  placeholder = "Search canonical names, or type a new one",
                                  maxOptions = 200
                                )),
          shiny::uiOutput(ns("new_canonical_warning")),
          shiny::uiOutput(ns("extra_fields"))
        )
      )
    ),
    bslib::layout_columns(
      col_widths = c(4, 4, 4),
      bslib::card(
        bslib::card_header("Evidence"),
        bslib::card_body(shiny::tableOutput(ns("evidence")))
      ),
      bslib::card(
        bslib::card_header("Other aliases mapping to this canonical"),
        bslib::card_body(shiny::uiOutput(ns("siblings")))
      ),
      bslib::card(
        bslib::card_header("Registered trials using this raw value"),
        bslib::card_body(shiny::uiOutput(ns("trials")))
      )
    )
  )
}

review_card_server <- function(id, tier, root, paths, reviewer, canonicals, on_decision) {
  # These are forced deliberately. This function is called from a for loop over
  # TIERS, and every argument below is used lazily inside observers — without
  # forcing, all six modules would bind to the loop's final tier.
  force(tier); force(root); force(paths); force(canonicals); force(on_decision)

  shiny::moduleServer(id, function(input, output, session) {

    rows      <- shiny::reactiveVal(NULL)
    cursor    <- shiny::reactiveVal(1L)
    decisions <- shiny::reactiveVal(NULL)

    refresh_decisions <- function() {
      led <- latest_decisions(read_ledger(paths))
      decisions(led[led$tier == tier$id, , drop = FALSE])
    }

    shiny::observeEvent(TRUE, once = TRUE, {
      rows(tier$loader(root))
      refresh_decisions()
    })

    decided_keys <- shiny::reactive({
      d <- decisions()
      if (is.null(d) || !nrow(d)) return(character())
      d$row_key[d$action %in% c("accept", "edit", "reject")]
    })

    min_impact_default <- if (is.null(tier$min_impact)) 0 else tier$min_impact
    auditable <- isTRUE(tier$auditable)

    output$scope_controls <- shiny::renderUI({
      if (!auditable) return(NULL)
      r <- rows()
      shiny::req(r)
      ns <- session$ns
      shiny::tagList(
        shiny::hr(),
        shiny::radioButtons(
          ns("mode"), "Scope",
          choices = c("Above threshold" = "head", "Audit sample of the tail" = "audit"),
          selected = "head"
        ),
        shiny::conditionalPanel(
          condition = sprintf("input['%s'] == 'head'", ns("mode")),
          shiny::sliderInput(ns("min_impact"),
                             sprintf("Minimum %s", tier$impact_label),
                             min = 0, max = 10, value = min_impact_default, step = 1)
        ),
        shiny::tags$small(class = "text-muted", shiny::uiOutput(ns("scope_note")))
      )
    })

    min_impact <- shiny::reactive({
      if (!auditable) return(0)
      if (identical(input$mode, "audit")) return(min_impact_default)
      if (is.null(input$min_impact)) min_impact_default else input$min_impact
    })

    # The audited set is drawn from the rows the threshold excludes, so
    # reviewing it measures exactly the population that is otherwise skipped.
    in_scope <- shiny::reactive({
      r <- rows()
      shiny::req(r)
      if (!auditable) return(r)
      if (identical(input$mode, "audit")) {
        audit_sample(r, tier$id, min_impact_default)
      } else {
        r[r$impact >= min_impact(), , drop = FALSE]
      }
    })

    output$scope_note <- shiny::renderUI({
      r <- rows(); shiny::req(r)
      if (identical(input$mode, "audit")) {
        tail_n <- sum(r$impact < min_impact_default)
        shiny::HTML(sprintf(
          "Reviewing %d of the %d rows below the threshold. Their error rate estimates the whole tail.",
          nrow(in_scope()), tail_n))
      } else {
        shiny::HTML(sprintf("%d of %d rows; %d excluded resolve nothing at all.",
                            nrow(in_scope()), nrow(r), sum(r$impact == 0)))
      }
    })

    visible <- shiny::reactive({
      r <- in_scope()
      shiny::req(r)
      if (isTRUE(input$hide_decided)) r <- r[!r$row_key %in% decided_keys(), , drop = FALSE]
      r
    })

    shiny::observeEvent(list(input$mode, input$min_impact), cursor(1L), ignoreInit = TRUE)

    current <- shiny::reactive({
      v <- visible()
      if (is.null(v) || !nrow(v)) return(NULL)
      i <- max(1L, min(cursor(), nrow(v)))
      v[i, , drop = FALSE]
    })

    # Populate the canonical pool server-side; both pools are far too large to
    # ship to the browser as static choices.
    shiny::observeEvent(current(), {
      cur <- current()
      shiny::req(cur)
      sel <- if (is.na(cur$proposed[[1]])) "" else cur$proposed[[1]]
      shiny::updateSelectizeInput(
        session, "proposed",
        choices  = canonicals,
        selected = sel,
        server   = TRUE
      )
      shiny::updateTextAreaInput(session, "comment", value = "")
    })

    output$empty_notice <- shiny::renderUI({
      v <- visible()
      if (!is.null(v) && nrow(v)) return(NULL)
      bslib::card(
        bslib::card_body(
          shiny::h5("Nothing left to review in this tier."),
          shiny::p("Untick “Hide decided rows” to revisit decisions already made.")
        )
      )
    })

    output$raw <- shiny::renderText({
      cur <- current(); if (is.null(cur)) return("")
      cur$raw[[1]]
    })

    is_new_canonical <- shiny::reactive({
      val <- input$proposed
      !is.null(val) && nzchar(val) && !val %in% canonicals
    })

    output$new_canonical_warning <- shiny::renderUI({
      if (!isTRUE(is_new_canonical())) return(NULL)
      shiny::div(
        class = "alert alert-warning py-2 px-3 mt-2 mb-0",
        shiny::strong("New canonical. "),
        "“", input$proposed, "” does not exist yet. Saving creates it — ",
        "check it is not a variant of an existing name first."
      )
    })

    output$extra_fields <- shiny::renderUI({
      cur <- current()
      if (is.null(cur) || !length(tier$extra_fields)) return(NULL)
      ns <- session$ns
      shiny::tagList(
        shiny::hr(),
        lapply(tier$extra_fields, function(f) {
          val <- if (f %in% names(cur) && !is.na(cur[[f]][[1]])) as.character(cur[[f]][[1]]) else ""
          if (!is.null(FIELD_CHOICES[[f]])) {
            # Fixed vocabulary — no free text, so synonyms cannot be invented.
            shiny::selectInput(
              ns(paste0("extra_", f)), f,
              choices  = c("(unset)" = "", FIELD_CHOICES[[f]]),
              selected = val, width = "100%"
            )
          } else if (f %in% POOL_FIELDS) {
            # Canonical sponsor names — same pool as `proposed`, server-side.
            shiny::selectizeInput(
              ns(paste0("extra_", f)), f, choices = NULL, width = "100%",
              options = list(create = TRUE, createOnBlur = TRUE, maxOptions = 200,
                             placeholder = "Search canonical names")
            )
          } else {
            shiny::textInput(ns(paste0("extra_", f)), f, value = val, width = "100%")
          }
        })
      )
    })

    # The pool-backed extra fields are created dynamically, so their choices
    # have to be pushed after the UI renders rather than at construction.
    shiny::observeEvent(current(), {
      cur <- current()
      shiny::req(cur)
      for (f in intersect(tier$extra_fields, POOL_FIELDS)) {
        val <- if (f %in% names(cur) && !is.na(cur[[f]][[1]])) as.character(cur[[f]][[1]]) else ""
        shiny::updateSelectizeInput(session, paste0("extra_", f),
                                    choices = canonicals, selected = val,
                                    server = TRUE)
      }
    })

    output$evidence <- shiny::renderTable({
      cur <- current(); if (is.null(cur)) return(NULL)
      fields <- intersect(tier$evidence, names(cur))
      if (!length(fields)) return(NULL)
      data.frame(
        field = fields,
        value = vapply(fields, function(f) {
          v <- cur[[f]][[1]]
          if (is.na(v)) "—" else as.character(v)
        }, character(1)),
        stringsAsFactors = FALSE
      )
    }, colnames = FALSE, width = "100%")

    siblings <- shiny::reactive({
      cur <- current(); if (is.null(cur)) return(NULL)
      sibling_aliases(root, tier$domain, cur$proposed[[1]], cur$raw[[1]],
                      limit = MAX_SIBLINGS)
    })

    output$siblings <- shiny::renderUI({
      sib <- siblings()
      if (is.null(sib) || !nrow(sib)) return(shiny::em("No other alias maps here."))
      ns <- session$ns
      shiny::tagList(
        shiny::tags$small(class = "text-muted d-block mb-2",
                          "Detach removes the alias from this canonical."),
        shiny::tags$ul(
          class = "list-unstyled mb-0",
          lapply(seq_len(nrow(sib)), function(i) {
            shiny::tags$li(
              class = "d-flex justify-content-between align-items-center gap-2 mb-1",
              shiny::span(
                sib$alias_clean[[i]],
                shiny::tags$small(class = "text-muted",
                                  paste0(" (", sib$source[[i]], ")"))
              ),
              if (isTRUE(sib$editable[[i]])) {
                shiny::actionButton(ns(paste0("detach_", i)), "Detach",
                                    class = "btn-sm btn-outline-danger py-0")
              } else {
                # Generated tiers are re-derived on rebuild, so an edit here
                # would not survive; say so rather than offer a dead button.
                shiny::tags$small(class = "text-muted", "generated")
              }
            )
          })
        )
      )
    })

    # Fixed set of observers, one per possible sibling slot — Shiny cannot
    # observe inputs that are created and destroyed per render.
    lapply(seq_len(MAX_SIBLINGS), function(i) {
      shiny::observeEvent(input[[paste0("detach_", i)]], {
        sib <- siblings()
        shiny::req(sib, nrow(sib) >= i, isTRUE(sib$editable[[i]]))
        cur <- current(); shiny::req(cur)
        home <- alias_home(tier$domain, sib$source[[i]])
        shiny::req(home)

        append_decision(paths, list(
          decision_id           = paste0(home$tier, "-",
                                         row_hash(sib$alias_clean[[i]], utc_now(), reviewer())),
          decided_at_utc        = utc_now(),
          reviewer              = reviewer(),
          tier                  = home$tier,
          domain                = tier$domain,
          source_file           = home$file,
          row_key               = sib$alias_clean[[i]],
          raw_value             = sib$alias_clean[[i]],
          proposed_value        = cur$proposed[[1]],
          final_value           = NA_character_,
          action                = "reject",
          created_new_canonical = "FALSE",
          extra_fields          = NA_character_,
          comment               = sprintf("detached from '%s' while reviewing '%s'",
                                          cur$proposed[[1]], cur$raw[[1]]),
          input_hash            = row_hash(sib$alias_clean[[i]], cur$proposed[[1]])
        ))
        refresh_decisions()
        on_decision()
        shiny::showNotification(sprintf("Detached '%s'", sib$alias_clean[[i]]),
                                duration = 2)
      }, ignoreInit = TRUE)
    })

    output$trials <- shiny::renderUI({
      cur <- current(); if (is.null(cur)) return(NULL)
      tr <- trial_references(root, tier$domain, cur$raw[[1]])
      if (!nrow(tr)) return(shiny::em("No registered trial found for this raw value."))

      # The country spread is usually what disambiguates a name — "UCL" on four
      # GB trials is University College London, not the Belgian UCL.
      countries <- tr$country[!is.na(tr$country)]
      summary <- if (length(countries)) {
        tab <- sort(table(countries), decreasing = TRUE)
        paste(sprintf("%s x%d", names(tab), as.integer(tab)), collapse = " · ")
      } else NULL

      shiny::tagList(
        if (!is.null(summary)) {
          shiny::div(class = "mb-2", shiny::strong("Countries: "), summary)
        },
        shiny::tags$ul(
          class = "list-unstyled mb-0",
          lapply(seq_len(min(nrow(tr), 15L)), function(i) {
            shiny::tags$li(
              shiny::tags$a(href = tr$url[[i]], target = "_blank", tr$id[[i]]),
              shiny::tags$small(class = "text-muted", paste0(" ", tr$register[[i]]))
            )
          })
        ),
        if (nrow(tr) > 15L) {
          shiny::tags$small(class = "text-muted",
                            sprintf("… and %d more (%d trials total)",
                                    nrow(tr) - 15L, nrow(tr)))
        }
      )
    })

    output$progress <- shiny::renderUI({
      r <- rows(); v <- visible()
      shiny::req(r)
      n_dec <- sum(r$row_key %in% decided_keys())
      shiny::div(
        shiny::tags$small(sprintf("%d decided / %d in tier", n_dec, nrow(r))),
        shiny::br(),
        shiny::tags$small(sprintf("Showing %d · position %d",
                                  nrow(v), min(cursor(), max(1L, nrow(v)))))
      )
    })

    # ── recording a decision ────────────────────────────────────────────────

    record <- function(action) {
      cur <- current()
      if (is.null(cur)) return(invisible(NULL))
      final <- input$proposed %||% ""
      comment <- trimws(input$comment %||% "")

      if (identical(action, "reject") && !nzchar(comment)) {
        shiny::showNotification("A comment is required when rejecting.", type = "warning")
        return(invisible(NULL))
      }
      if (action %in% c("accept", "edit") && !nzchar(final)) {
        shiny::showNotification("Pick or type a canonical value first.", type = "warning")
        return(invisible(NULL))
      }

      extras <- NULL
      if (length(tier$extra_fields)) {
        extras <- vapply(tier$extra_fields, function(f) {
          as.character(input[[paste0("extra_", f)]] %||% "")
        }, character(1))
        extras <- jsonlite::toJSON(as.list(extras), auto_unbox = TRUE)
      }

      decision <- list(
        decision_id           = paste0(tier$id, "-", row_hash(cur$row_key[[1]], utc_now(), reviewer())),
        decided_at_utc        = utc_now(),
        reviewer              = reviewer(),
        tier                  = tier$id,
        domain                = tier$domain,
        source_file           = tier$source_file,
        row_key               = cur$row_key[[1]],
        raw_value             = cur$raw[[1]],
        proposed_value        = cur$proposed[[1]],
        final_value           = if (identical(action, "reject")) NA_character_ else final,
        action                = action,
        created_new_canonical = if (isTRUE(is_new_canonical()) && action %in% c("accept", "edit")) "TRUE" else "FALSE",
        extra_fields          = if (is.null(extras)) NA_character_ else as.character(extras),
        comment               = if (nzchar(comment)) comment else NA_character_,
        input_hash            = row_hash(cur$raw[[1]], cur$proposed[[1]], cur$impact[[1]])
      )

      append_decision(paths, decision)

      # Queue tiers additionally carry the decision in the queue CSV, which is
      # the format curate_*.R --export already reads.
      if (!is.null(tier$queue) && action != "skip") {
        write_queue_decision(
          paths,
          queue_path    = file.path(root, tier$source_file),
          key_col       = tier$queue$key_col,
          row_key       = cur$row_key[[1]],
          decision      = if (identical(action, "reject")) "rejected" else "accepted",
          canonical     = decision$final_value,
          comment       = decision$comment %||% NA_character_,
          canonical_col = tier$queue$canonical_col
        )
      }

      refresh_decisions()
      on_decision()
      if (!isTRUE(input$hide_decided)) cursor(cursor() + 1L)
      shiny::showNotification(sprintf("Recorded: %s", action), duration = 1.5)
    }

    shiny::observeEvent(input$accept,    record("accept"))
    shiny::observeEvent(input$save_edit, record("edit"))
    shiny::observeEvent(input$reject,    record("reject"))
    shiny::observeEvent(input$skip,      record("skip"))

    shiny::observeEvent(input$nxt,  cursor(min(cursor() + 1L, max(1L, nrow(visible())))))
    shiny::observeEvent(input$prev, cursor(max(1L, cursor() - 1L)))

    shiny::observeEvent(input$hide_decided, cursor(1L))
  })
}

`%||%` <- function(a, b) if (is.null(a)) b else a
