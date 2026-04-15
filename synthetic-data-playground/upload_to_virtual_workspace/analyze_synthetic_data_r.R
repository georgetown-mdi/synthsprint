#!/usr/bin/env Rscript

# R equivalent synthetic-data evaluator (R kernel friendly).
# Produces similar outputs to the Python workflow:
# - distribution/validity tables
# - PII pattern checks
# - privacy risk summary
# - visualization PNGs

ensure_pkg <- function(pkg) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org")
  }
}

pkgs <- c("readr", "readxl", "arrow", "dplyr", "stringr", "jsonlite", "ggplot2", "tidyr", "purrr")
invisible(lapply(pkgs, ensure_pkg))

suppressPackageStartupMessages({
  library(readr)
  library(readxl)
  library(arrow)
  library(dplyr)
  library(stringr)
  library(jsonlite)
  library(ggplot2)
  library(tidyr)
  library(purrr)
})

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  out <- list(data = NULL, metadata = NULL, outdir = "../analysis_reports/output_r")
  i <- 1
  while (i <= length(args)) {
    k <- args[[i]]
    if (k == "--data" && i + 1 <= length(args)) {
      out$data <- args[[i + 1]]
      i <- i + 2
    } else if (k == "--metadata" && i + 1 <= length(args)) {
      out$metadata <- args[[i + 1]]
      i <- i + 2
    } else if (k == "--outdir" && i + 1 <= length(args)) {
      out$outdir <- args[[i + 1]]
      i <- i + 2
    } else {
      i <- i + 1
    }
  }
  out
}

load_table <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext == "csv") return(readr::read_csv(path, show_col_types = FALSE))
  if (ext == "tsv") return(readr::read_tsv(path, show_col_types = FALSE))
  if (ext == "xlsx") return(readxl::read_excel(path, sheet = 1))
  if (ext == "parquet") return(as.data.frame(arrow::read_parquet(path)))
  stop(sprintf("Unsupported file type: %s", ext))
}

is_num <- function(x) is.numeric(x) || is.integer(x)

to_csv <- function(df, path) {
  if (!is.null(df) && nrow(df) > 0) readr::write_csv(df, path)
}

column_profile <- function(df) {
  n <- nrow(df)
  tibble::tibble(column = names(df)) %>%
    rowwise() %>%
    mutate(
      dtype = class(df[[column]])[1],
      missing_count = sum(is.na(df[[column]])),
      missing_pct = ifelse(n == 0, 0, round(missing_count / n * 100, 3)),
      unique_count = dplyr::n_distinct(df[[column]], na.rm = TRUE),
      unique_pct = ifelse(n == 0, 0, round(unique_count / n * 100, 3)),
      is_constant = unique_count <= 1
    ) %>%
    ungroup() %>%
    arrange(desc(missing_pct), desc(unique_pct))
}

numeric_distribution <- function(df) {
  ncols <- names(df)[vapply(df, is_num, logical(1))]
  if (length(ncols) == 0) return(NULL)
  map_dfr(ncols, function(col) {
    x <- df[[col]]
    x <- x[!is.na(x)]
    if (length(x) == 0) return(NULL)
    q <- quantile(x, probs = c(0.01, 0.05, 0.25, 0.50, 0.75, 0.95, 0.99), names = FALSE, na.rm = TRUE)
    iqr <- q[5] - q[3]
    low <- q[3] - 1.5 * iqr
    high <- q[5] + 1.5 * iqr
    tibble::tibble(
      column = col,
      count = length(x),
      mean = mean(x),
      sd = sd(x),
      min = min(x),
      p01 = q[1],
      p05 = q[2],
      p25 = q[3],
      p50 = q[4],
      p75 = q[5],
      p95 = q[6],
      p99 = q[7],
      max = max(x),
      iqr = iqr,
      outlier_iqr_count = sum(x < low | x > high)
    )
  })
}

