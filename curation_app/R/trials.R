# ══════════════════════════════════════════════════════════════════════════════
# TAB 1 — TRIAL VALIDATION
# ══════════════════════════════════════════════════════════════════════════════
#
# The SAME raw-vs-normalised overview the dashboard shows in its trial-detail
# modal, with each field clickable to correct it.
#
# The first version put eighteen input widgets in a sidebar. That is a form, not
# a review: it asks the reviewer to scan eighteen controls to find the one thing
# that is wrong, and it looks nothing like the screen they already know. Reading
# comes first — raw beside normalised, one row per field — and editing is what
# happens when a row looks wrong.
#
# ── The routing split ─────────────────────────────────────────────────────────
#
# Sponsor and substance corrections are keyed on the RAW STRING and go to the
# registry, so they fix every trial carrying it. Everything else becomes a
# per-trial override. The editor says which, every time, before saving.

# Deliberately short. The full title, substance, condition, countries and
# participant count all appear in the detail panel beside their raw values, so
# repeating them here only makes every row tall enough to hide the panel. The
# title is truncated rather than dropped: it is how a human recognises a trial.
TRIAL_TABLE_COLS <- c("CT_number", "title_short", "sponsor_label", "phase", "status", "year")

trials_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::div(
    class = "p-2",
    shiny::uiOutput(ns("filters")),
    bslib::layout_columns(
      col_widths = c(5, 7),
      # overflow-x on the COLUMN, not the page: without it the table renders at
      # its natural width, spills out of its 5/12 track and the detail panel is
      # drawn on top of it.
      shiny::div(style = "overflow-x:auto; min-width:0;", DT::DTOutput(ns("table"))),
      bslib::card(
        class = "p-3",
        shiny::uiOutput(ns("detail_header")),
        shiny::uiOutput(ns("detail")),
        shiny::uiOutput(ns("sign_off"))
      )
    )
  )
}

