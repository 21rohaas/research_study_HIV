/* WHICH ALIAS CANONICAL DRUG NAMES DO NOT EXIST IN THE ART EXCEL? */
SELECT DISTINCT
    a.DrugName AS canonical_drug_name
FROM work_rohanramirez_a299.hiv_drug_alias a
LEFT JOIN (
    SELECT DISTINCT drug_name
    FROM work_rohanramirez_a299.hiv_art_component_lookup
) e
    ON a.DrugName = e.drug_name
WHERE e.drug_name IS NULL
ORDER BY a.DrugName;
/* POLYPHARMACY NOW 65362885 btw it takes 65 minutes to run do not fret stage 2 does verifying there isno ArT IDENTFYER */
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'work_rohanramirez_a299'
  AND table_name = 'hospice_poly12m_fills'
ORDER BY ordinal_position;
/* reconfirming my matching process */
SELECT
    COUNT(*) AS bridge_rows,
    COUNT(DISTINCT match_name) AS unique_names,
    COUNT(DISTINCT canonical_drug_name) AS art_products
FROM work_rohanramirez_a299.hiv_art_name_bridge;
/* creating a permanent art exclusion table
 * this joins my saved fills to the original pharmacy events and checks both brand and generic names. 
 * this will identify art fills using existing name bridge 
 * i got an earlier error and need to make this recomputable due to the disl size 
 * it failesd as i was trying to join a bunch -- now again permanent ART-to-NDC11 lookup first, year by year. */ 
/* 0. Read source fill-date coverage; one scan of the saved (not raw) fills. */
SELECT MIN(fill_date) AS earliest_fill, MAX(fill_date) AS latest_fill
FROM work_rohanramirez_a299.hospice_poly12m_fills;
/* 1. CREATE ONCE: intentionally new names to preserve prior failed attempts. */
CREATE TABLE IF NOT EXISTS work_rohanramirez_a299.hospice_poly12m_art_ndc_batches (
    batch_id VARCHAR(20),
    ndc11 VARCHAR(11)
)
DISTSTYLE ALL
SORTKEY(batch_id, ndc11);
CREATE TABLE IF NOT EXISTS work_rohanramirez_a299.hospice_poly12m_art_ndc_batch_status (
    batch_id VARCHAR(20),
    completed_at TIMESTAMP,
    ndc11_rows BIGINT
)
DISTSTYLE ALL
SORTKEY(batch_id);
/* reinsertable  ART ncd11 yearly batches */
BEGIN;
DELETE FROM work_rohanramirez_a299.hospice_poly12m_art_ndc_batches
WHERE batch_id = '2026';
INSERT INTO work_rohanramirez_a299.hospice_poly12m_art_ndc_batches
    (batch_id, ndc11)
SELECT DISTINCT
    '2026' AS batch_id,
    TRIM(p.ndc11) AS ndc11
FROM komodo_202610.pharmacy_events p
WHERE p.fill_date >= DATE '2026-01-01'
  AND p.fill_date <  DATE '2027-01-01'
  AND TRIM(p.ndc11) ~ '^[0-9]{11}$'
  AND (
      UPPER(TRIM(p.brand_name)) IN (
          SELECT UPPER(TRIM(match_name))
          FROM work_rohanramirez_a299.hiv_art_name_bridge
      )
      OR
      UPPER(TRIM(p.generic_name)) IN (
          SELECT UPPER(TRIM(match_name))
          FROM work_rohanramirez_a299.hiv_art_name_bridge
      )
  );
DELETE FROM work_rohanramirez_a299.hospice_poly12m_art_ndc_batch_status
WHERE batch_id = '2026';
INSERT INTO work_rohanramirez_a299.hospice_poly12m_art_ndc_batch_status
    (batch_id, completed_at, ndc11_rows)
SELECT '2026', GETDATE(), COUNT(*)
FROM work_rohanramirez_a299.hospice_poly12m_art_ndc_batches
WHERE batch_id = '2026';
COMMIT;
/* 3. CHECK saved batched for completede years. */
SELECT batch_id, completed_at, ndc11_rows
FROM work_rohanramirez_a299.hospice_poly12m_art_ndc_batch_status
ORDER BY batch_id;