categorical_top_values <- function(df) {
  ccols <- names(df)[!vapply(df, is_num, logical(1))]
  if (length(ccols) == 0) return(NULL)
  map_dfr(ccols, function(col) {
    vals <- as.character(df[[col]])
    vals <- vals[!is.na(vals)]
    if (length(vals) == 0) return(NULL)
    tab <- sort(table(vals), decreasing = TRUE)
    top <- head(tab, 10)
    tibble::tibble(
      column = col,
      top_values = as.character(jsonlite::toJSON(names(top), auto_unbox = TRUE)),
      top_counts = as.character(jsonlite::toJSON(as.integer(top), auto_unbox = TRUE))
    )
  })
}

detect_pii <- function(df, scan_limit = 5000) {
  pii_name_patterns <- list(
    possible_name_column = "(name|first|last|middle|fullname)",
    possible_email_column = "(email|e-mail|mail)",
    possible_phone_column = "(phone|mobile|tel|contact)",
    possible_address_column = "(address|street|city|state|zip|postal)",
    possible_dob_column = "(dob|birth|date_of_birth)",
    possible_id_column = "(ssn|social|passport|license|mrn|nhs|patient_id|id$)"
  )
  pii_value_patterns <- list(
    email_like = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
    phone_like = "(\\+?\\d{1,3}[-.\\s]?)?(\\(?\\d{3}\\)?[-.\\s]?){1,2}\\d{4}",
    ssn_like = "\\d{3}-\\d{2}-\\d{4}",
    ip_like = "(\\d{1,3}\\.){3}\\d{1,3}",
    url_like = "https?://[^\\s]+"
  )

  name_hits <- map_dfr(names(pii_name_patterns), function(rule) {
    pat <- pii_name_patterns[[rule]]
    hit_cols <- names(df)[str_detect(names(df), regex(pat, ignore_case = TRUE))]
    if (length(hit_cols) == 0) return(NULL)
    tibble::tibble(column = hit_cols, rule = rule, evidence = "column_name_match")
  })

  sample_df <- df %>% slice_head(n = scan_limit)
  value_hits <- map_dfr(names(sample_df), function(col) {
    vals <- as.character(sample_df[[col]])
    vals <- vals[!is.na(vals)]
    joined <- paste(head(vals, 5000), collapse = "\n")
    map_dfr(names(pii_value_patterns), function(rule) {
      pat <- pii_value_patterns[[rule]]
      m <- stringr::str_extract_all(joined, regex(pat, ignore_case = TRUE))[[1]]
      if (length(m) == 0) return(NULL)
      tibble::tibble(
        column = col,
        rule = rule,
        match_count_in_sample = length(m),
        example_match = substr(m[[1]], 1, 80)
      )
    })
  })
  list(name_hits = name_hits, value_hits = value_hits)
}

validity_flags <- function(df) {
  ncols <- names(df)[vapply(df, is_num, logical(1))]
  map_dfr(ncols, function(col) {
    x <- df[[col]]
    x <- x[!is.na(x)]
    if (length(x) == 0) return(NULL)
    out <- list()
    if (mean(x < 0) > 0) {
      out <- append(out, list(tibble::tibble(
        column = col, rule = "has_negative_values", pct_negative = mean(x < 0) * 100
      )))
    }
    if (dplyr::n_distinct(x) <= 12 && dplyr::n_distinct(x) > 2 && all(x %in% 0:999)) {
      out <- append(out, list(tibble::tibble(
        column = col, rule = "possible_coded_variable_review_levels", distinct_levels = dplyr::n_distinct(x)
      )))
    }
    bind_rows(out)
  })
}

uniqueness_risk <- function(df) {
  n <- nrow(df)
  tibble::tibble(column = names(df)) %>%
    rowwise() %>%
    mutate(
      unique_count = dplyr::n_distinct(df[[column]], na.rm = TRUE),
      unique_pct = ifelse(n == 0, 0, unique_count / n * 100),
      possible_direct_identifier = unique_pct >= 95 & unique_count > 50
    ) %>%
    ungroup() %>%
    arrange(desc(unique_pct))
}