trials_server <- function(id, db, session_user, cache, snapshot = snapshot_current) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    snap <- shiny::reactive(snapshot())

    editable_fields <- Filter(function(f) isTRUE(f$editable), TRIAL_FIELD_SPEC)

    # The canonical pools, for the sponsor and substance pickers. Same loader
    # tab 2 uses, so both screens offer exactly the same live entities — and
    # merged-away ones are excluded in both.
    registries <- shiny::reactive({
      sp <- snap(); if (is.null(sp)) return(list())
      list(sponsor   = norm_registry_load(sp, "sponsor"),
           substance = norm_registry_load(sp, "substance"))
    })

    entity_domain <- function(f) {
      if (identical(f$route, "sponsor_registry")) "sponsor"
      else if (identical(f$route, "substance_registry")) "substance" else NA_character_
    }

    output$filters <- shiny::renderUI({
      shiny::req(!is.null(cache))
      shiny::div(class = "d-flex gap-2 align-items-end mb-2",
        # Defaults to the reviewer's own assignment. 51,311 trials will never
        # all be validated; a stratified sample is drawn and split, and browsing
        # the whole corpus is the exception rather than the starting point.
        shiny::selectInput(ns("scope"), "Show",
          choices = c("My assigned sample" = "mine", "All trials" = "all"),
          selected = "mine", width = "190px"),
        # Which round. A validation can be redone, so several draws coexist and
        # the reviewer says which one they are working through.
        shiny::selectInput(ns("draw"), "Review round", choices = NULL, width = "230px"),
        shiny::textInput(ns("search"), "Search title, sponsor, substance or CT number",
                         width = "360px"),
        shiny::selectInput(ns("register"), "Register",
                           choices = c("All", sort(unique(stats::na.omit(cache$register)))),
                           width = "130px"),
        shiny::checkboxInput(ns("only_undecided"), "Hide trials already reviewed", value = FALSE))
    })

    my_draws <- shiny::reactive({
      reviewed_tick()
      shiny::invalidateLater(20000, session)
      u <- session_user()
      if (is.null(u) || is.null(db)) return(NULL)
      tryCatch(sample_choices_for_reviewer(db, u$username), error = function(e) NULL)
    })

    shiny::observeEvent(my_draws(), {
      d <- my_draws()
      if (is.null(d) || !nrow(d)) {
        shiny::updateSelectInput(session, "draw", choices = character())
        return()
      }
      ch <- stats::setNames(d$sample_id, sprintf("%s (%s assigned)", d$label, d$assigned))
      # Keep the reviewer where they were if that round still exists; otherwise
      # start them on the newest.
      cur <- shiny::isolate(input$draw)
      shiny::updateSelectInput(session, "draw", choices = ch,
        selected = if (!is.null(cur) && cur %in% ch) cur else ch[[1]])
    })

    assigned <- shiny::reactive({
      reviewed_tick()
      # Polled, because a sample drawn in the ADMIN tab must appear here. This
      # reactive otherwise only invalidates when the reviewer signs a trial off,
      # so a draw made after the page loaded left tab 1 showing the empty
      # assignment it computed at load — "works after a reload", which is the
      # worst kind of working.
      shiny::invalidateLater(20000, session)
      u <- session_user()
      if (is.null(u) || is.null(db)) return(NULL)
      # Errors are SURFACED, not swallowed. The previous version returned NULL
      # on any failure, so a permissions problem and "no sample drawn yet"
      # produced an identical empty table — the same blindness that made the
      # login failure take an afternoon.
      tryCatch(sample_for_reviewer(db, u$username, input$draw),
               error = function(e) {
                 message("trial validation: could not read the assignment for ",
                         u$username, ": ", conditionMessage(e))
                 structure(data.frame(), class = c("assignment_error", "data.frame"))
               })
    })

    output$assignment_progress <- shiny::renderUI({
      a <- assigned(); if (is.null(a) || !nrow(a)) return(NULL)
      done <- sum(a$trial_id %in% my_reviews())
      shiny::div(class = "small text-muted mb-2",
        sprintf("%d of %d assigned trials reviewed", done, nrow(a)),
        if (any(a$is_overlap))
          sprintf(" · %d also assigned to someone else, to measure agreement",
                  sum(a$is_overlap)))
    })

    reviewed_tick <- shiny::reactiveVal(0)
    my_reviews <- shiny::reactive({
      reviewed_tick()
      if (is.null(db)) return(character())
      tryCatch(latest_trial_reviews(db)$trial_id, error = function(e) character())
    })

    filtered <- shiny::reactive({
      d <- cache; shiny::req(!is.null(d))
      if (identical(input$scope %||% "mine", "mine")) {
        a <- assigned()
        # An empty assignment means no sample has been drawn for this reviewer
        # yet. Showing all 51,311 instead would silently defeat the sampling.
        d <- if (is.null(a) || !nrow(a)) d[0, , drop = FALSE]
             else d[d$`_id` %in% a$trial_id, , drop = FALSE]
      }
      q <- input$search %||% ""
      if (nzchar(q)) {
        # A few named columns, not all 81: a grepl across the whole frame on
        # every keystroke is not interactive at 51k rows.
        hit <- Reduce(`|`, lapply(c("Full_title", "sponsor_label", "substance_label", "CT_number"),
          function(cn) if (cn %in% names(d)) grepl(q, d[[cn]] %||% "", ignore.case = TRUE)
                       else rep(FALSE, nrow(d))))
        d <- d[which(hit), , drop = FALSE]
      }
      if (!identical(input$register, "All") && !is.null(input$register))
        d <- d[d$register %in% input$register, , drop = FALSE]
      if (isTRUE(input$only_undecided)) d <- d[!d$`_id` %in% my_reviews(), , drop = FALSE]
      d
    })

    output$table <- DT::renderDT({
      d <- filtered()
      # An empty table has several causes and they need different actions.
      shiny::validate(shiny::need(!is.null(d) && nrow(d),
        if (!identical(input$scope %||% "mine", "mine")) "No trials match."
        else if (inherits(assigned(), "assignment_error"))
          "Could not read your assignment from the database — see the app log."
        else if (is.null(assigned()) || !nrow(assigned()))
          paste("No trials are assigned to you. An admin draws the review sample",
                "in Admin -> Review sample. This list refreshes within 20 seconds",
                "of a draw.")
        else "Your assigned trials are not in this snapshot — refresh it in Admin."))
      d$title_short <- substr(d$Full_title %||% "", 1, 70)
      # No filter = "top": a row of per-column boxes above five columns is more
      # chrome than the table itself, and the search box above already covers
      # the fields anyone searches on.
      tbl <- head(d[, intersect(TRIAL_TABLE_COLS, names(d)), drop = FALSE], 5000)
      names(tbl) <- c("CT number", "Title", "Sponsor", "Phase", "Status", "Year")[
        match(names(tbl), TRIAL_TABLE_COLS)]
      DT::datatable(
        tbl, selection = "single", rownames = FALSE, width = "100%",
        options = list(
          pageLength = 15, lengthChange = FALSE,
          # scrollX keeps the overflow INSIDE the table rather than letting it
          # push into the neighbouring column.
          scrollX = TRUE, autoWidth = FALSE,
          # Without no-wrap a 70-character title becomes three lines and one row
          # is taller than the whole panel beside it.
          columnDefs = list(list(targets = "_all", className = "dt-nowrap")),
          dom = "tip"))
    }, server = TRUE)

    row <- shiny::reactive({
      i <- input$table_rows_selected; d <- filtered()
      if (is.null(i) || !length(i) || is.null(d) || !nrow(d)) return(NULL)
      d[i[1], , drop = FALSE]
    })

    shown_at <- shiny::reactiveVal(Sys.time())
    shiny::observeEvent(row(), shown_at(Sys.time()))

    saved_tick <- shiny::reactiveVal(0)
    # A reviewer's own pending edits, so the screen shows what they already did
    # rather than the pipeline value they have just corrected. Labelled pending,
    # because it is not live until the nightly runs.
    pending <- shiny::reactive({
      saved_tick()
      r <- row(); if (is.null(r) || is.null(db)) return(NULL)
      tryCatch(latest_trial_decisions(db, r$`_id`), error = function(e) NULL)
    })

    output$detail_header <- shiny::renderUI({
      r <- row()
      if (is.null(r)) return(shiny::div(class = "text-muted", "Select a trial below."))
      shiny::div(
        class = "mb-2",
        shiny::tags$strong(show_val(r$CT_number)),
        shiny::tags$a(" open ↗", href = trial_link(r), target = "_blank", class = "small"),
        shiny::p(class = "small text-muted mt-1 mb-0", show_val(r$Full_title)))
    })

    # ── The overview: raw beside normalised, one row per field ────────────────
    #
    # Same shape as the dashboard's trial-detail modal, so a reviewer is reading
    # a screen they already know. The only addition is that an editable row is a
    # link.
    render_group <- function(r, group, header) {
      rows <- field_rows(r, group = group)
      pend <- pending()
      spec_by_id <- stats::setNames(TRIAL_FIELD_SPEC,
                                    vapply(TRIAL_FIELD_SPEC, function(f) f$id, character(1)))
      shiny::tagList(
        shiny::h6(header, class = "mt-3"),
        shiny::tags$table(
          class = "table table-sm table-bordered align-middle",
          style = "font-size:12px;",
          shiny::tags$thead(shiny::tags$tr(
            shiny::tags$th(style = "width:20%;", "Field"),
            shiny::tags$th(style = "width:36%;", "What the register said"),
            shiny::tags$th(style = "width:36%;", "What the app shows"),
            shiny::tags$th(style = "width:8%;", ""))),
          shiny::tags$tbody(lapply(rows, function(x) {
            f <- spec_by_id[[x$id]]
            p <- if (!is.null(pend) && nrow(pend)) pend[pend$field_id == x$id, ] else NULL
            has_pending <- !is.null(p) && nrow(p) && identical(p$action[[1]], "override")
            # One signal, not a taxonomy: the row is tinted when the app's value
            # differs from the register's. That is the only distinction a
            # reviewer needs to decide where to look, and it needs no
            # explanation of how the pipeline works.
            differs <- identical(x$change, "changed")
            shiny::tags$tr(
              style = if (differs) "background-color:#fff8e1;" else NULL,
              shiny::tags$th(x$label),
              shiny::tags$td(
                if (identical(x$raw_status, "absent"))
                  shiny::tags$span(class = "text-muted", "\u2014")
                # A bare dash on a field the register never reports reads as
                # missing data. Where the reason is known, say it.
                else if ((is.na(x$raw) || !nzchar(trimws(x$raw))) && !is.na(x$no_source))
                  shiny::tags$span(class = "text-muted fst-italic", x$no_source)
                else show_val(x$raw)),
              shiny::tags$td(
                if (has_pending)
                  shiny::tagList(
                    shiny::tags$span(p$final_value[[1]]),
                    shiny::tags$span(class = "badge bg-warning text-dark ms-1",
                                     title = "saved, live after tonight's rebuild", "pending"))
                else show_val(x$norm)),
              shiny::tags$td(
                if (isTRUE(f$editable))
                  shiny::actionLink(ns(paste0("edit_", x$id)), "edit", class = "small")
                else shiny::tags$span(class = "text-muted small", "\u2014")))
          }))))
    }

    # Which fields cannot show the register's value with THIS data file.
    #
    # The app reads the cache published on the deploy branch, which is built
    # from main. Between adding a field's raw column and that reaching main,
    # the published cache has the normalised value and not the register's. That
    # is one fact about the data file — worth saying once, not on five rows of
    # every trial, and it disappears on its own.
    missing_sources <- shiny::reactive({
      if (is.null(cache)) return(character())
      vapply(Filter(function(f) length(f$raw_cols) &&
                                !any(f$raw_cols %in% names(cache)), TRIAL_FIELD_SPEC),
             function(f) f$label, character(1))
    })

    output$detail <- shiny::renderUI({
      require_role(session)
      r <- row()
      if (is.null(r)) return(shiny::div(class = "text-muted p-2",
        "Select a trial to see how it was recoded."))
      shiny::div(
        class = "curation-fields",
        # One sentence, no jargon. Someone who has never heard of the pipeline
        # should be able to start reviewing from this line alone.
        shiny::div(class = "alert alert-light border py-2 small mb-2",
          shiny::strong("Highlighted rows are where the app's value differs from the register's. "),
          "Check those first. Click ", shiny::tags$em("edit"), " on any row that looks wrong. ",
          shiny::tags$span(class = "text-muted",
            "A dash means the register did not supply that field.")),
        if (length(missing_sources()))
          shiny::div(class = "alert alert-warning py-2 small mb-2",
            shiny::strong("This data file cannot show the register's own wording for: "),
            paste(missing_sources(), collapse = ", "), ". ",
            shiny::span(class = "text-muted",
              "Their values are correct; only the comparison is unavailable. ",
              "Resolved by the next nightly rebuild.")),
        render_group(r, "entities", "Trial details"),
        render_group(r, "status", "Dates, status and results"))
    })

    # ── One editor, one field ─────────────────────────────────────────────────
    #
    # The observers are created ONCE, here, from a static field list — not
    # inside the renderUI. Shiny cannot observe inputs that are re-created on
    # every render, and the legacy app hit exactly this: it needed a fixed pool
    # of observers for the same reason. lapply + force, never a for loop, or
    # every link edits the last field.
    editing <- shiny::reactiveVal(NULL)
    lapply(editable_fields, function(f) {
      force(f)
      shiny::observeEvent(input[[paste0("edit_", f$id)]], {
        r <- row(); if (is.null(r)) return()
        editing(f$id)
        cur <- Filter(function(x) x$id == f$id, field_rows(r))[[1]]
        registry_scope <- f$route %in% c("sponsor_registry", "substance_registry")
        shiny::showModal(shiny::modalDialog(
          title = paste("Edit:", f$label),
          size = "m", easyClose = TRUE,
          shiny::div(class = "small text-muted mb-1", shiny::tags$em("The register sent: "),
                     show_val(cur$raw)),
          shiny::div(class = "small text-muted mb-3", shiny::tags$em("Currently shown as: "),
                     show_val(cur$norm)),
          if (!is.na(entity_domain(f)))
            shiny::uiOutput(ns("new_canonical_warning")),
          switch(f$control,
            # Server-side and empty at render: 6,954 sponsor and 19,645
            # substance canonicals must not ship to the browser. Populated by
            # the updateSelectizeInput below, once the input exists.
            entity = shiny::selectizeInput(ns("edit_value"), f$label,
                       choices = NULL, selected = cur$norm,
                       options = list(create = TRUE, placeholder = "type to search")),
            select = shiny::selectInput(ns("edit_value"), f$label,
                       choices = unique(c("", f$vocab, if (!is.na(cur$norm)) cur$norm)),
                       selected = cur$norm %||% ""),
            number = shiny::numericInput(ns("edit_value"), f$label,
                       value = suppressWarnings(as.numeric(cur$norm))),
            date   = shiny::dateInput(ns("edit_value"), f$label,
                       value = suppressWarnings(as.Date(cur$norm))),
            bool   = shiny::selectInput(ns("edit_value"), f$label,
                       choices = c("Yes", "No", "Unknown"),
                       selected = if (identical(cur$norm, "TRUE")) "Yes"
                                  else if (identical(cur$norm, "FALSE")) "No" else "Unknown"),
            shiny::textInput(ns("edit_value"), f$label, value = cur$norm %||% "")),
          shiny::textAreaInput(ns("edit_comment"), "Comment (optional)", rows = 2),
          # Scope, stated before the save and not after. This is the entire UX
          # of the routing split.
          if (registry_scope)
            shiny::div(class = "alert alert-warning py-2 small mb-0",
              shiny::strong("This is not a per-trial edit. "), f$note)
          else shiny::div(class = "text-muted small", f$note),
          footer = shiny::tagList(
            shiny::modalButton("Cancel"),
            shiny::actionButton(ns("edit_save"), "Save", class = "btn-primary")))) 

        # Must run AFTER showModal: the input does not exist until the modal is
        # in the DOM, and updating a selectize that is not there silently does
        # nothing — which is what left these as free-text boxes.
        dom <- entity_domain(f)
        if (!is.na(dom)) {
          reg <- registries()[[dom]]
          if (!is.null(reg) && nrow(reg)) {
            shiny::updateSelectizeInput(session, "edit_value",
              choices = sort(unique(reg$canonical)), selected = cur$norm,
              server = TRUE)
          }
        }
      }, ignoreInit = TRUE)
    })

    # Uncontrolled canonical creation is how near-duplicates accumulated in the
    # registry originally, so it is shown before the save, never after.
    output$new_canonical_warning <- shiny::renderUI({
      fid <- editing(); if (is.null(fid)) return(NULL)
      f <- Filter(function(x) identical(x$id, fid), TRIAL_FIELD_SPEC)[[1]]
      dom <- entity_domain(f); if (is.na(dom)) return(NULL)
      v <- input$edit_value
      if (is.null(v) || !nzchar(v)) return(NULL)
      reg <- registries()[[dom]]
      if (!is.null(reg) && v %in% reg$canonical) return(NULL)
      shiny::div(class = "alert alert-warning py-2 small",
        shiny::strong("New canonical. "),
        sprintf("\"%s\" is not in the %s registry and will be created.", v, dom))
    })

    shiny::observeEvent(input$edit_save, {
      fid <- editing(); r <- row(); u <- session_user()
      if (is.null(fid) || is.null(r) || is.null(u) || is.null(db)) return()
      f <- Filter(function(x) identical(x$id, fid), TRIAL_FIELD_SPEC)[[1]]
      cur <- Filter(function(x) x$id == fid, field_rows(r))[[1]]
      new <- input$edit_value
      new <- if (identical(f$control, "bool"))
               switch(as.character(new), Yes = "TRUE", No = "FALSE", NA_character_)
             else as.character(new)
      if (identical(as.character(cur$norm), new) ||
          (is.na(cur$norm) && (is.na(new) || !nzchar(new)))) {
        shiny::showNotification("Unchanged — nothing saved.", type = "message")
        shiny::removeModal(); return()
      }
      ms  <- as.integer(difftime(Sys.time(), shown_at(), units = "secs") * 1000)
      sha <- snap()$sha %||% NA_character_
      ok <- tryCatch({
        if (identical(f$route, "trial_override")) {
          append_trial_decision(db, trial_id = r$`_id`, field_id = f$id, action = "override",
            reviewer = u$username, snapshot_sha = sha, raw_shown = cur$raw,
            norm_shown = cur$norm, final_value = new, value_type = spec_value_type(f),
            comment = input$edit_comment %||% NA_character_,
            decision_ms = ms, app_version = APP_VERSION)
        } else {
          dom <- if (identical(f$route, "sponsor_registry")) "sponsor" else "substance"
          raw <- if (dom == "sponsor") row_val(r, "sponsor_name_raw") else cur$raw
          if (is.na(raw) || !nzchar(raw)) stop("no raw string to key this decision on")
          append_norm_decision(db, domain = dom, raw_value = raw, action = "edit",
            reviewer = u$username, snapshot_sha = sha, proposed = cur$norm,
            final_canonical = new, comment = input$edit_comment %||% NA_character_,
            decision_ms = ms, app_version = APP_VERSION)
        }
        TRUE
      }, error = function(e) {
        shiny::showNotification(conditionMessage(e), type = "error"); FALSE })
      if (isTRUE(ok)) {
        shiny::showNotification(
          if (identical(f$route, "trial_override")) "Saved. Live after tonight's rebuild."
          else "Saved to the registry — applies to every trial with this string.",
          type = "message")
        saved_tick(saved_tick() + 1)
        shiny::removeModal()
      }
    })

    output$sign_off <- shiny::renderUI({
      if (is.null(row())) return(NULL)
      shiny::div(class = "mt-2",
        shiny::textAreaInput(ns("comment"), "Comment", rows = 2, width = "100%"),
        shiny::div(class = "d-flex gap-2",
          shiny::actionButton(ns("validate"), "Mark validated", class = "btn-success btn-sm"),
          shiny::actionButton(ns("flag"), "Flag for another reviewer", class = "btn-warning btn-sm")))
    })

    sign_off <- function(status) {
      r <- row(); u <- session_user()
      if (is.null(r) || is.null(u) || is.null(db)) return()
      ok <- tryCatch({
        append_trial_review(db, trial_id = r$`_id`, status = status, reviewer = u$username,
                            snapshot_sha = snap()$sha %||% NA_character_,
                            comment = input$comment %||% NA_character_)
        TRUE
      }, error = function(e) { shiny::showNotification(conditionMessage(e), type = "error"); FALSE })
      if (ok) {
        shiny::showNotification(sprintf("Trial marked %s.", status), type = "message")
        shiny::updateTextAreaInput(session, "comment", value = "")
        reviewed_tick(reviewed_tick() + 1)
      }
    }
    shiny::observeEvent(input$validate, sign_off("validated"))
    shiny::observeEvent(input$flag,     sign_off("flagged"))

    list(filtered = filtered, reviewed_tick = reviewed_tick, saved_tick = saved_tick)
  })
}

# The cache is typed, so an override must declare what it carries — casting
# from a bare string is how "12" ends up in a numeric column.
spec_value_type <- function(f) {
  switch(f$control, number = "numeric", date = "date", bool = "logical", "character")
}
