/* to see how long the query has been running */
SELECT
    query_id,
    status,
    start_time,
    ROUND(elapsed_time / 60000000.0, 1) AS elapsed_minutes,
    ROUND(queue_time / 60000000.0, 1) AS queue_minutes,
    ROUND(execution_time / 60000000.0, 1) AS execution_minutes,
    error_message,
    LEFT(query_text, 200) AS query_text
FROM sys_query_history
WHERE query_text ILIKE '%patients_with_valid_claims%'
  AND query_text NOT ILIKE '%sys_query_history%'
ORDER BY start_time DESC
LIMIT 10;

/* Recreate original ART-fill table ONCE. Do not rerun after yearly inserts. cause i had to fix it to include only valid pharmacy claims no reversals*/
/* inserting patients in HIV positive only by year 
 * 2016 C
 * 2017 C
 * 2018 C
 * 2019 C
 * 2020 C
 * 2021 C
 * 2022 C
 * 2023 C
 * 2024 C
 * 2025 C
 * 2026*/ 
BEGIN;
DELETE FROM work_rohanramirez_a299.hiv_art_rx_fills_12m
WHERE EXTRACT(YEAR FROM hospice_date) = 2026;
INSERT INTO work_rohanramirez_a299.hiv_art_rx_fills_12m
WITH h AS (
    SELECT
        patient_id,
        event_date AS hospice_date
    FROM work_rohanramirez_a299.hospice_f_candidates
    WHERE hiv_status = TRUE
      AND event_date >= DATE '2026-01-01'
      AND event_date <  DATE '2027-01-01'
),
pharmacy_names AS (
    /* BRAND NAME */
    SELECT
        h.patient_id,
        h.hospice_date,
        p.fill_date::DATE AS fill_date,
        CAST(p.days_supply AS INTEGER) AS days_supply,
        UPPER(TRIM(p.brand_name)) AS pharmacy_name
    FROM h
    INNER JOIN komodo_202610.pharmacy_events p
        ON h.patient_id = p.patient_id
       /* fill must occur before hospice */
       AND p.fill_date::DATE < h.hospice_date
       /* medication supply overlaps the 365-day pre-hospice window */
       AND DATEADD(
               day,
               CAST(p.days_supply AS INTEGER),
               p.fill_date::DATE
           ) > DATEADD(day, -365, h.hospice_date)
    WHERE p.brand_name IS NOT NULL
      AND p.days_supply IS NOT NULL
      AND p.days_supply > 0
      /* valid paid pharmacy claim; reversed claims do not count as coverage */
      AND UPPER(TRIM(p.transaction_result)) = 'PAID'
      AND UPPER(TRIM(p.transaction_status)) IN ('FINAL', 'STANDALONE')
      AND TRIM(p.ndc11) ~ '^[0-9]{11}$'
      /* exclude PrEP/HBV products by brand even if the generic also matches */
      AND COALESCE(UPPER(TRIM(p.brand_name)), '') NOT LIKE '%APRETUDE%'
      AND COALESCE(UPPER(TRIM(p.brand_name)), '') NOT LIKE '%VEMLIDY%' 
    UNION ALL
    /* GENERIC NAME */
    SELECT
        h.patient_id,
        h.hospice_date,
        p.fill_date::DATE AS fill_date,
        CAST(p.days_supply AS INTEGER) AS days_supply,
        UPPER(TRIM(p.generic_name)) AS pharmacy_name
    FROM h
    INNER JOIN komodo_202610.pharmacy_events p
        ON h.patient_id = p.patient_id
       /* fill must occur before hospice */
       AND p.fill_date::DATE < h.hospice_date
       /* medication supply overlaps the 365-day pre-hospice window */
       AND DATEADD(
               day,
               CAST(p.days_supply AS INTEGER),
               p.fill_date::DATE
           ) > DATEADD(day, -365, h.hospice_date)
    WHERE p.generic_name IS NOT NULL
      AND p.days_supply IS NOT NULL
      AND p.days_supply > 0
      /* valid paid pharmacy claim; reversed claims do not count as coverage */
      AND UPPER(TRIM(p.transaction_result)) = 'PAID'
      AND UPPER(TRIM(p.transaction_status)) IN ('FINAL', 'STANDALONE')
      AND TRIM(p.ndc11) ~ '^[0-9]{11}$'
      /* exclude PrEP/HBV products by brand even if the generic also matches */
      AND COALESCE(UPPER(TRIM(p.brand_name)), '') NOT LIKE '%APRETUDE%'
      AND COALESCE(UPPER(TRIM(p.brand_name)), '') NOT LIKE '%VEMLIDY%' 
)
SELECT DISTINCT
    p.patient_id,
    p.hospice_date,
    p.fill_date,
    p.days_supply,
    b.canonical_drug_name