quasi_identifier_risk <- function(df, max_cols = 5) {
  n <- nrow(df)
  if (n == 0) return(NULL)
  hints <- "(age|sex|gender|ethnic|race|zip|postal|region|site|center|dob|birth)"

  cand <- map_dfr(names(df), function(col) {
    up <- dplyr::n_distinct(df[[col]], na.rm = TRUE) / n * 100
    is_hint <- str_detect(col, regex(hints, ignore_case = TRUE))
    keep <- is_hint || (up > 3 && up < 95)
    if (!keep) return(NULL)
    tibble::tibble(column = col, score = (ifelse(is_hint, 100, 0) + min(99, abs(up - 50))))
  }) %>%
    arrange(desc(score)) %>%
    slice_head(n = max_cols)

  cols <- cand$column
  if (length(cols) < 2) return(NULL)
  grouped <- df %>%
    mutate(across(all_of(cols), ~replace(as.character(.x), is.na(.x), "__NA__"))) %>%
    group_by(across(all_of(cols))) %>%
    summarise(k = dplyr::n(), .groups = "drop")

  tibble::tibble(
    columns_used = paste(cols, collapse = ","),
    rows_total = n,
    groups_total = nrow(grouped),
    k_min = min(grouped$k),
    k_5th_percentile = as.numeric(quantile(grouped$k, 0.05)),
    k_median = median(grouped$k),
    groups_with_k_1 = sum(grouped$k == 1),
    pct_rows_in_k_1_groups = (sum(grouped$k[grouped$k == 1]) / n) * 100
  )
}

row_missingness_summary <- function(df) {
  if (nrow(df) == 0) return(NULL)
  row_missing <- rowSums(is.na(df))
  tibble::tibble(
    rows_total = nrow(df),
    cols_total = ncol(df),
    mean_missing_per_row = mean(row_missing),
    p95_missing_per_row = as.numeric(quantile(row_missing, 0.95)),
    rows_with_any_missing_pct = mean(row_missing > 0) * 100,
    rows_all_missing_pct = mean(row_missing == ncol(df)) * 100
  )
}

string_column_profile <- function(df) {
  ccols <- names(df)[!vapply(df, is_num, logical(1))]
  map_dfr(ccols, function(col) {
    vals <- as.character(df[[col]])
    vals <- vals[!is.na(vals)]
    if (length(vals) == 0) return(NULL)
    lens <- nchar(vals)
    tibble::tibble(
      column = col,
      non_null_count = length(vals),
      avg_len = mean(lens),
      p95_len = as.numeric(quantile(lens, 0.95)),
      max_len = max(lens),
      pct_numeric_like_strings = mean(str_detect(vals, "^[-+]?\\d+(\\.\\d+)?$")) * 100,
      pct_date_like_strings = mean(str_detect(vals, "^\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}$")) * 100
    )
  })
}

numeric_top_correlations <- function(df, top_n = 100) {
  ncols <- names(df)[vapply(df, is_num, logical(1))]
  if (length(ncols) < 2) return(NULL)
  m <- suppressWarnings(cor(df[ncols], use = "pairwise.complete.obs"))
  pairs <- which(upper.tri(m), arr.ind = TRUE)
  out <- tibble::tibble(
    col_a = rownames(m)[pairs[, 1]],
    col_b = colnames(m)[pairs[, 2]],
    pearson_r = m[pairs],
    abs_r = abs(m[pairs])
  ) %>%
    filter(!is.na(pearson_r)) %>%
    arrange(desc(abs_r)) %>%
    slice_head(n = top_n)
  out
}

privacy_risk_summary <- function(name_hits, value_hits, uniq_df, k_df) {
  direct_id_cols <- ifelse(is.null(uniq_df), 0, sum(uniq_df$possible_direct_identifier))
  k_one_pct <- ifelse(is.null(k_df), 0, k_df$pct_rows_in_k_1_groups[[1]])
  score <- min(30, nrow(name_hits) * 4) +
    min(30, nrow(value_hits) * 7) +
    min(25, direct_id_cols * 5) +
    min(15, as.integer(k_one_pct / 2))
  band <- ifelse(score >= 60, "high", ifelse(score >= 30, "medium", "low"))
  tibble::tibble(
    risk_score_0_100 = as.integer(score),
    risk_band = band,
    pii_name_hit_count = nrow(name_hits),
    pii_value_hit_count = nrow(value_hits),
    possible_direct_identifier_columns = as.integer(direct_id_cols),
    pct_rows_in_k1_groups = as.numeric(k_one_pct)
  )
}

