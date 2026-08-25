# ══════════════════════════════════════════════════════════════════════════════
# TAB 3 — CHANGES AND STATISTICS
# ══════════════════════════════════════════════════════════════════════════════
#
# Visible to every reviewer, not just admins. Two reasons: the per-field change
# rate tells a reviewer which normalisation to distrust, which is directly
# useful while reviewing; and the disagreement report is the ENTIRE safety net
# for last-write-wins, so hiding it behind a role would make the conflict rule
# unsafe for everyone who cannot see it.
#
# Deliberately NOT here: any leaderboard framing of disagreement. Per-reviewer
# throughput is shown because it answers "is this workable"; ranking who is
# "right" when two people disagree is not something this data can support.

# ── Metrics ───────────────────────────────────────────────────────────────────
# Plain functions of a connection, so they are testable without a Shiny session.

metrics_totals <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT
      (SELECT count(*) FROM norm_decisions  WHERE action <> 'skip') AS norm_all,
      (SELECT count(*) FROM norm_decisions_latest)                  AS norm_keys,
      (SELECT count(*) FROM trial_decisions)                        AS trial_all,
      (SELECT count(*) FROM trial_decisions_latest)                 AS trial_keys,
      (SELECT count(DISTINCT trial_id) FROM trial_reviews)          AS trials_signed_off,
      (SELECT count(*) FROM norm_decisions
        WHERE action <> 'skip' AND decided_at_utc > now() - interval '7 days')
        + (SELECT count(*) FROM trial_decisions
        WHERE decided_at_utc > now() - interval '7 days')           AS last_7_days")
}

metrics_by_reviewer <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT reviewer,
           count(*)                                       AS decisions,
           count(*) FILTER (WHERE kind = 'norm')          AS norm,
           count(*) FILTER (WHERE kind = 'trial')         AS trial,
           count(*) FILTER (WHERE action = 'accept')      AS accepted,
           count(*) FILTER (WHERE action IN ('edit','override')) AS changed,
           count(*) FILTER (WHERE action IN ('reject','not_a_substance')) AS rejected,
           -- Median rather than mean: one interrupted card at 40 minutes would
           -- otherwise swamp a hundred real ones.
           percentile_cont(0.5) WITHIN GROUP (ORDER BY decision_ms)
             FILTER (WHERE decision_ms IS NOT NULL)       AS median_ms,
           max(decided_at_utc)                            AS last_decision
    FROM (
      SELECT reviewer, action, decision_ms, decided_at_utc, 'norm'  AS kind
        FROM norm_decisions WHERE action <> 'skip'
      UNION ALL
      SELECT reviewer, action, decision_ms, decided_at_utc, 'trial' AS kind
        FROM trial_decisions
    ) x
    GROUP BY reviewer ORDER BY decisions DESC")
}