FROM pharmacy_names p
INNER JOIN work_rohanramirez_a299.hiv_art_name_bridge b
    ON p.pharmacy_name = UPPER(TRIM(b.match_name))
/* APRETUDE (PrEP) and VEMLIDY (HBV) do not count toward ART PDC.
 * Exclude their canonical names too, regardless of how the name was matched.
 * Brand-missing generic claims may remain indication-ambiguous.
 */
WHERE UPPER(TRIM(b.canonical_drug_name)) NOT IN ('APRETUDE', 'VEMLIDY');
COMMIT;
/* quality check */
/*  check on the years */ 
SELECT
    EXTRACT(YEAR FROM hospice_date)::INT AS hospice_year,
    COUNT(*) AS fill_rows,
    COUNT(DISTINCT patient_id) AS patients_with_art_fills
FROM work_rohanramirez_a299.hiv_art_rx_fills_12m
GROUP BY EXTRACT(YEAR FROM hospice_date)
ORDER BY hospice_year;
/* seeing range of mds */
SELECT
    MIN(days_supply) AS min_days,
    MAX(days_supply) AS max_days,
    AVG(days_supply) AS mean_days,
    SUM(CASE WHEN days_supply > 365 THEN 1 ELSE 0 END) AS over_365
FROM work_rohanramirez_a299.hiv_art_rx_fills_12m;
/* componenbt level fill table */
DROP TABLE IF EXISTS work_rohanramirez_a299.hiv_art_component_fills_12m;
/* 35,189 ART fill rows representing 1,833 HIV positive patients with at least one matched ART fille */ 
/* previous result: 35,189 ART fill rows representing 1,833 HIV positive patients; will change after paid-claim filtering */ 
CREATE TABLE work_rohanramirez_a299.hiv_art_component_fills_12m
DISTKEY(patient_id)
SORTKEY(patient_id, fill_date) AS
SELECT DISTINCT
    f.patient_id,
    f.hospice_date,
    f.fill_date,
    f.days_supply,
    f.canonical_drug_name,
    c.drug_abrv,
    c.cmpnt_abrv,
    c.drug_class,
    c.delivery,
    /* first covered day inside the 365-day pre-hospice window */
    GREATEST(
        f.fill_date,
        DATEADD(day, -365, f.hospice_date)
    ) AS coverage_start,
    /* exclusive end of medication coverage */
    LEAST(
        DATEADD(
            day,
            CAST(f.days_supply AS INTEGER),
            f.fill_date
        ),
        f.hospice_date
    ) AS coverage_end
FROM work_rohanramirez_a299.hiv_art_rx_fills_12m f
INNER JOIN work_rohanramirez_a299.hiv_art_component_lookup c
    ON f.canonical_drug_name = c.drug_name;
/* checxk that the component table contains every year */
   SELECT
    EXTRACT(YEAR FROM hospice_date)::INT AS hospice_year,
    COUNT(*) AS component_fill_rows,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT canonical_drug_name) AS products,
    COUNT(DISTINCT cmpnt_abrv) AS components