SELECT COUNT(DISTINCT ndc11) AS unique_art_ndc11
FROM work_rohanramirez_a299.hospice_poly12m_art_ndc_batches;
/* double check to make sure all the batches cover the observed years */
SELECT
    EXTRACT(YEAR FROM fill_date)::INTEGER AS fill_year,
    COUNT(*) AS fills
FROM work_rohanramirez_a299.hospice_poly12m_fills
WHERE fill_date < DATE '2016-01-01'
GROUP BY 1
ORDER BY 1;
/* this is the art exclusion table.  RUN ONLY AFTER ALL SOURCE FILL-DATE BATCHES HAVE COMPLETED 
  This final CTAS reads ONLY saved cohort fills and a small, permanent
  NDC11 catalog, not the giant komodo_202610.pharmacy_events table.
*/
CREATE TABLE work_rohanramirez_a299.hospice_poly12m_art_exclusions_v2
DISTKEY(patient_id)
SORTKEY(patient_id, pharmacy_event_id) AS
SELECT
    f.index_id,
    f.patient_id,
    f.pharmacy_event_id,
    f.fill_date,
    f.ndc11
FROM work_rohanramirez_a299.hospice_poly12m_fills f
WHERE EXISTS (
    SELECT 1
    FROM work_rohanramirez_a299.hospice_poly12m_art_ndc_batches a
    WHERE a.ndc11 = f.ndc11
);

SELECT COUNT(*) AS excluded_index_fill_rows,
       COUNT(DISTINCT index_id) AS indices_with_art,
       COUNT(DISTINCT ndc11) AS excluded_ndc11
FROM work_rohanramirez_a299.hospice_poly12m_art_exclusions_v2;
/* how many art fills were identified */
SELECT
    COUNT(*) AS excluded_art_fills,
    COUNT(DISTINCT index_id) AS patients_with_art,
    COUNT(DISTINCT ndc11) AS unique_art_ndc11
FROM work_rohanramirez_a299.hospice_poly12m_art_exclusions_v2;
/* now i need to see how many of these are hiv positive and hiv negative */
WITH art_patients AS (
    SELECT DISTINCT patient_id
    FROM work_rohanramirez_a299.hospice_poly12m_art_exclusions_v2
)
SELECT
    h.hiv_status,
    COUNT(*) AS total_patients,
    COUNT(a.patient_id) AS patients_with_art,
    COUNT(*) - COUNT(a.patient_id) AS patients_without_art
FROM work_rohanramirez_a299.hospice_f_candidates h
LEFT JOIN art_patients a
    ON h.patient_id = a.patient_id
GROUP BY h.hiv_status
ORDER BY h.hiv_status;
/* Top 200 unmapped non-ART NDCs, ranked by pharmacy fill frequency */
DROP TABLE IF EXISTS work_rohanramirez_a299.unmapped_stage3_ndcs;
CREATE TABLE work_rohanramirez_a299.unmapped_stage3_ndcs
DISTSTYLE ALL
SORTKEY(priority_rank) AS
WITH unmapped AS (
    SELECT ndc11
    FROM work_rohanramirez_a299.hospice_poly12m_crosswalk
    GROUP BY ndc11
    HAVING MAX(CASE WHEN mapping_status = 'mapped' THEN 1 ELSE 0 END) = 0
),
counts AS (
    SELECT
        f.ndc11,
        COUNT(*) AS fill_records
    FROM work_rohanramirez_a299.hospice_poly12m_fills f
    JOIN unmapped u ON f.ndc11 = u.ndc11
    WHERE NOT EXISTS (
        SELECT 1
        FROM work_rohanramirez_a299.hospice_poly12m_art_exclusions_v2 e
        WHERE f.index_id = e.index_id
          AND f.patient_id = e.patient_id
          AND f.pharmacy_event_id = e.pharmacy_event_id
          AND f.ndc11 = e.ndc11
    )
    GROUP BY f.ndc11
),
ranked AS (
    SELECT
        ndc11,
        fill_records,
        ROW_NUMBER() OVER (
            ORDER BY fill_records DESC, ndc11
        ) AS priority_rank
    FROM counts
)
SELECT
    priority_rank,
    ndc11,
    fill_records
