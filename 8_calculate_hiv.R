source("Code/shareable_clinical_metrics/1_configure_clinical_metrics.R")

# Project: Frailty_Komoto shareable 2022 clinical metrics
# Author: Nemo Zhou
# Date started: 2026-09-27
# Date last updated: 2026-09-27
#
# ---- Purpose ----
# Convert matched HIV diagnosis evidence into annual patient-year HIV status.
# The active rule is HIV-positive when the same 2022 patient-year has at least
# one inpatient HIV diagnosis or at least two distinct non-inpatient HIV
# diagnosis dates. The non-inpatient threshold remains configurable but defaults
# to the value used by the current 3.x comparison pipeline: two dates.

run_calculate_hiv <- function() {
  config <- get_shareable_clinical_metrics_config()
  con <- connect_shareable_komodo(config)
  on.exit(disconnect_shareable_komodo(con), add = TRUE)

  require_table_columns(
    con,
    config$write_schema,
    config$metric_ids_table,
    c("patid", "patient_id", "analysis_year")
  )
  require_table_columns(
    con,
    config$write_schema,
    config$hiv_evidence_table,
    c(
      "patid", "analysis_year", "diagnosis_date", "claim_setting", "metric",
      "lookup_version"
    )
  )

  hiv_lookup <- read_lookup_csv(file.path(
    config$lookup_dir,
    "0.6_hiv_diagnosis_lookup.csv"
  ))
  require_columns(hiv_lookup, c("metric", "lookup_version"), "HIV diagnosis lookup")
  hiv_versions <- unique(hiv_lookup$lookup_version[toupper(hiv_lookup$metric) == "HIV"])
  hiv_versions <- hiv_versions[!is.na(hiv_versions) & nzchar(hiv_versions)]
  if (length(hiv_versions) != 1L) {
    stop("HIV diagnosis lookup must contain one active lookup version.")
  }

  prepare_output_table(con, config, config$hiv_status_table)
  ids_identifier <- qualified_identifier(config$write_schema, config$metric_ids_table)
  evidence_identifier <- qualified_identifier(config$write_schema, config$hiv_evidence_table)
  status_identifier <- qualified_identifier(config$write_schema, config$hiv_status_table)
  threshold <- config$hiv_non_inpatient_min_distinct_dates

  phase_started <- start_phase("Calculate annual 2022 HIV status")
  execute_sql(
    con,
    paste0(
      "CREATE TABLE ", status_identifier, "\n",
      "DISTKEY(patid) SORTKEY(analysis_year, patid) AS\n",
      "WITH hiv_matches AS (\n",
      "  SELECT DISTINCT patid, analysis_year, diagnosis_date, claim_setting, lookup_version\n",
      "  FROM ", evidence_identifier, "\n",
      "  WHERE analysis_year = 2022 AND metric = 'HIV'\n",
      "), inpatient_evidence AS (\n",
      "  SELECT patid, analysis_year, 1::INTEGER AS hiv_inpatient_evidence\n",
      "  FROM hiv_matches WHERE claim_setting = 'inpatient'\n",
      "  GROUP BY patid, analysis_year\n",
      "), non_inpatient_dates AS (\n",
      "  SELECT DISTINCT patid, analysis_year, diagnosis_date\n",
      "  FROM hiv_matches WHERE claim_setting = 'non_inpatient'\n",
      "), ranked_non_inpatient_dates AS (\n",
      "  SELECT patid, analysis_year, diagnosis_date,\n",
      "         ROW_NUMBER() OVER (PARTITION BY patid, analysis_year\n",
      "                            ORDER BY diagnosis_date) AS date_rank\n",
      "  FROM non_inpatient_dates\n",
      "), non_inpatient_evidence AS (\n",
      "  SELECT patid, analysis_year, COUNT(*)::INTEGER AS distinct_dates,\n",
      "         MIN(CASE WHEN date_rank = 2 THEN diagnosis_date END) AS second_date\n",
      "  FROM ranked_non_inpatient_dates GROUP BY patid, analysis_year\n",
      "), all_evidence AS (\n",
      "  SELECT patid, analysis_year, MIN(diagnosis_date) AS first_observed_date,\n",
      "         COUNT(*)::INTEGER AS evidence_count, MAX(lookup_version) AS lookup_version\n",
      "  FROM hiv_matches GROUP BY patid, analysis_year\n",
      ")\n",
      "SELECT ids.patid, ids.patient_id, ids.analysis_year,\n",
      "       CASE WHEN COALESCE(ip.hiv_inpatient_evidence, 0) = 1\n",
      "              OR COALESCE(op.distinct_dates, 0) >= ", threshold, "\n",
      "            THEN 1 ELSE 0 END::INTEGER AS hiv_status,\n",
      "       COALESCE(ip.hiv_inpatient_evidence, 0)::INTEGER AS hiv_inpatient_evidence,\n",
      "       COALESCE(op.distinct_dates, 0)::INTEGER AS hiv_non_inpatient_distinct_dates,\n",
      "       op.second_date AS hiv_non_inpatient_second_date,\n",
      "       all_ev.first_observed_date AS hiv_first_observed_date,\n",
      "       COALESCE(all_ev.evidence_count, 0)::INTEGER AS hiv_evidence_count,\n",
      "       COALESCE(all_ev.lookup_version, ", sql_string(hiv_versions[[1]]),
      ")::VARCHAR(128) AS lookup_version\n",
      "FROM ", ids_identifier, " ids\n",
      "LEFT JOIN inpatient_evidence ip\n",
      "  ON ip.patid = ids.patid AND ip.analysis_year = ids.analysis_year\n",
      "LEFT JOIN non_inpatient_evidence op\n",
      "  ON op.patid = ids.patid AND op.analysis_year = ids.analysis_year\n",
      "LEFT JOIN all_evidence all_ev\n",
      "  ON all_ev.patid = ids.patid AND all_ev.analysis_year = ids.analysis_year\n",
      "WHERE ids.analysis_year = 2022;"
    )
  )
  finish_phase("Calculate annual 2022 HIV status", phase_started)

  check_one_row_per_patient_year(con, status_identifier, "HIV status table")
  qa <- DBI::dbGetQuery(
    con,
    paste0(
      "SELECT COUNT(ids.patid)::BIGINT AS denominator_rows,\n",
      "       COUNT(hiv.patid)::BIGINT AS status_rows,\n",
      "       SUM(CASE WHEN hiv.hiv_status = 1 THEN 1 ELSE 0 END)::BIGINT AS positive_rows,\n",
      "       SUM(CASE WHEN hiv.hiv_status = 1 AND hiv.hiv_inpatient_evidence = 0\n",
      "                     AND hiv.hiv_non_inpatient_distinct_dates < ", threshold,
      "                THEN 1 ELSE 0 END)::BIGINT AS invalid_positive_rows,\n",
      "       SUM(CASE WHEN hiv.hiv_status = 0 AND\n",
      "                     (hiv.hiv_inpatient_evidence = 1 OR\n",
      "                      hiv.hiv_non_inpatient_distinct_dates >= ", threshold, ")\n",
      "                THEN 1 ELSE 0 END)::BIGINT AS invalid_negative_rows\n",
      "FROM ", ids_identifier, " ids\n",
      "LEFT JOIN ", status_identifier, " hiv ON hiv.patid = ids.patid"
    )
  )
  print(qa)
  if (
    qa$denominator_rows[[1]] != qa$status_rows[[1]] ||
      qa$invalid_positive_rows[[1]] != 0 ||
      qa$invalid_negative_rows[[1]] != 0
  ) {
    stop("HIV status table failed denominator or rule-concordance checks.")
  }
  invisible(config$hiv_status_table)
}

run_calculate_hiv()