FROM work_rohanramirez_a299.hiv_art_component_fills_12m
GROUP BY EXTRACT(YEAR FROM hospice_date)
ORDER BY hospice_year;
/* run the interval checkswhere i should get back 0 */
SELECT COUNT(*) AS bad_component_intervals
FROM work_rohanramirez_a299.hiv_art_component_fills_12m
WHERE coverage_end <= coverage_start;
SELECT COUNT(*) AS outside_window
FROM work_rohanramirez_a299.hiv_art_component_fills_12m
WHERE coverage_start < DATEADD(day, -365, hospice_date)
   OR coverage_end > hospice_date;
/* 
 * PERCENTAGE OF HIV POSITIVE PATIENTS IN EACH HIOSPICE YEAR WHO HAD A MATCHED ART FILL 
 * 
 * 
 */
WITH hiv_by_year AS (
    SELECT
        EXTRACT(YEAR FROM event_date)::INT AS hospice_year,
        COUNT(DISTINCT patient_id) AS hiv_positive_patients
    FROM work_rohanramirez_a299.hospice_f_candidates
    WHERE hiv_status = TRUE
    GROUP BY EXTRACT(YEAR FROM event_date)
),
art_by_year AS (
    SELECT
        EXTRACT(YEAR FROM hospice_date)::INT AS hospice_year,
        COUNT(DISTINCT patient_id) AS patients_with_art_fills
    FROM work_rohanramirez_a299.hiv_art_rx_fills_12m
    GROUP BY EXTRACT(YEAR FROM hospice_date)
)
SELECT
    h.hospice_year,
    h.hiv_positive_patients,
    COALESCE(a.patients_with_art_fills, 0) AS patients_with_art_fills,
    ROUND(
        100.0 * COALESCE(a.patients_with_art_fills, 0)
        / h.hiv_positive_patients,
        1
    ) AS percent_with_art_fills
FROM hiv_by_year h
LEFT JOIN art_by_year a
    ON h.hospice_year = a.hospice_year
ORDER BY h.hospice_year;
/* check dual-use medications in our ART name bridge */
SELECT DISTINCT
    canonical_drug_name
FROM work_rohanramirez_a299.hiv_art_name_bridge
WHERE UPPER(canonical_drug_name) LIKE '%DESCOVY%'
   OR UPPER(canonical_drug_name) LIKE '%TRUVADA%'
   OR UPPER(canonical_drug_name) LIKE '%VIREAD%'
   OR UPPER(canonical_drug_name) LIKE '%EPIVIR%'
   OR UPPER(canonical_drug_name) LIKE '%LAMIVUDINE%'
   OR UPPER(canonical_drug_name) LIKE '%TENOFOVIR%'
ORDER BY canonical_drug_name;

/* examine 2-component versus 3+-component ART coverage */
SELECT
    CASE
        WHEN n_art_components = 0 THEN '0 components'
        WHEN n_art_components = 1 THEN '1 component'
        WHEN n_art_components = 2 THEN '2 components'
        ELSE '3+ components'
    END AS coverage_group,
    n_art_products,
    COUNT(*) AS patient_days,
    COUNT(DISTINCT patient_id) AS patients
FROM work_rohanramirez_a299.hiv_art_daily_coverage_12m
GROUP BY 1, 2
ORDER BY 1, 2;
/* now i go to do pdc 
 * 
 * 
 */
