# ============================================================================
# Dockerfile — EU Paediatric Clinical Trials Dashboard
#
# Two-stage build:
#   Stage 1 (builder): system deps + R packages (cached layer)
#   Stage 2 (app):     copy code + launch config
#
# Usage:
#   docker build -t pediatric-trials .
#   docker run -p 3838:3838 -v $(pwd)/data:/app/data pediatric-trials
# ============================================================================

FROM rocker/r-ver:4.4.1 AS builder

LABEL maintainer="Ruben Van Paemel"
LABEL description="EU Paediatric Clinical Trials Dashboard (EUCTR + CTIS)"

# ── System dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libsqlite3-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    zlib1g-dev \
    # Node.js for ctrdata EUCTR scraping
    nodejs \
    npm \
    # Headless Chrome for ctrdata CTIS
    chromium-bsu \
    # curl for healthcheck
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Tell ctrdata / chromote where to find the browser
ENV CHROMOTE_CHROME=/usr/bin/chromium

# ── Install R packages (in dependency order for Docker cache) ───────────────

# Core infrastructure
RUN R -e 'install.packages(c( \
    "nodbi", "RSQLite", "DBI" \
  ), repos = "https://cloud.r-project.org/")'

# Shiny + dashboard
RUN R -e 'install.packages(c( \
    "shiny", "shinydashboard", "shinycssloaders", "htmltools", "httpuv", "eulerr"  \
  ), repos = "https://cloud.r-project.org/")'

# Data wrangling
RUN R -e 'install.packages(c( \
    "dplyr", "tidyr", "stringr", "lubridate", "readr", "purrr" \
  ), repos = "https://cloud.r-project.org/")'

# Visualisation
RUN R -e 'install.packages(c( \
    "ggplot2", "plotly", "DT", "eulerr" \
  ), repos = "https://cloud.r-project.org/")'

# Export
RUN R -e 'install.packages("writexl", repos = "https://cloud.r-project.org/")'

# ctrdata (install last — most likely to need updates)
RUN R -e 'install.packages("ctrdata", repos = "https://cloud.r-project.org/")'


# ── Application stage ───────────────────────────────────────────────────────
FROM builder AS app

RUN mkdir -p /app/data
WORKDIR /app

# Copy application files
COPY app.R          /app/app.R
COPY update_data.R  /app/update_data.R

# Environment variables for DB path (overridable at runtime)
ENV DB_PATH=/app/data/pediatric_trials.sqlite
ENV DB_COLLECTION=trials
ENV CACHE_PATH=/app/data/pediatric_trials_cache.rds

# ── Wrapper script for update_data.R (reads env vars) ──────────────────────
# ── Wrapper script for update_data.R (reads env vars) ──────────────────────
RUN cat > /app/update_wrapper.R <<'REOF'
db_path <- Sys.getenv("DB_PATH", "/app/data/pediatric_trials.sqlite")
db_coll <- Sys.getenv("DB_COLLECTION", "trials")
assign("DB_PATH", db_path, envir = .GlobalEnv)
assign("DB_COLLECTION", db_coll, envir = .GlobalEnv)

source("/app/update_data.R")
REOF

# ── Startup script ─────────────────────────────────────────────────────────
RUN cat > /app/start.sh <<'EOF'
#!/bin/bash
set -e

export DB_PATH="${DB_PATH:-/app/data/pediatric_trials.sqlite}"
export DB_COLLECTION="${DB_COLLECTION:-trials}"
export CACHE_PATH="${CACHE_PATH:-/app/data/pediatric_trials_cache.rds}"

echo "============================================"
echo " EU Paediatric Clinical Trials Dashboard"
echo "============================================"
echo " DB_PATH:    ${DB_PATH}"
echo " CACHE_PATH: ${CACHE_PATH}"
echo ""

if [ -f "${DB_PATH}" ]; then
    SIZE=$(du -h "${DB_PATH}" | cut -f1)
    echo " Database found: ${SIZE}"
else
    echo " No database found."
    echo " Use the Update button in the app, or run:"
    echo "   docker exec <id> Rscript /app/update_wrapper.R"
fi

echo ""
echo " Starting Shiny on port 3838..."
echo "============================================"

exec R -e "
  Sys.setenv(
    DB_PATH       = '${DB_PATH}',
    DB_COLLECTION = '${DB_COLLECTION}',
    CACHE_PATH    = '${CACHE_PATH}'
  );
  options(shiny.port = 3838, shiny.host = '0.0.0.0');
  shiny::runApp('/app/app.R')
"
EOF
RUN chmod +x /app/start.sh

# ── Expose port and healthcheck ────────────────────────────────────────────
EXPOSE 3838

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:3838/ || exit 1

CMD ["/app/start.sh"]