FROM ranked
WHERE priority_rank <= 200;
/* Verify the top 200 unmapped NDCs */
SELECT *
FROM work_rohanramirez_a299.unmapped_stage3_ndcs
ORDER BY priority_rank;
/* checking now the mapped ndcs */
SELECT *
FROM work_rohanramirez_a299.bridging_unmapped_ndcs
ORDER BY priority_rank;

SELECT
    fda_match_status,
    COUNT(*) AS ndcs,
    SUM(fill_records) AS fill_records,
    ROUND(
        100.0 * SUM(fill_records) /
        SUM(SUM(fill_records)) OVER (),
        2
    ) AS pct_top200_fills
FROM work_rohanramirez_a299.bridging_unmapped_ndcs
GROUP BY fda_match_status
ORDER BY fill_records DESC;
/* Identify the years in which unmatched NDCs appeared */
/* Uses saved Stage 2 fills and the existing FDA bridge */
SELECT
    b.priority_rank,
    b.ndc11,
    b.fill_records,
    MIN(f.fill_date) AS first_fill_date,
    MAX(f.fill_date) AS last_fill_date
FROM work_rohanramirez_a299.bridging_unmapped_ndcs b
JOIN work_rohanramirez_a299.hospice_poly12m_fills f
    ON b.ndc11 = f.ndc11
WHERE b.fda_match_status = 'NOT_FOUND'
  AND NOT EXISTS (
      SELECT 1
      FROM work_rohanramirez_a299.hospice_poly12m_art_exclusions_v2 e
      WHERE f.index_id = e.index_id
        AND f.patient_id = e.patient_id
        AND f.pharmacy_event_id = e.pharmacy_event_id
        AND f.ndc11 = e.ndc11
  )
GROUP BY
    b.priority_rank,
    b.ndc11,
    b.fill_records
ORDER BY b.priority_rank;
/* reran stage 3 so lets see result */
SELECT
    exposure_status,
    metrics_status,
    mapping_version
FROM work_rohanramirez_a299.hospice_poly12m_pipeline_state;
/* checking stage 4*/
SELECT
    exposure_status,
    metrics_status,
    mapping_version
FROM work_rohanramirez_a299.hospice_poly12m_pipeline_state;
/* Polypharmacy prevalence by HIV status */

/* Polypharmacy descriptive statistics by HIV status */
SELECT
    CASE
        WHEN c.hiv_status = TRUE THEN 'HIV-positive'
        ELSE 'HIV-algorithm-negative'
    END AS hiv_group,
    COUNT(*) AS n_patients,
    SUM(p.polypharmacy) AS n_polypharmacy,
    ROUND(100.0 * SUM(p.polypharmacy) / NULLIF(COUNT(*), 0), 2)
        AS percent_polypharmacy,
    ROUND(AVG(p.days_5plus_atc3), 2) AS mean_qualifying_days,
    PERCENTILE_CONT(0.50) WITHIN GROUP (
        ORDER BY p.days_5plus_atc3
    ) AS median_qualifying_days,
    PERCENTILE_CONT(0.25) WITHIN GROUP (
        ORDER BY p.days_5plus_atc3
    ) AS q1_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (
        ORDER BY p.days_5plus_atc3
    ) AS q3_days,
    SUM(CASE WHEN p.n_unmapped_fills > 0 THEN 1 ELSE 0 END)
        AS patients_with_unmapped_fills,
    SUM(p.n_unmapped_fills) AS total_unmapped_fills,
    SUM(CASE WHEN p.n_fills = 0 THEN 1 ELSE 0 END)
        AS patients_without_fills
FROM work_rohanramirez_a299.hospice_poly12m_metrics p
JOIN work_rohanramirez_a299.hospice_f_candidates c
    ON p.patient_id = c.patient_id
WHERE c.hiv_status IS NOT NULL
GROUP BY 1
ORDER BY 1;