DROP TABLE IF EXISTS work_rohanramirez_a299.hiv_art_daily_coverage_12m;
CREATE TABLE work_rohanramirez_a299.hiv_art_daily_coverage_12m
DISTKEY(patient_id)
SORTKEY(patient_id, coverage_day) AS
WITH digits AS (
    SELECT 0 AS n UNION ALL
    SELECT 1 UNION ALL
    SELECT 2 UNION ALL
    SELECT 3 UNION ALL
    SELECT 4 UNION ALL
    SELECT 5 UNION ALL
    SELECT 6 UNION ALL
    SELECT 7 UNION ALL
    SELECT 8 UNION ALL
    SELECT 9
),
offsets AS (
    SELECT
        a.n
        + 10 * b.n
        + 100 * c.n AS day_offset
    FROM digits a
    CROSS JOIN digits b
    CROSS JOIN digits c
    WHERE a.n + 10 * b.n + 100 * c.n < 365
),
patients AS (
    SELECT DISTINCT
        patient_id,
        hospice_date
    FROM work_rohanramirez_a299.hiv_art_rx_fills_12m
),
patient_days AS (
    SELECT
        p.patient_id,
        p.hospice_date,
        DATEADD(
            day,
            CAST(o.day_offset AS INTEGER),
            DATEADD(day, -365, p.hospice_date)
        ) AS coverage_day
    FROM patients p
    CROSS JOIN offsets o
)
SELECT
    d.patient_id,
    d.hospice_date,
    d.coverage_day,
    COUNT(DISTINCT c.cmpnt_abrv) AS n_art_components,
    COUNT(DISTINCT c.canonical_drug_name) AS n_art_products,
    MAX(
        CASE
            WHEN c.delivery = 'TWO DRUG'
            THEN 1 ELSE 0
        END
    ) AS has_two_drug_product,
    MAX(
        CASE
            WHEN c.delivery = 'SINGLE REGIMEN'
            THEN 1 ELSE 0
        END
    ) AS has_single_regimen_product
FROM patient_days d
LEFT JOIN work_rohanramirez_a299.hiv_art_component_fills_12m c
    ON d.patient_id = c.patient_id
   AND d.coverage_day >= c.coverage_start
   AND d.coverage_day < c.coverage_end
GROUP BY
    d.patient_id,
    d.hospice_date,
    d.coverage_day;
/* coverage_start <= day < coverage_end so a 30 day perscription only contrbutes only 30 days */
/* i will check it now */
 SELECT
    COUNT(*) AS patient_days,
    COUNT(DISTINCT patient_id) AS patients,
    MIN(n_art_components) AS min_components,
    MAX(n_art_components) AS max_components
FROM work_rohanramirez_a299.hiv_art_daily_coverage_12m;
/* lets see how many art components patients hav each day */
SELECT
    n_art_components,
    COUNT(*) AS patient_days,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (),
        1
    ) AS pct_patient_days
FROM work_rohanramirez_a299.hiv_art_daily_coverage_12m
GROUP BY n_art_components
ORDER BY n_art_components;
/* i need to calculate the patient level pdc */ 
WITH patient_max AS (
    SELECT
        patient_id,
        MAX(n_art_components) AS max_components
    FROM work_rohanramirez_a299.hiv_art_daily_coverage_12m
    GROUP BY patient_id
)
SELECT
    max_components,
    COUNT(*) AS patients
FROM patient_max
GROUP BY max_components
ORDER BY max_components;
/* i see here the issue is the ot os a BOOSter
ALTER TABLE work_rohanramirez_a299.hiv_art_daily_coverage_12m
ADD COLUMN n_active_art_components INTEGER;  */ 
/* populate with components fills */
 DROP TABLE IF EXISTS work_rohanramirez_a299.hiv_art_pdc_summary;
 CREATE TABLE work_rohanramirez_a299.hiv_art_pdc_summary
DISTKEY(patient_id)
SORTKEY(patient_id) AS
WITH patient_coverage AS (
    SELECT
        patient_id,
        MAX(hospice_date) AS hospice_date,
        /* PRIMARY VERSION: booster counts */
        SUM(
            CASE
                WHEN n_art_components >= 2
                THEN 1 ELSE 0
            END
        ) AS days_covered_2plus
    FROM work_rohanramirez_a299.hiv_art_daily_coverage_12m
    GROUP BY patient_id
)
SELECT
    patient_id,
    hospice_date,
    days_covered_2plus,
    /* booster INCLUDED */
    days_covered_2plus / 365.0 AS art_pdc
FROM patient_coverage;
 /* CHECKING IT */
SELECT
    COUNT(*) AS patients,
    MIN(art_pdc) AS min_pdc,
    MAX(art_pdc) AS max_pdc,
    AVG(art_pdc) AS mean_pdc