generate_visuals <- function(outdir) {
  viz_dir <- file.path(outdir, "visuals")
  dir.create(viz_dir, recursive = TRUE, showWarnings = FALSE)
  made <- c()

  save_plot <- function(plot_obj, filename, width = 11, height = 7) {
    fp <- file.path(viz_dir, filename)
    ggsave(fp, plot_obj, width = width, height = height, dpi = 160)
    made <<- c(made, filename)
  }

  cp <- read_if_exists(file.path(outdir, "column_profile.csv"))
  if (!is.null(cp) && nrow(cp) > 0) {
    p1 <- cp %>% arrange(desc(missing_pct)) %>% slice_head(n = 20) %>%
      ggplot(aes(x = missing_pct, y = reorder(column, missing_pct))) +
      geom_col(fill = "#4C78A8") + labs(title = "Top Columns by Missing Percentage", x = "Missing %", y = "Column")
    save_plot(p1, "01_missingness_top_columns.png")

    p2 <- cp %>% arrange(desc(unique_pct)) %>% slice_head(n = 20) %>%
      ggplot(aes(x = unique_pct, y = reorder(column, unique_pct))) +
      geom_col(fill = "#72B7B2") + labs(title = "Top Columns by Uniqueness Percentage", x = "Unique %", y = "Column")
    save_plot(p2, "02_uniqueness_top_columns.png")
  }

  nd <- read_if_exists(file.path(outdir, "numeric_distribution.csv"))
  if (!is.null(nd) && "outlier_iqr_count" %in% names(nd)) {
    p3 <- nd %>% arrange(desc(outlier_iqr_count)) %>% slice_head(n = 20) %>%
      ggplot(aes(x = outlier_iqr_count, y = reorder(column, outlier_iqr_count))) +
      geom_col(fill = "#F58518") + labs(title = "Top Numeric Columns by IQR Outlier Count", x = "Outlier count", y = "Column")
    save_plot(p3, "03_outliers_iqr_top_columns.png")
  }

  tc <- read_if_exists(file.path(outdir, "numeric_top_correlations.csv"))
  if (!is.null(tc) && all(c("col_a", "col_b", "pearson_r") %in% names(tc))) {
    tc2 <- tc %>% mutate(pair = paste(col_a, "<>", col_b), abs_r = abs(pearson_r)) %>% arrange(desc(abs_r)) %>% slice_head(n = 20)
    p4 <- ggplot(tc2, aes(x = pearson_r, y = reorder(pair, abs_r))) +
      geom_col(fill = "#E45756") + labs(title = "Top Correlated Numeric Column Pairs", x = "Pearson r", y = "Pair")
    save_plot(p4, "04_top_correlated_pairs.png", width = 12, height = 8)
  }

  prs <- read_if_exists(file.path(outdir, "privacy_risk_summary.csv"))
  if (!is.null(prs) && nrow(prs) > 0) {
    r <- prs[1, ]
    m <- tibble::tibble(
      metric = c("PII name hits", "PII value hits", "Possible direct-ID cols", "% rows in k=1 groups", "Risk score (0-100)"),
      value = c(r$pii_name_hit_count, r$pii_value_hit_count, r$possible_direct_identifier_columns, r$pct_rows_in_k1_groups, r$risk_score_0_100)
    )
    p5 <- ggplot(m, aes(x = value, y = reorder(metric, value))) +
      geom_col(fill = "#54A24B") +
      labs(title = paste0("Privacy Risk Summary (Band: ", r$risk_band, ")"), x = "Value", y = "Metric")
    save_plot(p5, "05_privacy_risk_summary.png", width = 10, height = 6)
  }

  pii <- read_if_exists(file.path(outdir, "pii_value_pattern_hits.csv"))
  if (!is.null(pii) && "rule" %in% names(pii)) {
    pg <- pii %>% group_by(rule) %>% summarise(match_count_in_sample = sum(match_count_in_sample), .groups = "drop")
    p6 <- ggplot(pg, aes(x = match_count_in_sample, y = reorder(rule, match_count_in_sample))) +
      geom_col(fill = "#B279A2") + labs(title = "PII Pattern Matches by Rule", x = "Matches", y = "Rule")
    save_plot(p6, "06_pii_pattern_hits.png", width = 9, height = 5)
  }

  idx <- c("# Visual Report Index", "", "Generated visual artifacts:")
  if (length(made) == 0) idx <- c(idx, "- No visuals generated (required CSV inputs not found).")
  if (length(made) > 0) idx <- c(idx, paste0("- `", made, "`"))
  writeLines(idx, con = file.path(viz_dir, "VISUAL_INDEX.md"))
}