metrics_daily <- function(con, days = 90L) {
  DBI::dbGetQuery(con, "
    SELECT date_trunc('day', decided_at_utc)::date AS day, reviewer, count(*) AS n
    FROM (
      SELECT reviewer, decided_at_utc FROM norm_decisions WHERE action <> 'skip'
      UNION ALL
      SELECT reviewer, decided_at_utc FROM trial_decisions
    ) x
    WHERE decided_at_utc > now() - ($1 || ' days')::interval
    GROUP BY 1, 2 ORDER BY 1", params = list(as.integer(days)))
}

# WHICH NORMALISATION IS UNTRUSTWORTHY — the point of this tab.
#
# THE DENOMINATOR IS NOT OBVIOUS, so it is stated here rather than implied.
# Only CHANGES are recorded per field: a reviewer who reads a trial and accepts
# the phase writes nothing for phase. So "how often was this field looked at"
# does not exist per field.
#
# What does exist is the whole-trial sign-off. A signed-off trial means every
# field on that screen was seen, so the number of sign-offs is the denominator
# and the per-field overrides are the numerator. That makes the rate "of the
# trials someone reviewed, how often was THIS field wrong" — which is the
# question worth answering, but it is an approximation and it is only honest
# while reviewers actually sign trials off rather than only editing them.
metrics_field_change_rate <- function(con, min_n = 5L) {
  DBI::dbGetQuery(con, "
    WITH seen AS (SELECT count(DISTINCT trial_id) AS n FROM trial_reviews),
         chg  AS (SELECT field_id,
                         count(DISTINCT trial_id) FILTER (WHERE action = 'override') AS n_changed,
                         count(*) AS n_decisions
                  FROM trial_decisions GROUP BY field_id)
    SELECT chg.field_id, chg.n_changed, chg.n_decisions, seen.n AS n_trials_reviewed,
           CASE WHEN seen.n > 0 THEN chg.n_changed::float / seen.n END AS change_rate
    FROM chg CROSS JOIN seen
    WHERE seen.n >= $1
    ORDER BY change_rate DESC NULLS LAST", params = list(as.integer(min_n)))
}

# Change rate by WHY the pipeline queued the row and how confident it was.
# This is the evidence for re-tuning route_for_review()'s 0.75 / 0.90
# thresholds: a band where reviewers change most rows has the wrong prior.
metrics_by_reason <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT domain, COALESCE(review_reason, '(none)') AS review_reason,
           count(*) AS decided,
           count(*) FILTER (WHERE action = 'accept') AS accepted,
           count(*) FILTER (WHERE action = 'edit')   AS changed,
           count(*) FILTER (WHERE action IN ('reject','not_a_substance')) AS rejected,
           count(*) FILTER (WHERE action = 'edit')::float / NULLIF(count(*), 0) AS change_rate
    FROM norm_decisions WHERE action <> 'skip'
    GROUP BY 1, 2 ORDER BY decided DESC")
}

metrics_by_confidence <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT domain,
           width_bucket(confidence_shown, 0, 1, 10) AS band,
           count(*) AS decided,
           count(*) FILTER (WHERE action = 'accept') AS accepted,
           count(*) FILTER (WHERE action = 'edit')::float / NULLIF(count(*), 0) AS change_rate
    FROM norm_decisions
    WHERE action <> 'skip' AND confidence_shown IS NOT NULL
    GROUP BY 1, 2 ORDER BY 1, 2")
}

# New canonicals are the number to watch: uncontrolled minting is how
# near-duplicate canonicals accumulated in the registry originally.
metrics_new_canonicals <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT domain, reviewer, raw_value, final_canonical, decided_at_utc
    FROM norm_decisions WHERE new_canonical ORDER BY decided_at_utc DESC LIMIT 200")
}

# Overrides that now agree with the pipeline — safe to retire. Nothing retires
# them automatically: an override is a human statement and expires only when a
# human says so.
metrics_stale_overrides <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT trial_id, field_id, final_value, norm_shown, reviewer, decided_at_utc
    FROM trial_decisions_latest
    WHERE action = 'override' AND final_value IS NOT DISTINCT FROM norm_shown
    ORDER BY decided_at_utc")
}

# ── UI ────────────────────────────────────────────────────────────────────────