FROM work_rohanramirez_a299.hiv_art_pdc_summary;
/* now add the columns (do this if not done) 
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN art_pdc DECIMAL(6,5); /* booster */ 
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN art_pdc_calculable BOOLEAN; */ 
/* due to redoing this */
/* clear previous ART PDC and nonadherence results */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET
    art_pdc = NULL,
    art_pdc_calculable =
        CASE WHEN hiv_status = TRUE THEN FALSE ELSE NULL END,
    nonadherent_80 = NULL,
    nonadherent_85 = NULL,
    nonadherent_95 = NULL;
/* update the calculatable hiv + patients yay btw */
/* calculate the nonadherence flags using the revised PDC */
UPDATE work_rohanramirez_a299.hospice_f_candidates h
SET
    art_pdc = p.art_pdc,
    art_pdc_calculable = TRUE,
    nonadherent_80 =
        CASE WHEN p.art_pdc < 0.80 THEN 1 ELSE 0 END,
    nonadherent_85 =
        CASE WHEN p.art_pdc < 0.85 THEN 1 ELSE 0 END,
    nonadherent_95 =
        CASE WHEN p.art_pdc < 0.95 THEN 1 ELSE 0 END
FROM work_rohanramirez_a299.hiv_art_pdc_summary p
WHERE h.patient_id = p.patient_id
  AND h.hiv_status = TRUE
  AND p.art_pdc IS NOT NULL;
/* corrected PDc distribution */
 /* final ART PDC validation for HIV-positive hospice patients */
SELECT
    COUNT(*) AS hiv_positive,
    SUM(CASE WHEN art_pdc IS NOT NULL
        THEN 1 ELSE 0 END) AS pdc_calculable,
    SUM(CASE WHEN art_pdc IS NULL
        THEN 1 ELSE 0 END) AS pdc_missing,
    SUM(CASE WHEN art_pdc = 0
        THEN 1 ELSE 0 END) AS pdc_zero,
    SUM(CASE WHEN art_pdc > 0
        THEN 1 ELSE 0 END) AS pdc_above_zero,
    SUM(CASE WHEN art_pdc = 1
        THEN 1 ELSE 0 END) AS pdc_full_coverage,
    ROUND(AVG(art_pdc), 3) AS mean_pdc
FROM work_rohanramirez_a299.hospice_f_candidates
WHERE hiv_status = TRUE;
/* median summary stats */
/* ART PDC descriptive statistics */
SELECT
    COUNT(*) AS patients,
    ROUND(AVG(art_pdc), 3) AS mean_pdc,
    ROUND(
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY art_pdc)::DECIMAL(10,5),
        3
    ) AS median_pdc,
    MIN(art_pdc) AS min_pdc,
    MAX(art_pdc) AS max_pdc
FROM work_rohanramirez_a299.hiv_art_pdc_summary
WHERE art_pdc IS NOT NULL;
/* final check */
/* verify the 28 patients with PDC = 0 yes they have 1 max component */
SELECT
    MAX(d.n_art_components) AS max_components,
    COUNT(DISTINCT d.patient_id) AS patients
FROM work_rohanramirez_a299.hiv_art_daily_coverage_12m d
JOIN work_rohanramirez_a299.hiv_art_pdc_summary p
    ON d.patient_id = p.patient_id
WHERE p.art_pdc = 0
GROUP BY d.patient_id;
/* the IQR stats */
WITH quartiles AS (
    SELECT
        COUNT(*) AS patients,
        AVG(art_pdc) AS mean_pdc,
        PERCENTILE_CONT(0.25)
        WITHIN GROUP (ORDER BY art_pdc)::DECIMAL(10,5) AS q1,
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY art_pdc)::DECIMAL(10,5) AS median_pdc,
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (ORDER BY art_pdc)::DECIMAL(10,5) AS q3
    FROM work_rohanramirez_a299.hiv_art_pdc_summary
    WHERE art_pdc IS NOT NULL
)
SELECT
    patients,
    ROUND(mean_pdc, 3) AS mean_pdc,
    ROUND(q1, 3) AS q1_25th,
    ROUND(median_pdc, 3) AS median_pdc,
    ROUND(q3, 3) AS q3_75th,
    ROUND(q3 - q1, 3) AS iqr
FROM quartiles;
