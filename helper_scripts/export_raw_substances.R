suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
})

cache <- readRDS("trials_cache.rds")

out <- cache |>
  mutate(raw_substance = dplyr::if_else(
    !is.na(DIMP_inn_name) & nchar(stringr::str_trim(DIMP_inn_name)) > 0,
    DIMP_inn_name,
    DIMP_product_name
  )) |>
  filter(!is.na(raw_substance), nchar(stringr::str_trim(raw_substance)) > 0) |>
  count(raw_substance, name = "n_trials", sort = TRUE)

readr::write_csv(out, "tmp_raw_substances.csv")
message(sprintf(
  "Wrote %d unique raw substance values (total %d rows) to tmp_raw_substances.csv",
  nrow(out), sum(out$n_trials)
))