read_if_exists <- function(path) {
  if (!file.exists(path)) return(NULL)
  readr::read_csv(path, show_col_types = FALSE)
}

main <- function() {
  args <- parse_args()
  if (is.null(args$data)) stop("Usage: Rscript analyze_synthetic_data_r.R --data <synthetic_data_file> [--metadata <metadata_xlsx>] [--outdir <output_dir>]")

  outdir <- normalizePath(args$outdir, winslash = "/", mustWork = FALSE)
  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

  df <- load_table(args$data)
  cp <- column_profile(df)
  nd <- numeric_distribution(df)
  ct <- categorical_top_values(df)
  pii <- detect_pii(df, scan_limit = 5000)
  vf <- validity_flags(df)
  ur <- uniqueness_risk(df)
  kr <- quasi_identifier_risk(df)
  rms <- row_missingness_summary(df)
  scp <- string_column_profile(df)
  ntc <- numeric_top_correlations(df)
  prs <- privacy_risk_summary(pii$name_hits, pii$value_hits, ur, kr)

  to_csv(cp, file.path(outdir, "column_profile.csv"))
  to_csv(nd, file.path(outdir, "numeric_distribution.csv"))
  to_csv(ct, file.path(outdir, "categorical_top_values.csv"))
  to_csv(pii$name_hits, file.path(outdir, "pii_column_name_hits.csv"))
  to_csv(pii$value_hits, file.path(outdir, "pii_value_pattern_hits.csv"))
  to_csv(vf, file.path(outdir, "validity_flags.csv"))
  to_csv(ur, file.path(outdir, "uniqueness_risk.csv"))
  to_csv(kr, file.path(outdir, "quasi_identifier_k_anonymity_snapshot.csv"))
  to_csv(rms, file.path(outdir, "row_missingness_summary.csv"))
  to_csv(scp, file.path(outdir, "string_column_profile.csv"))
  to_csv(ntc, file.path(outdir, "numeric_top_correlations.csv"))
  to_csv(prs, file.path(outdir, "privacy_risk_summary.csv"))

  if (!is.null(args$metadata) && file.exists(args$metadata)) {
    md <- readxl::read_excel(args$metadata, sheet = 1)
    readr::write_csv(md, file.path(outdir, "metadata_dictionary_dump.csv"))
  }

  summary <- list(
    input_file = normalizePath(args$data, winslash = "/", mustWork = FALSE),
    rows = nrow(df),
    columns = ncol(df),
    duplicate_rows = sum(duplicated(df)),
    duplicate_row_pct = ifelse(nrow(df) == 0, 0, sum(duplicated(df)) / nrow(df) * 100),
    numeric_column_count = sum(vapply(df, is_num, logical(1))),
    non_numeric_column_count = sum(!vapply(df, is_num, logical(1))),
    outputs = basename(list.files(outdir, pattern = "\\.csv$", full.names = TRUE))
  )

  jsonlite::write_json(summary, file.path(outdir, "summary.json"), pretty = TRUE, auto_unbox = TRUE)
  generate_visuals(outdir)

  cat(toJSON(summary, pretty = TRUE, auto_unbox = TRUE), "\n")
  cat("\nAnalysis complete. Files written to:", outdir, "\n")
}

main()
