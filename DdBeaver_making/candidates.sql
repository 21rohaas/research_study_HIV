/* alright, getting into this, this sql identified mx/rx closed periods a year before entering hospice
 * second, made a hospice candidates where I added in the age over 50 requirement when they enter hospice 
 * BIG thing HIV identification, this encompasses all 3 routes. we see outpatient, inpatient, then meds. at the end you can see the specifc pharmacy medication distinct
 * for those who were only pharmacy positive  
 * 
 * 
 */

/* DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_index; */
CREATE TABLE work_rohanramirez_a299.hospice_candidates
DISTKEY(patient_id)
SORTKEY(patient_id, event_date) AS
SELECT *
FROM (
    SELECT *
    FROM work_rohanramirez_a299.hospice_inpatient_admission_events
    UNION ALL
    SELECT *
    FROM work_rohanramirez_a299.hospice_nonip_admission_events
) combined
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY patient_id
    ORDER BY event_date
) = 1;
/* lets do a distribution of the combinations of bill type code */
/* frequency table now of admission candidates before we narrow down */
SELECT
    place_code,
    level_code,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_candidates
GROUP BY place_code, level_code
ORDER BY place_code, level_code;
/* now we are adding in another column */
ALTER TABLE work_rohanramirez_a299.hospice_candidates
ADD COLUMN closed_both_1yr BOOLEAN;
/* populating the table for closed requirement tohave True or False  */
WITH ordered AS (
    SELECT
        patient_id,
        closed_type,
        closed_start_date::DATE AS closed_start_date,
        closed_end_date::DATE AS closed_end_date,
        MAX(closed_end_date::DATE) OVER (
            PARTITION BY patient_id, closed_type
            ORDER BY closed_start_date, closed_end_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_end
    FROM komodo_202606.patient_closed
    WHERE closed_type IN ('MX CLOSED', 'RX CLOSED')
),
marked AS (
    SELECT
        *,
        CASE
            WHEN prior_max_end IS NULL
              OR closed_start_date > DATEADD(day, 1, prior_max_end)
            THEN 1
            ELSE 0
        END AS new_group
    FROM ordered
),
grouped AS (
    SELECT
        *,
        SUM(new_group) OVER (
            PARTITION BY patient_id, closed_type
            ORDER BY closed_start_date, closed_end_date
            ROWS UNBOUNDED PRECEDING
        ) AS coverage_group
    FROM marked
),
continuous_periods AS (
    SELECT
        patient_id,
        closed_type,
        MIN(closed_start_date) AS coverage_start,
        MAX(closed_end_date) AS coverage_end
    FROM grouped
    GROUP BY patient_id, closed_type, coverage_group
),
coverage_flags AS (
    SELECT
        h.patient_id,
        MAX(
            CASE
                WHEN c.closed_type = 'MX CLOSED'
                 AND c.coverage_start <= DATEADD(year, -1, h.event_date)
                 AND c.coverage_end >= DATEADD(day, -1, h.event_date)
                THEN 1 ELSE 0
            END
        ) AS mx_ok,
        MAX(
            CASE
                WHEN c.closed_type = 'RX CLOSED'
                 AND c.coverage_start <= DATEADD(year, -1, h.event_date)
                 AND c.coverage_end >= DATEADD(day, -1, h.event_date)
                THEN 1 ELSE 0
            END
        ) AS rx_ok
    FROM work_rohanramirez_a299.hospice_candidates h
    LEFT JOIN continuous_periods c
        ON h.patient_id = c.patient_id
    GROUP BY h.patient_id
)
UPDATE work_rohanramirez_a299.hospice_candidates
SET closed_both_1yr =
    CASE
        WHEN f.mx_ok = 1
         AND f.rx_ok = 1
        THEN TRUE
        ELSE FALSE
    END
FROM coverage_flags f
WHERE work_rohanramirez_a299.hospice_candidates.patient_id = f.patient_id;
/* now quality checking */
/* the [v] means true */ 
/* the other means false */
SELECT
    closed_both_1yr,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_candidates
GROUP BY closed_both_1yr
ORDER BY closed_both_1yr;
/* adding in 2 columns i will be doing MX constant insurance */
/* adding column for doing MX and RX insurance column too */
ALTER TABLE work_rohanramirez_a299.hospice_candidates
ADD COLUMN mx_constant_insurance BOOLEAN;
ALTER TABLE work_rohanramirez_a299.hospice_candidates
ADD COLUMN mx_rx_constant_insurance BOOLEAN;
/* 
 * same group repeated/renewed with touching dates
-- merge it
same group with a true gap
-- fails continuous insurance
different group during the year
-- fails constant insurance

For the entire 12 months immediately before event_date,can the patient's insurance rows 
be pieced together into one unbroken interval under the same insurance group

MX:
same mx_insurance_group
+ dates piece together without gaps
+ covers entire 12 months
= mx_constant_insurance TRUE

MX + RX:
MX passes above
AND
same rx_insurance_group
+ RX dates piece together without gaps
+ covers entire 12 months
= mx_rx_constant_insurance TRUE

these are the decisions the code walks through 
MX fails
--- mx_constant_insurance = FALSE
---mx_rx_constant_insurance = FALSE
--- don't care what RX says

MX passes
--- mx_constant_insurance = TRUE
--- then check RX
    RX passes ---TRUE
    RX fails  --- FALSE
 */
/* setting both flags to false */
UPDATE work_rohanramirez_a299.hospice_candidates
SET
    mx_constant_insurance = FALSE,
    mx_rx_constant_insurance = FALSE
WHERE closed_both_1yr = TRUE;
/* mx continuity */
WITH ordered AS (
    SELECT
        h.patient_id,
        h.event_date,
        i.mx_insurance_group AS insurance_group,
        i.row_valid_start::DATE AS start_date,
        i.row_valid_end::DATE AS end_date,
        MAX(i.row_valid_end::DATE) OVER (
            PARTITION BY h.patient_id, i.mx_insurance_group
            ORDER BY i.row_valid_start, i.row_valid_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_end
    FROM work_rohanramirez_a299.hospice_candidates h
    INNER JOIN komodo_202606.patient_insurance i
        ON h.patient_id = i.patient_id
       AND i.row_valid_end >= DATEADD(year, -1, h.event_date)
       AND i.row_valid_start < h.event_date
    WHERE h.closed_both_1yr = TRUE
      AND i.mx_insurance_group IS NOT NULL
),
marked AS (
    SELECT
        *,
        CASE
            WHEN prior_max_end IS NULL
              OR start_date > DATEADD(day, 1, prior_max_end)
            THEN 1
            ELSE 0
        END AS new_interval
    FROM ordered
),
grouped AS (
    SELECT
        *,
        SUM(new_interval) OVER (
            PARTITION BY patient_id, insurance_group
            ORDER BY start_date, end_date
            ROWS UNBOUNDED PRECEDING
        ) AS interval_group
    FROM marked
),
continuous_periods AS (
    SELECT
        patient_id,
        event_date,
        insurance_group,
        MIN(start_date) AS coverage_start,
        MAX(end_date) AS coverage_end
    FROM grouped
    GROUP BY
        patient_id,
        event_date,
        insurance_group,
        interval_group
),
mx_pass AS (
    SELECT DISTINCT patient_id
    FROM continuous_periods
    WHERE coverage_start <= DATEADD(year, -1, event_date)
      AND coverage_end >= DATEADD(day, -1, event_date)
)
UPDATE work_rohanramirez_a299.hospice_candidates
SET mx_constant_insurance = TRUE
FROM mx_pass m
WHERE hospice_candidates.patient_id = m.patient_id;
/* only checking for RX for patientswho passed MX only */
WITH ordered AS (
    SELECT
        h.patient_id,
        h.event_date,
        i.rx_insurance_group AS insurance_group,
        i.row_valid_start::DATE AS start_date,
        i.row_valid_end::DATE AS end_date,
        MAX(i.row_valid_end::DATE) OVER (
            PARTITION BY h.patient_id, i.rx_insurance_group
            ORDER BY i.row_valid_start, i.row_valid_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_end
    FROM work_rohanramirez_a299.hospice_candidates h
    INNER JOIN komodo_202606.patient_insurance i
        ON h.patient_id = i.patient_id
       AND i.row_valid_end >= DATEADD(year, -1, h.event_date)
       AND i.row_valid_start < h.event_date
    WHERE h.closed_both_1yr = TRUE
      AND h.mx_constant_insurance = TRUE
      AND i.rx_insurance_group IS NOT NULL
),
marked AS (
    SELECT
        *,
        CASE
            WHEN prior_max_end IS NULL
              OR start_date > DATEADD(day, 1, prior_max_end)
            THEN 1
            ELSE 0
        END AS new_interval
    FROM ordered
),
grouped AS (
    SELECT
        *,
        SUM(new_interval) OVER (
            PARTITION BY patient_id, insurance_group
            ORDER BY start_date, end_date
            ROWS UNBOUNDED PRECEDING
        ) AS interval_group
    FROM marked
),
continuous_periods AS (
    SELECT
        patient_id,
        event_date,
        insurance_group,
        MIN(start_date) AS coverage_start,
        MAX(end_date) AS coverage_end
    FROM grouped
    GROUP BY
        patient_id,
        event_date,
        insurance_group,
        interval_group
),
rx_pass AS (
    SELECT DISTINCT patient_id
    FROM continuous_periods
    WHERE coverage_start <= DATEADD(year, -1, event_date)
      AND coverage_end >= DATEADD(day, -1, event_date)
)
UPDATE work_rohanramirez_a299.hospice_candidates 
SET mx_rx_constant_insurance = TRUE
FROM rx_pass r
WHERE hospice_candidates.patient_id = r.patient_id;
/* counts */
SELECT
    mx_rx_constant_insurance,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_candidates
WHERE closed_both_1yr = TRUE
GROUP BY mx_rx_constant_insurance
ORDER BY mx_rx_constant_insurance;
/* now lets do age rewquirement ill start with adding age at entrance of hospice */
ALTER TABLE work_rohanramirez_a299.hospice_candidates
ADD COLUMN age_at_hospice INTEGER;
/* now altering age from patient_dob and hospice event_date. I also made sure to not to call someone 50 before they are 50 */
UPDATE work_rohanramirez_a299.hospice_candidates
SET age_at_hospice =
    DATEDIFF(year, d.patient_dob, hospice_candidates.event_date)
    -
    CASE
        WHEN DATEADD(
                 year,
                 DATEDIFF(year, d.patient_dob, hospice_candidates.event_date),
                 d.patient_dob
             ) > hospice_candidates.event_date
        THEN 1
        ELSE 0
    END
FROM komodo_202606.patient_demographics d
WHERE hospice_candidates.patient_id = d.patient_id;
/* now doing a simple count of who is 50 and up upon admission */
SELECT
    CASE
        WHEN age_at_hospice >= 50 THEN '50+'
        ELSE '<50'
    END AS age_group,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_candidates
WHERE closed_both_1yr = TRUE
  AND mx_rx_constant_insurance = TRUE
GROUP BY 1
ORDER BY 1;
/* now after finding only 915,470 maks the cutoff as it is 50 and up. this carries into HIV indentification  */
/* hiv identification will be made into a new table */
/*   DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_f_candidates;  */
CREATE TABLE work_rohanramirez_a299.hospice_f_candidates
DISTKEY(patient_id)
SORTKEY(patient_id, event_date) AS
SELECT *
FROM work_rohanramirez_a299.hospice_candidates
WHERE closed_both_1yr = TRUE
  AND mx_rx_constant_insurance = TRUE
  AND age_at_hospice >= 50;
/* check now */
SELECT COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates;
/*
 * The protocol definition is:
 >= 1 inpatient HIV diagnosis, or
 >= 2 outpatient HIV diagnoses, or
 >= 2 successive fills/refills for HIV medications, excluding lamivudine-only evidence (as it can treat hep B) .
 */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN medicaid_primary BOOLEAN;
/*now i continues to update it */ 
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET
    medicaid_primary = false;
/* medicaid as a primary insurer at any point during the 12 month lookback  */
WITH medicaid_primary_patients AS (
    SELECT DISTINCT
        h.patient_id
    FROM work_rohanramirez_a299.hospice_f_candidates h
    INNER JOIN komodo_202606.patient_insurance i
        ON h.patient_id = i.patient_id
       AND i.row_valid_end >= DATEADD(year, -1, h.event_date)
       AND i.row_valid_start < h.event_date
    WHERE UPPER(TRIM(i.mx_insurance_group)) = 'MEDICAID'
)
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET medicaid_primary = TRUE
FROM medicaid_primary_patients m
WHERE hospice_f_candidates.patient_id = m.patient_id;
/* checking it */
SELECT
    medicaid_primary,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates
GROUP BY medicaid_primary
ORDER BY medicaid_primary;
/* now ading in identifcation of HIV */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN hiv_status BOOLEAN;
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN hiv_most_recent_date DATE;
/* bruh it again deleted my fucking code DIAGNOSIS ROUTES */
DROP TABLE IF EXISTS hospice_hiv_dx_summary;
CREATE TABLE hospice_hiv_dx_summary
DISTKEY(patient_id)
SORTKEY(patient_id) AS
SELECT
    h.patient_id,
    /* Route 1: >=1 inpatient HIV diagnosis */
    MAX(
        CASE
            WHEN dx.source_table = 'INPATIENT_EVENTS'
            THEN 1 ELSE 0
        END
    ) AS inpatient_pass,

    /* Route 2: >=2 distinct outpatient HIV diagnosis dates */
    COUNT(
        DISTINCT CASE
            WHEN dx.source_table = 'NON_INPATIENT_EVENTS'
            THEN dx.event_date::DATE
        END
    ) AS outpatient_hiv_dates,
    MAX(
        CASE
            WHEN dx.source_table = 'INPATIENT_EVENTS'
            THEN dx.event_date::DATE
        END
    ) AS latest_inpatient_date,
    MAX(
        CASE
            WHEN dx.source_table = 'NON_INPATIENT_EVENTS'
            THEN dx.event_date::DATE
        END
    ) AS latest_outpatient_date
FROM work_rohanramirez_a299.hospice_f_candidates h
INNER JOIN komodo_202606.normalized_dx_events dx
    ON h.patient_id = dx.patient_id
   AND dx.event_date <= h.event_date
WHERE dx.source_table IN (
    'INPATIENT_EVENTS',
    'NON_INPATIENT_EVENTS'
)
AND dx.dx_code IN (
    'Z21',
    'B200','B201','B202','B203','B204',
    'B205','B206','B207','B208','B209',
    'B210','B211','B212','B213',
    'B217','B218','B219',
    'B220','B221','B222','B227',
    'B230','B231','B232','B238',
    'B24'
)
GROUP BY h.patient_id;
/* quality checking it */
SELECT
    SUM(CASE WHEN inpatient_pass = 1 THEN 1 ELSE 0 END)
        AS inpatient_pass,
    SUM(CASE WHEN outpatient_hiv_dates >= 2 THEN 1 ELSE 0 END)
        AS outpatient_pass,
    SUM(
        CASE
            WHEN inpatient_pass = 1
              OR outpatient_hiv_dates >= 2
            THEN 1 ELSE 0
        END
    ) AS diagnosis_positive
FROM hospice_hiv_dx_summary;
/* diagnosis adding in earliest hiv date */
/* check my existing HIV and diagnosis tables ngl i ran this after i did random narrowing stuff down  so do not run this lil chunk
 * this is for a future idea where we can bridge atc medication to include hep b and prep medication if patient is already hiv positive from diagnosis */
SELECT
    COUNT(*) AS diagnosis_positive
FROM work_rohanramirez_a299.hospice_hiv_dx_summary s
INNER JOIN work_rohanramirez_a299.hospice_f_candidates h
    ON s.patient_id = h.patient_id
WHERE s.inpatient_pass = 1
   OR s.outpatient_hiv_dates >= 2;
/* yes now we go to route 3 */
DROP TABLE IF EXISTS work_rohanramirez_a299.hiv_drug_lookup;
/* I HAVE TO MAKE AN ALIAS TABLE */
DROP TABLE IF EXISTS work_rohanramirez_a299.hiv_drug_alias;
CREATE TABLE work_rohanramirez_a299.hiv_drug_alias (
    alias_name VARCHAR(255),
    DrugName VARCHAR(255),
    name_source VARCHAR(20),
    review_note VARCHAR(255)
)
DISTSTYLE ALL
SORTKEY(alias_name);
/* ADDING IN OBVIOUS MISSED MAPPINGS */
INSERT INTO work_rohanramirez_a299.hiv_drug_alias
    (alias_name, DrugName, name_source, review_note)
VALUES
/* ABACAVIR-LAMIVUDINE */
(
    'ABACAVIR/LAMIVUDINE',
    'ABACAVIR-LAMIVUDINE',
    'brand_name',
    'False negative caused by slash formatting'
),
(
    'ABACAVIR SULFATE/LAMIVUDINE',
    'ABACAVIR-LAMIVUDINE',
    'generic_name',
    'False negative caused by salt name'
),
/* ABACAVIR-LAMIVUDINE-ZIDOVUDINE */
(
    'ABACAVIR/LAMIVUDINE/ZIDOVUDINE',
    'ABACAVIR-LAMIVUDINE-ZIDOVUDINE',
    'brand_name',
    'False negative caused by slash formatting'
),
(
    'ABACAVIR SULFATE/LAMIVUDINE/ZIDOVUDINE',
    'ABACAVIR-LAMIVUDINE-ZIDOVUDINE',
    'generic_name',
    'False negative caused by salt name'
),
/* DARUNAVIR */
(
    'DARUNAVIR PROPYLENE GLYCOLATE',
    'DARUNAVIR',
    'brand_name',
    'False negative caused by formulation wording'
),
/* LAMIVUDINE-ZIDOVUDINE */
(
    'LAMIVUDINE/ZIDOVUDINE',
    'LAMIVUDINE-ZIDOVUDINE',
    'brand_name',
    'False negative caused by slash formatting'
),
/* LOPINAVIR-RITONAVIR */
(
    'LOPINAVIR/RITONAVIR',
    'LOPINAVIR-RITONAVIR',
    'brand_name',
    'False negative caused by slash formatting'
),
/* IDVYNSO - mentor approved addition */
(
    'IDVYNSO',
    'IDVYNSO',
    'brand_name',
    'Mentor-approved HIV cohort-identification medication'
),
(
    'DORAVIRINE/ISLATRAVIR',
    'IDVYNSO',
    'generic_name',
    'Generic representation of mentor-approved IDVYNSO'
);
/* CHECK ON CCANNONICAL DRUGNAME STRING */
SELECT drug_name
FROM work_rohanramirez_a299.hiv_drug_lookup
WHERE
       drug_name ILIKE '%EFAVIRENZ%'
    OR drug_name ILIKE '%RILPIVIRINE%'
ORDER BY drug_name;
/* SEE IF SPACE IS IN THERE ISSUE */
SELECT
    '[' || drug_name || ']' AS drug_name_check,
    LENGTH(drug_name) AS n_chars
FROM work_rohanramirez_a299.hiv_drug_lookup
WHERE drug_name ILIKE 'EMTRICITABINE-RILPIVIRINE%';
/* NOW ADDING IN MAPPINGS */
INSERT INTO work_rohanramirez_a299.hiv_drug_alias
    (alias_name, DrugName, name_source, review_note)
VALUES
/* EFAVIRENZ + EMTRICITABINE + TDF */
(
    'EFAVIRENZ-EMTRIC-TENOFOV DISOP',
    'EFAVIRENZ-EMTRICITABINE-TENOFOVIR DISOPROXIL FUMARATE',
    'brand_name',
    'False negative: Komodo abbreviated brand representation'
),
(
    'EFAVIRENZ/EMTRICITABINE/TENOFOVIR',
    'EFAVIRENZ-EMTRICITABINE-TENOFOVIR DISOPROXIL FUMARATE',
    'brand_name',
    'False negative: Komodo slash formatting'
),
(
    'EFAVIRENZ/EMTRICITABINE/TENOFOVIR DISOPROXIL FUMARATE',
    'EFAVIRENZ-EMTRICITABINE-TENOFOVIR DISOPROXIL FUMARATE',
    'generic_name',
    'False negative: Komodo slash formatting'
),
/* EFAVIRENZ + LAMIVUDINE + TDF */
(
    'EFAVIRENZ-LAMIVU-TENOFOV DISOP',
    'EFAVIRENZ-LAMIVUDINE-TENOFOVIR DISOPROXIL FUMARATE',
    'brand_name',
    'False negative: Komodo abbreviated brand representation'
),
(
    'EFAVIRENZ/LAMIVUDINE/TENOFOVIR',
    'EFAVIRENZ-LAMIVUDINE-TENOFOVIR DISOPROXIL FUMARATE',
    'brand_name',
    'False negative: Komodo slash formatting'
),
(
    'EFAVIRENZ/LAMIVUDINE/TENOFOVIR DISOPROXIL FUMARATE',
    'EFAVIRENZ-LAMIVUDINE-TENOFOVIR DISOPROXIL FUMARATE',
    'generic_name',
    'False negative: Komodo slash formatting'
),
/* EMTRICITABINE + RILPIVIRINE + TDF */
(
    'EMTRICITABINE-RILPIVIRINE-TENOF',
    'EMTRICITABINE-RILPIVIRINE- TENOFOVIR DISOPROXIL FUMARATE',
    'brand_name',
    'False negative: Komodo abbreviated brand representation'
),
(
    'EMTRICITABINE/RILPIVIRINE HCL/TENOFOVIR DISOPROXIL FUMARATE',
    'EMTRICITABINE-RILPIVIRINE- TENOFOVIR DISOPROXIL FUMARATE',
    'generic_name',
    'False negative: slash formatting and rilpivirine HCL'
),
(
    'EMTRICITABINE/RILPIVIRINE/TENOFOVIR',
    'EMTRICITABINE-RILPIVIRINE- TENOFOVIR DISOPROXIL FUMARATE',
    'brand_name',
    'False negative: Komodo slash formatting'
);
/* so with route 3 being so expensive i capped the lookback period to 6 years. i did not want to exclude the earlier patients if we do get a lot of data from them.
 * date caped at earliest observation pharmacy date 2016-01-01 */ 
DROP TABLE IF EXISTS work_rohanramirez_a299.hiv_route3_match_names;
CREATE TABLE work_rohanramirez_a299.hiv_route3_match_names
DISTSTYLE ALL
SORTKEY(match_name) AS
SELECT DISTINCT UPPER(TRIM(match_name)) AS match_name
FROM (
    SELECT drug_name AS match_name
    FROM work_rohanramirez_a299.hiv_drug_lookup
    WHERE identify_hiv = TRUE

    UNION ALL

    SELECT a.alias_name AS match_name
    FROM work_rohanramirez_a299.hiv_drug_alias a
    INNER JOIN work_rohanramirez_a299.hiv_drug_lookup d
        ON UPPER(TRIM(a.DrugName)) = UPPER(TRIM(d.drug_name))
    WHERE d.identify_hiv = TRUE
) x
WHERE match_name IS NOT NULL
  AND TRIM(match_name) <> '';
/* quality check */
SELECT COUNT(*) AS approved_route3_names
FROM work_rohanramirez_a299.hiv_route3_match_names;
/* EXPENSIVE PHARMACY SCAN */
/* DELETE OLD ROUTE 3 RESULTS BECAUSE MATCHING LOGIC CHANGED */
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_hiv_rx_summary;
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_hiv_rx_fills;
/* clear old route 3 audit results but keep pharmacy observability */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET hiv_rx_fill_dates = NULL,
    hiv_rx_evidence_status = NULL;
/*ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
DROP COLUMN hiv_rx_observable_years;*/
/* DESTINATION TABLE EMPTY FIRST THEN I WILL INSERT BY HOSPICE YEAR */
CREATE TABLE work_rohanramirez_a299.hospice_hiv_rx_fills (
    patient_id VARCHAR(255),
    fill_date DATE
)
DISTKEY(patient_id)
SORTKEY(patient_id,fill_date);
/* now FOR YEARLY INSERT */
/* change the two hospice-year boundaries for each year 2016 through 2026 */
/* each hospice year should be inserted once after recreating the empty table */
INSERT INTO work_rohanramirez_a299.hospice_hiv_rx_fills
WITH h AS (
    SELECT patient_id,event_date
    FROM work_rohanramirez_a299.hospice_f_candidates
    WHERE event_date >= DATE '2016-01-01'
      AND event_date < DATE '2017-01-01'
),
/* EXCLUDE PRODUCTS THAT CANNOT ESTABLISH HIV FIRST */
/* this prevents an excluded brand from sneaking back in through generic_name */
eligible_pharmacy AS (
    SELECT
        h.patient_id,
        p.fill_date::DATE AS fill_date,
        p.brand_name,
        p.generic_name
    FROM h
    INNER JOIN komodo_202610.pharmacy_events p
        ON h.patient_id = p.patient_id
       AND p.fill_date >= GREATEST(
            DATEADD(year,-6,h.event_date),
            DATE '2016-01-01'
       )
       AND p.fill_date <= h.event_date
    /* only valid paid pharmacy claims count toward HIV identification */
    /* days_supply is not required for Route 3 */
    WHERE UPPER(TRIM(p.transaction_result)) = 'PAID'
      AND UPPER(TRIM(p.transaction_status)) IN ('FINAL', 'STANDALONE')
      AND p.fill_date IS NOT NULL
      AND UPPER(TRIM(COALESCE(p.brand_name,''))) NOT IN (
        'APRETUDE',
        'YEZTUGO',
        'DESCOVY',
        'TRUVADA',
        'VEMLIDY',
        'VIREAD',
        'EPIVIR HBV',
        'NORVIR',
        'VOCABRIA',
        'EMTRICITABINE-TENOFOVIR DISOP',
        'EMTRICITABINE/TENOFOVIR'
    )
),

/* CHECK BRAND AND GENERIC NAMES SEPARATELY */
/* no OR join and no fuzzy matching */
pharmacy_names AS (
    SELECT
        patient_id,
        fill_date,
        brand_name AS pharmacy_name
    FROM eligible_pharmacy
    WHERE brand_name IS NOT NULL
    UNION ALL
    SELECT
        patient_id,
        fill_date,
        generic_name AS pharmacy_name
    FROM eligible_pharmacy
    WHERE generic_name IS NOT NULL
)
SELECT DISTINCT
    n.patient_id,
    n.fill_date
FROM pharmacy_names n
INNER JOIN work_rohanramirez_a299.hiv_route3_match_names l
    ON UPPER(TRIM(n.pharmacy_name)) = l.match_name;
/*
2016 
2017 C
2018 C
2019 C
2020 C
2021 C
2022 C
2023 C
2024 C
2025 C
2026 C
*/
 /* check completed hospice years for Route 3 */
SELECT
    EXTRACT(YEAR FROM h.event_date)::INT AS hospice_year,
    COUNT(DISTINCT f.patient_id) AS patients_with_hiv_rx_fills,
    COUNT(*) AS fill_rows,
    COUNT(DISTINCT f.fill_date) AS distinct_fill_dates
FROM work_rohanramirez_a299.hospice_hiv_rx_fills f
INNER JOIN work_rohanramirez_a299.hospice_f_candidates h
    ON f.patient_id = h.patient_id
GROUP BY 1
ORDER BY hospice_year;
/* now permanent route 3 summary */
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_hiv_rx_summary;
CREATE TABLE work_rohanramirez_a299.hospice_hiv_rx_summary
DISTKEY(patient_id)
SORTKEY(patient_id) AS
SELECT
    patient_id,
    COUNT(DISTINCT fill_date) AS hiv_rx_fill_dates,
    CASE
        WHEN COUNT(DISTINCT fill_date) >= 2 THEN 1
        ELSE 0
    END AS pharmacy_pass,
    MAX(fill_date) AS latest_pharmacy_date
FROM work_rohanramirez_a299.hospice_hiv_rx_fills
GROUP BY patient_id;
/* quality check got pharmacy positive 1, 915 and any was 2020*/
SELECT
    COUNT(DISTINCT CASE
        WHEN pharmacy_pass = 1 THEN patient_id
    END) AS pharmacy_positive,
    COUNT(DISTINCT patient_id) AS patients_with_any_qualifying_hiv_medication
FROM work_rohanramirez_a299.hospice_hiv_rx_summary;
/* verifying */
/* compare pharmacy-only HIV identification with overlapping diagnosis evidence */
SELECT
    COUNT(DISTINCT CASE
        WHEN r.pharmacy_pass = 1
        THEN r.patient_id
    END) AS pharmacy_positive,
    COUNT(DISTINCT CASE
        WHEN r.pharmacy_pass = 1
         AND COALESCE(d.inpatient_pass, 0) = 0
         AND COALESCE(d.outpatient_hiv_dates, 0) < 2
        THEN r.patient_id
    END) AS pharmacy_only,
    COUNT(DISTINCT CASE
        WHEN r.pharmacy_pass = 1
         AND (
             d.inpatient_pass = 1
             OR d.outpatient_hiv_dates >= 2
         )
        THEN r.patient_id
    END) AS pharmacy_and_diagnosis
FROM work_rohanramirez_a299.hospice_hiv_rx_summary r
LEFT JOIN work_rohanramirez_a299.hospice_hiv_dx_summary d
    ON r.patient_id = d.patient_id;
/* WRITE ROUTE 3 RESULTS INTO HOSPICE F CANDIDATES */
/* everyone starts as having no qualifying HIV medication */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET hiv_rx_fill_dates = 0,
    hiv_rx_evidence_status = 'NO_QUALIFYING_HIV_RX';
/* overwrite patients who actually had qualifying medication evidence */
UPDATE work_rohanramirez_a299.hospice_f_candidates h
SET hiv_rx_fill_dates = r.hiv_rx_fill_dates,
    hiv_rx_evidence_status = CASE
        WHEN r.pharmacy_pass = 1 THEN 'ROUTE3_POSITIVE'
        ELSE 'ONE_QUALIFYING_FILL_DATE'
    END
FROM work_rohanramirez_a299.hospice_hiv_rx_summary r
WHERE h.patient_id = r.patient_id;
/* COMBINE ALL 3 HIV IDENTIFICATION ROUTES */
/* COMBINE ALL 3 HIV IDENTIFICATION ROUTES */
/* reset old HIV results first; some patients may no longer pass Route 3 */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET hiv_status = FALSE,
    hiv_most_recent_date = NULL;

UPDATE work_rohanramirez_a299.hospice_f_candidates h
SET hiv_status = TRUE,
    hiv_most_recent_date = x.hiv_most_recent_date
FROM (
    SELECT
        patient_id,
        MAX(evidence_date) AS hiv_most_recent_date
    FROM (
        /* ROUTE 1: at least one inpatient HIV diagnosis */
        SELECT
            patient_id,
            latest_inpatient_date AS evidence_date
        FROM work_rohanramirez_a299.hospice_hiv_dx_summary
        WHERE inpatient_pass = 1
        UNION ALL
        /* ROUTE 2: at least two outpatient HIV diagnosis dates */
        SELECT
            patient_id,
            latest_outpatient_date AS evidence_date
        FROM work_rohanramirez_a299.hospice_hiv_dx_summary
        WHERE outpatient_hiv_dates >= 2
        UNION ALL
        /* ROUTE 3: at least two qualifying HIV medication fill dates */
        SELECT
            patient_id,
            latest_pharmacy_date AS evidence_date
        FROM work_rohanramirez_a299.hospice_hiv_rx_summary
        WHERE pharmacy_pass = 1
    ) evidence
    WHERE evidence_date IS NOT NULL
    GROUP BY patient_id
) x
WHERE h.patient_id = x.patient_id;
/* final HIV status quality check */
SELECT
    hiv_status,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates
GROUP BY hiv_status
ORDER BY hiv_status;
/* look at pharmacy positive or diagnosis positive */
/* HIV POSITIVE DISTRIBUTION BY IDENTIFICATION ROUTE */
SELECT
    COUNT(DISTINCT CASE
        WHEN r.pharmacy_pass = 1
        THEN h.patient_id
    END) AS pharmacy_positive,
    COUNT(DISTINCT CASE
        WHEN d.inpatient_pass = 1
          OR d.outpatient_hiv_dates >= 2
        THEN h.patient_id
    END) AS diagnosis_positive,
    COUNT(DISTINCT CASE
        WHEN d.inpatient_pass = 1
        THEN h.patient_id
    END) AS inpatient_positive,
    COUNT(DISTINCT CASE
        WHEN d.outpatient_hiv_dates >= 2
        THEN h.patient_id
    END) AS outpatient_positive,
    COUNT(DISTINCT CASE
        WHEN r.pharmacy_pass = 1
         AND (
             d.inpatient_pass = 1
             OR d.outpatient_hiv_dates >= 2
         )
        THEN h.patient_id
    END) AS pharmacy_and_diagnosis,
    COUNT(DISTINCT CASE
        WHEN r.pharmacy_pass = 1
         AND COALESCE(d.inpatient_pass,0) = 0
         AND COALESCE(d.outpatient_hiv_dates,0) < 2
        THEN h.patient_id
    END) AS pharmacy_only,
    COUNT(DISTINCT CASE
        WHEN (
             d.inpatient_pass = 1
             OR d.outpatient_hiv_dates >= 2
        )
         AND COALESCE(r.pharmacy_pass,0) = 0
        THEN h.patient_id
    END) AS diagnosis_only,
    COUNT(DISTINCT CASE
        WHEN h.hiv_status = TRUE
        THEN h.patient_id
    END) AS total_hiv_positive
FROM work_rohanramirez_a299.hospice_f_candidates h
LEFT JOIN work_rohanramirez_a299.hospice_hiv_dx_summary d
    ON h.patient_id = d.patient_id
LEFT JOIN work_rohanramirez_a299.hospice_hiv_rx_summary r
    ON h.patient_id = r.patient_id;
/* FINAL UPDATE OF MOST RECENT KNOWN HIV DATE */
/* take the latest qualifying evidence date across routes 1, 2, and 3 */
UPDATE work_rohanramirez_a299.hospice_f_candidates h
SET hiv_most_recent_date = x.hiv_most_recent_date
FROM (
    SELECT
        patient_id,
        MAX(evidence_date) AS hiv_most_recent_date
    FROM (
        /* ROUTE 1: inpatient HIV diagnosis */
        SELECT
            patient_id,
            latest_inpatient_date AS evidence_date
        FROM work_rohanramirez_a299.hospice_hiv_dx_summary
        WHERE inpatient_pass = 1
        UNION ALL
        /* ROUTE 2: at least two outpatient HIV diagnosis dates */
        SELECT
            patient_id,
            latest_outpatient_date AS evidence_date
        FROM work_rohanramirez_a299.hospice_hiv_dx_summary
        WHERE outpatient_hiv_dates >= 2
        UNION ALL
        /* ROUTE 3: at least two qualifying HIV medication fill dates */
        SELECT
            patient_id,
            latest_pharmacy_date AS evidence_date
        FROM work_rohanramirez_a299.hospice_hiv_rx_summary
        WHERE pharmacy_pass = 1
    ) evidence
    WHERE evidence_date IS NOT NULL
    GROUP BY patient_id
) x
WHERE h.patient_id = x.patient_id
  AND h.hiv_status = TRUE;
 /* QUALITY CHECK IT */
/* every HIV-positive patient should now have a most recent HIV date */
/* range of most recent HIV evidence date among HIV-positive patients */
SELECT
    MIN(hiv_most_recent_date) AS earliest_most_recent_hiv_date,
    MAX(hiv_most_recent_date) AS latest_most_recent_hiv_date
FROM work_rohanramirez_a299.hospice_f_candidates
WHERE hiv_status = TRUE;
/* we got 283 pharmacy positive individuals now we gotta investigate what meds made those positive */
/* PHARMACY-ONLY HIV POSITIVE PATIENTS AND THEIR QUALIFYING MEDICATIONS */
/* PHARMACY ONLY HIV POSITIVE MEDICATION REVIEW */
DROP TABLE IF EXISTS work_rohanramirez_a299.pharmacyonlyHIVpos;
CREATE TABLE work_rohanramirez_a299.pharmacyonlyHIVpos
DISTKEY(patient_id)
SORTKEY(patient_id,fill_date) AS
SELECT DISTINCT
    r.patient_id,
    f.fill_date,
    p.brand_name,
    p.generic_name
FROM work_rohanramirez_a299.hospice_hiv_rx_summary r
LEFT JOIN work_rohanramirez_a299.hospice_hiv_dx_summary d
    ON r.patient_id = d.patient_id
INNER JOIN work_rohanramirez_a299.hospice_hiv_rx_fills f
    ON r.patient_id = f.patient_id
INNER JOIN komodo_202610.pharmacy_events p
    ON f.patient_id = p.patient_id
   AND f.fill_date = p.fill_date::DATE
WHERE r.pharmacy_pass = 1
  /* use the same valid-claim and excluded-brand rules as Route 3 */
  AND UPPER(TRIM(p.transaction_result)) = 'PAID'
  AND UPPER(TRIM(p.transaction_status)) IN ('FINAL', 'STANDALONE')
  AND UPPER(TRIM(COALESCE(p.brand_name,''))) NOT IN (
      'APRETUDE', 'YEZTUGO', 'DESCOVY', 'TRUVADA',
      'VEMLIDY', 'VIREAD', 'EPIVIR HBV', 'NORVIR',
      'VOCABRIA', 'EMTRICITABINE-TENOFOVIR DISOP',
      'EMTRICITABINE/TENOFOVIR'
  )
  AND COALESCE(d.inpatient_pass,0) = 0
  AND COALESCE(d.outpatient_hiv_dates,0) < 2
  /* only pull the medication that actually matched route 3 */
  AND (
      EXISTS (
          SELECT 1
          FROM work_rohanramirez_a299.hiv_route3_match_names m
          WHERE m.match_name = UPPER(TRIM(p.brand_name))
      )
      OR EXISTS (
          SELECT 1
          FROM work_rohanramirez_a299.hiv_route3_match_names m
          WHERE m.match_name = UPPER(TRIM(p.generic_name))
      )
  );
  /* NOW CHECKING THE check */
SELECT *
FROM work_rohanramirez_a299.pharmacyonlyHIVpos
ORDER BY patient_id,fill_date;
/* now seeing the unique combos */
SELECT DISTINCT
    brand_name,