stats_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::div(
    class = "p-3",
    shiny::uiOutput(ns("headline")),
    bslib::navset_tab(
      bslib::nav_panel("Per-field change rate",
        shiny::p(class = "small text-muted mt-2",
          "Of the trials someone signed off, how often this field had to be corrected. ",
          shiny::strong("A high rate means that normalisation is not to be trusted.")),
        DT::DTOutput(ns("fields"))),
      bslib::nav_panel("Disagreements",
        shiny::p(class = "small text-muted mt-2",
          "Where two reviewers reached different answers on the same key. ",
          "Last-write-wins is only safe while these are read — the losing ",
          "decision is kept and shown."),
        shiny::h6("Normalisation"), DT::DTOutput(ns("dis_norm")),
        shiny::h6("Trials", class = "mt-3"), DT::DTOutput(ns("dis_trial"))),
      bslib::nav_panel("By reviewer", DT::DTOutput(ns("reviewers"))),
      bslib::nav_panel("By reason and confidence",
        shiny::p(class = "small text-muted mt-2",
          "Evidence for re-tuning the queue thresholds. A band where most rows ",
          "get changed has the wrong confidence prior."),
        shiny::h6("Review reason"), DT::DTOutput(ns("reason")),
        shiny::h6("Confidence band", class = "mt-3"), DT::DTOutput(ns("confidence"))),
      bslib::nav_panel("New canonicals",
        shiny::p(class = "small text-muted mt-2",
          "Every canonical a reviewer created. Uncontrolled minting is how ",
          "near-duplicates accumulated in the registry in the first place."),
        DT::DTOutput(ns("new_canon"))),
      bslib::nav_panel("Retirable overrides",
        shiny::p(class = "small text-muted mt-2",
          "Per-trial overrides that now agree with the pipeline. Nothing ",
          "retires them automatically."),
        DT::DTOutput(ns("stale")))
    )
  )
}

stats_server <- function(id, db, session_user, snapshot = snapshot_current) {
  shiny::moduleServer(id, function(input, output, session) {

    q <- function(f, ...) {
      require_role(session)
      if (is.null(db)) return(NULL)
      tryCatch(f(db, ...), error = function(e) NULL)
    }

    output$headline <- shiny::renderUI({
      require_role(session)
      t <- q(metrics_totals); if (is.null(t)) return(NULL)
      lag <- q(export_lag)
      pending <- if (is.null(lag)) NA else
        (as.numeric(lag$max_norm) - as.numeric(lag$exported_norm)) +
        (as.numeric(lag$max_trial) - as.numeric(lag$exported_trial))
      bslib::layout_columns(
        col_widths = c(3, 3, 3, 3),
        bslib::value_box("Decisions", fmt_int(as.numeric(t$norm_all) + as.numeric(t$trial_all)),
                         shiny::span(fmt_int(t$last_7_days), " in the last 7 days"), theme = "primary"),
        bslib::value_box("Strings decided", fmt_int(t$norm_keys),
                         "sponsor + substance", theme = "secondary"),
        bslib::value_box("Trials signed off", fmt_int(t$trials_signed_off),
                         "whole-trial reviews", theme = "secondary"),
        # The first question a reviewer asks after their first decision.
        bslib::value_box("Not yet live", if (is.na(pending)) "?" else fmt_int(pending),
                         if (is.null(lag) || is.na(lag$last_ok[[1]])) "no export has run yet"
                         else paste("last export", format(lag$last_ok[[1]], "%Y-%m-%d %H:%M")),
                         theme = if (!is.na(pending) && pending > 0) "warning" else "success")
      )
    })

    dt <- function(d, ...) {
      shiny::validate(shiny::need(!is.null(d) && nrow(d), "Nothing recorded yet."))
      DT::datatable(d, rownames = FALSE, options = list(pageLength = 12, scrollX = TRUE), ...)
    }

    output$fields     <- DT::renderDT(dt(q(metrics_field_change_rate, min_n = 1L)))
    output$reviewers  <- DT::renderDT(dt(q(metrics_by_reviewer)))
    output$dis_norm   <- DT::renderDT(dt(q(norm_disagreements)))
    output$dis_trial  <- DT::renderDT(dt(q(trial_disagreements)))
    output$reason     <- DT::renderDT(dt(q(metrics_by_reason)))
    output$confidence <- DT::renderDT(dt(q(metrics_by_confidence)))
    output$new_canon  <- DT::renderDT(dt(q(metrics_new_canonicals)))
    output$stale      <- DT::renderDT(dt(q(metrics_stale_overrides)))
  })
}
