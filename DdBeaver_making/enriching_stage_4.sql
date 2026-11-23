/* HERE A LOT OF THINGS DONE. I REDUCED DOWN POPULATION BEFORE ENRICHMENT OF GAGNE, CFI, CFI LEVEL, CCW
 * INSRUANCE HERE IS ENRICED WE SEE PRIMARY CATEGORICAL AND SECOND INSURANE COLUM IS TRUE IF THEY ARE DUAL ELIGIBLE 
 * 
 * */
/* CHECK SEX VALUES we see F M U */
SELECT DISTINCT patient_gender
FROM komodo_202606.patient_demographics
ORDER BY patient_gender;
/* CHECK RACE/ETHNICITY VALUES */
SELECT DISTINCT patient_race_ethnicity
FROM komodo_202606.patient_race_ethnicity
ORDER BY patient_race_ethnicity;
/* check insruance values */
SELECT DISTINCT mx_insurance_group
FROM komodo_202606.patient_insurance
ORDER BY mx_insurance_group;
/* ADD DEMOGRAPHIC VARIABLES */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN sex VARCHAR(10);
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN race_ethnicity VARCHAR(50);
/* SEX */
UPDATE work_rohanramirez_a299.hospice_f_candidates h
SET sex =
    CASE
        WHEN d.patient_gender = 'F' THEN 'FEMALE'
        WHEN d.patient_gender = 'M' THEN 'MALE'
        WHEN d.patient_gender = 'U' THEN 'UNKNOWN'
    END
FROM komodo_202606.patient_demographics d
WHERE h.patient_id = d.patient_id;
/* RACE / ETHNICITY */
UPDATE work_rohanramirez_a299.hospice_f_candidates h
SET race_ethnicity = r.patient_race_ethnicity
FROM komodo_202606.patient_race_ethnicity r
WHERE h.patient_id = r.patient_id;
/* huh i got NULL 16,053 */
SELECT
    race_ethnicity,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates
GROUP BY race_ethnicity
ORDER BY patients DESC;
/* ADD FINAL INSURANCE VARIABLES */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN primary_insurance VARCHAR(20);
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN dual_eligible BOOLEAN;
/* POPULATE PRIMARY INSURANCE + DUAL ELIGIBILITY */
WITH insurance_summary AS (
    SELECT
        h.patient_id,
        /* Primary insurance should be constant because payer switchers
           were already excluded from the cohort */
        MAX(UPPER(TRIM(i.mx_insurance_group))) AS primary_insurance,
        /* Medicare + Medicaid in either primary/secondary direction */
        CASE
            WHEN MAX(
                CASE
                    WHEN (
                        UPPER(TRIM(i.mx_insurance_group)) = 'MEDICARE'
                        AND UPPER(TRIM(i.mx_secondary_insurance_group)) = 'MEDICAID'
                    )
                    OR (
                        UPPER(TRIM(i.mx_insurance_group)) = 'MEDICAID'
                        AND UPPER(TRIM(i.mx_secondary_insurance_group)) = 'MEDICARE'
                    )
                    THEN 1
                    ELSE 0
                END
            ) = 1
            THEN TRUE
            ELSE FALSE
        END AS dual_eligible
    FROM work_rohanramirez_a299.hospice_f_candidates h
    INNER JOIN komodo_202606.patient_insurance i
        ON h.patient_id = i.patient_id
       AND i.row_valid_end >= DATEADD(year,-1,h.event_date)
       AND i.row_valid_start < h.event_date
    GROUP BY h.patient_id
)
UPDATE work_rohanramirez_a299.hospice_f_candidates 
SET
    primary_insurance = s.primary_insurance,
    dual_eligible = s.dual_eligible
FROM insurance_summary s
WHERE hospice_f_candidates.patient_id = s.patient_id;
/*checking it*/
SELECT
    UPPER(TRIM(i.mx_insurance_group)) AS primary_insurance,
    UPPER(TRIM(i.mx_secondary_insurance_group)) AS secondary_insurance,
    COUNT(DISTINCT h.patient_id) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates h
INNER JOIN komodo_202606.patient_insurance i
    ON h.patient_id = i.patient_id
   AND i.row_valid_end >= DATEADD(year,-1,h.event_date)
   AND i.row_valid_start < h.event_date
WHERE
    (
        UPPER(TRIM(i.mx_insurance_group)) = 'MEDICARE'
        AND UPPER(TRIM(i.mx_secondary_insurance_group)) = 'MEDICAID'
    )
    OR
    (
        UPPER(TRIM(i.mx_insurance_group)) = 'MEDICAID'
        AND UPPER(TRIM(i.mx_secondary_insurance_group)) = 'MEDICARE'
    )
GROUP BY
    UPPER(TRIM(i.mx_insurance_group)),
    UPPER(TRIM(i.mx_secondary_insurance_group))
ORDER BY patients DESC;
/* ONE INSURANCE CLASSIFICATION PER PATIENT */
SELECT
    primary_insurance,
    dual_eligible,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates
GROUP BY
    primary_insurance,
    dual_eligible
ORDER BY
    primary_insurance,
    dual_eligible;
/* CHECK CLAIM DATE COVERAGE */
SELECT
    MIN(event_date) AS min_dx_date,
    MAX(event_date) AS max_dx_date
FROM komodo_202606.normalized_dx_events;
SELECT
    MIN(event_date) AS min_px_date,
    MAX(event_date) AS max_px_date
FROM komodo_202606.normalized_procedure_events;
/* PATIENTS WITHOUT A FULL 12-MONTH NORMALIZED CLAIMS LOOKBACK */
SELECT
    COUNT(*) AS incomplete_lookback_patients
FROM work_rohanramirez_a299.hospice_f_candidates
WHERE event_date < DATE '2016-03-31';
SELECT
    hiv_status,
    COUNT(*) AS incomplete_lookback_patients
FROM work_rohanramirez_a299.hospice_f_candidates
WHERE event_date < DATE '2016-03-31'
GROUP BY hiv_status
ORDER BY hiv_status;
/* REMOVE INCOMPLETE CLAIMS LOOKBACK */
DELETE FROM work_rohanramirez_a299.hospice_f_candidates
WHERE event_date < DATE '2016-03-31';
/*    
 * missing race, gender, demographics
 * 
 */
/* SEX MISSING / UNKNOWN */
SELECT
    SUM(CASE WHEN sex IS NULL THEN 1 ELSE 0 END) AS missing_sex,
    SUM(CASE WHEN UPPER(TRIM(sex)) = 'UNKNOWN' THEN 1 ELSE 0 END) AS unknown_sex,
    SUM(CASE
            WHEN sex IS NULL
              OR UPPER(TRIM(sex)) = 'UNKNOWN'
            THEN 1 ELSE 0
        END) AS total_sex_to_drop
FROM work_rohanramirez_a299.hospice_f_candidates;
SELECT
    SUM(CASE WHEN race_ethnicity IS NULL THEN 1 ELSE 0 END) AS missing_race,
    SUM(CASE WHEN UPPER(TRIM(race_ethnicity)) = 'UNKNOWN' THEN 1 ELSE 0 END) AS unknown_race,
    SUM(CASE
            WHEN race_ethnicity IS NULL
              OR UPPER(TRIM(race_ethnicity)) = 'UNKNOWN'
            THEN 1 ELSE 0
        END) AS total_race_to_drop
FROM work_rohanramirez_a299.hospice_f_candidates;
 /* UNIQUE PATIENTS WITH MISSING/UNKNOWN SEX OR RACE */
SELECT
    COUNT(*) AS demographic_exclusions
FROM work_rohanramirez_a299.hospice_f_candidates
WHERE sex IS NULL
   OR UPPER(TRIM(sex)) = 'UNKNOWN'
   OR race_ethnicity IS NULL
   OR UPPER(TRIM(race_ethnicity)) = 'UNKNOWN';
   
  /* HIV STATUS AMONG DEMOGRAPHIC EXCLUSIONS */
SELECT
    hiv_status,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates
WHERE sex IS NULL
   OR UPPER(TRIM(sex)) = 'UNKNOWN'
   OR race_ethnicity IS NULL
   OR UPPER(TRIM(race_ethnicity)) = 'UNKNOWN'
GROUP BY hiv_status
ORDER BY hiv_status;
/* REMOVE MISSING / UNKNOWN REQUIRED DEMOGRAPHICS */
DELETE FROM work_rohanramirez_a299.hospice_f_candidates
WHERE sex IS NULL
   OR UPPER(TRIM(sex)) = 'UNKNOWN'
   OR race_ethnicity IS NULL
   OR UPPER(TRIM(race_ethnicity)) = 'UNKNOWN';
/* now narrowing based on state zip code */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN patient_state VARCHAR(10);
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN patient_zip VARCHAR(20);
/* GEOGRAPHY AT HOSPICE ADMISSION */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET
    patient_state = g.patient_state,
    patient_zip = g.patient_zip
FROM komodo_202606.patient_geography g
WHERE hospice_f_candidates.patient_id = g.patient_id
  AND hospice_f_candidates.event_date >= g.valid_from_date
  AND hospice_f_candidates.event_date <= g.valid_to_date;
  /* checking deleting the people mssing it 7  */
 SELECT
    SUM(CASE WHEN patient_state IS NULL THEN 1 ELSE 0 END) AS missing_state,
    SUM(CASE WHEN patient_zip IS NULL THEN 1 ELSE 0 END) AS missing_zip
FROM work_rohanramirez_a299.hospice_f_candidates;
DELETE FROM work_rohanramirez_a299.hospice_f_candidates
WHERE patient_state IS NULL
   OR patient_zip IS NULL;
/* now getting back into focus */
/* this is a table to store clinicalfeatures found across the yearly claims scans so we do no not have to rescan the massive procedure tables*/
DROP TABLE IF EXISTS work_rohanramirez_a299.cfi_gagne_feature_matches;
CREATE TABLE work_rohanramirez_a299.cfi_gagne_feature_matches (
    patient_id VARCHAR(255),
    hospice_year INTEGER,
    metric VARCHAR(16),
    feature_id VARCHAR(128),
    feature_name VARCHAR(256),
    match_type VARCHAR(16),
    lookup_version VARCHAR(128)
)
DISTKEY(patient_id)
SORTKEY(hospice_year, patient_id, metric, feature_id);
/* 2016 EXACT CFI/GAGNE DIAGNOSIS FEATURES */
INSERT INTO work_rohanramirez_a299.cfi_gagne_feature_matches
SELECT DISTINCT
    h.patient_id,
    EXTRACT(YEAR FROM h.event_date)::INTEGER AS hospice_year,
    l.metric,
    l.feature_id,
    l.feature_name,
    l.match_type,
    l.lookup_version
FROM work_rohanramirez_a299.hospice_f_candidates h
JOIN komodo_202606.normalized_dx_events d
    ON h.patient_id = d.patient_id
   AND d.event_date >= DATEADD(year,-1,h.event_date)
   AND d.event_date < h.event_date

JOIN work_rohanramirez_a299.cfi_gagne_dx_lookup l
    ON d.dx_code = l.match_value
   AND l.match_type = 'exact'
WHERE h.event_date >= DATE '2020-01-01'
  AND h.event_date < DATE '2021-01-01';
/* CHECK ALL CFI/GAGNE EVIDENCE */
SELECT
    hospice_year,
    metric,
    match_type,
    COUNT(*) AS feature_matches,
    COUNT(DISTINCT patient_id) AS patients
FROM work_rohanramirez_a299.cfi_gagne_feature_matches
GROUP BY hospice_year, metric, match_type
ORDER BY hospice_year, metric, match_type;
/* adding 2 variables i need */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN cfi_score DOUBLE PRECISION;
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN frailty_level VARCHAR(40);
/* so there is an intercept of only .10288 with no matched featires */
/* INTERCEPT-ONLY CFI SCORE */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET cfi_score = 0.10288;
/* NOW WE update THE PATIENTS WHO ACTUALLY MACHED CFI FEATURES */
/* ADD CFI FEATURE WEIGHTS */
WITH weighted_features AS (
    SELECT DISTINCT
        m.patient_id,
        w.disease_number,
        w.weight
    FROM work_rohanramirez_a299.cfi_gagne_feature_matches m
    JOIN work_rohanramirez_a299.cfi_weight_lookup w
        ON m.feature_id = w.feature_id
    WHERE m.metric = 'CFI'
),
cfi_scores AS (
    SELECT
        patient_id,
        SUM(weight) AS cfi_weight_sum
    FROM weighted_features
    GROUP BY patient_id
)
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET cfi_score = 0.10288 + s.cfi_weight_sum
FROM cfi_scores s
WHERE hospice_f_candidates.patient_id = s.patient_id;
/* then I DERIVE THE PROTOCOL FRAILTY CATEGOEIS level */
/* FRAILTY LEVEL */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET frailty_level =
    CASE
        WHEN cfi_score < 0.25 THEN 'NONFRAIL'
        WHEN cfi_score < 0.35 THEN 'MILDLY FRAIL'
        ELSE 'MODERATELY-TO-SEVERELY FRAIL'
    END;
 /* QUALITY check */
SELECT
    frailty_level,
    COUNT(*) AS patients,
    MIN(cfi_score) AS min_cfi,
    MAX(cfi_score) AS max_cfi,
    AVG(cfi_score) AS mean_cfi
FROM work_rohanramirez_a299.hospice_f_candidates
GROUP BY frailty_level
ORDER BY MIN(cfi_score);
/* MAKE SURE NOBODY is MISSING A CFI SCORE */
SELECT
    COUNT(*) AS total,
    SUM(CASE WHEN cfi_score IS NULL THEN 1 ELSE 0 END) AS missing_cfi,
    SUM(CASE WHEN frailty_level IS NULL THEN 1 ELSE 0 END) AS missing_frailty
FROM work_rohanramirez_a299.hospice_f_candidates;
/* NOW I go BACK to DBEAVER and add GAGNE to THE COHORT */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN gagne_score DOUBLE PRECISION;

ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN gagne_group_count INTEGER;
/* Everyone starts at 0 because Nemo assigns zero when no Gagne condition is observed: */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET
    gagne_score = 0,
    gagne_group_count = 0;
/* then I SCORE THE PEOPLE with GAGNE FEATURES */
/* GAGNE SCORE */
WITH observed_groups AS (
    SELECT DISTINCT
        m.patient_id,
        g.gagne_group,
        g.weight
    FROM work_rohanramirez_a299.cfi_gagne_feature_matches m
    JOIN work_rohanramirez_a299.gagne_feature_group_lookup g
        ON m.feature_id = g.feature_id
    WHERE m.metric = 'GAGNE'
),
gagne_scores AS (
    SELECT
        patient_id,
        COUNT(DISTINCT gagne_group) AS gagne_group_count,
        SUM(weight) AS gagne_score
    FROM observed_groups
    GROUP BY patient_id
)
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET
    gagne_score = s.gagne_score,
    gagne_group_count = s.gagne_group_count
FROM gagne_scores s
WHERE hospice_f_candidates.patient_id = s.patient_id; 
/* then WE QUALITY check */
SELECT
    COUNT(*) AS patients,
    SUM(CASE WHEN gagne_score IS NULL THEN 1 ELSE 0 END) AS missing_gagne,
    MIN(gagne_score) AS min_gagne,
    MAX(gagne_score) AS max_gagne,
    AVG(gagne_score) AS mean_gagne
FROM work_rohanramirez_a299.hospice_f_candidates;
/* CHECKING THE NEGATIVE VALUE */
SELECT
    MIN(weight) AS min_weight,
    MAX(weight) AS max_weight
FROM work_rohanramirez_a299.gagne_feature_group_lookup;
/* NOW I create ONE CCW EVIDENCE table */
DROP TABLE IF EXISTS work_rohanramirez_a299.ccw30_evidence;
CREATE TABLE work_rohanramirez_a299.ccw30_evidence (
    patient_id VARCHAR(255),
    hospice_year INTEGER,
    event_date DATE,
    source_table VARCHAR(64),
    claim_setting VARCHAR(20),
    dx_code VARCHAR(64),
    condition_name VARCHAR(64),
    condition_name_long VARCHAR(256),
    ccw_condition_id VARCHAR(128),
    qualification_group INTEGER,
    lookup_version VARCHAR(128)
)
DISTKEY(patient_id)
SORTKEY(hospice_year, patient_id, event_date);
/* now do the same year by year scan i did before 
 * 
 2016 CCW EVIDENCE */
INSERT INTO work_rohanramirez_a299.ccw30_evidence
SELECT DISTINCT
    h.patient_id,
    EXTRACT(YEAR FROM h.event_date)::INTEGER AS hospice_year,
    d.event_date::DATE,
    d.source_table,
    CASE
        WHEN d.source_table = 'INPATIENT_EVENTS'
            THEN 'inpatient'
        WHEN d.source_table = 'NON_INPATIENT_EVENTS'
            THEN 'outpatient'
    END AS claim_setting,
    d.dx_code,
    l.condition_name,
    l.condition_name_long,
    l.ccw_condition_id,
    l.qualification_group,
    l.lookup_version
FROM work_rohanramirez_a299.hospice_f_candidates h
JOIN komodo_202606.normalized_dx_events d
    ON h.patient_id = d.patient_id
   AND d.event_date >= DATEADD(year,-1,h.event_date)
   AND d.event_date < h.event_date
JOIN work_rohanramirez_a299.ccw30_lookup l
    ON d.dx_code = l.dx_code
WHERE h.event_date >= DATE '2026-01-01'
  AND h.event_date < DATE '2027-01-01'
  AND d.source_table IN (
      'INPATIENT_EVENTS',
      'NON_INPATIENT_EVENTS'
  );
/* then i quality check each year this is now a group thing that shows all the years  */
SELECT
    hospice_year,
    claim_setting,
    COUNT(*) AS evidence_rows,
    COUNT(DISTINCT patient_id) AS patients
FROM work_rohanramirez_a299.ccw30_evidence
GROUP BY hospice_year, claim_setting
ORDER BY hospice_year, claim_setting;
/* now i add the final variable to my cohort */
ALTER TABLE work_rohanramirez_a299.hospice_f_candidates
ADD COLUMN ccw_condition_count INTEGER;
/* now male everyone start at 0 */
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET ccw_condition_count = 0;
/* now i apply nemos qualification rules and update the counts */ 
/* QUALIFY CCW CONDITIONS AND COUNT PER PATIENT */
WITH qualified_conditions AS (
    SELECT
        patient_id,
        ccw_condition_id
    FROM work_rohanramirez_a299.ccw30_evidence
    GROUP BY
        patient_id,
        ccw_condition_id,
        qualification_group
    HAVING
        /* GROUP 1: >=1 inpatient diagnosis */
        (
            qualification_group = 1
            AND MAX(
                CASE WHEN claim_setting = 'inpatient'
                     THEN 1 ELSE 0 END
            ) = 1
        )
        OR
        /* GROUPS 2-3:
           >=1 inpatient OR >=2 distinct outpatient dates */
        (
            qualification_group IN (2,3)
            AND (
                MAX(
                    CASE WHEN claim_setting = 'inpatient'
                         THEN 1 ELSE 0 END
                ) = 1
                OR
                COUNT(
                    DISTINCT CASE
                        WHEN claim_setting = 'outpatient'
                        THEN event_date
                    END
                ) >= 2
            )
        )
        OR
        /* GROUP 4: >=1 outpatient diagnosis */
        (
            qualification_group = 4
            AND MAX(
                CASE WHEN claim_setting = 'outpatient'
                     THEN 1 ELSE 0 END
            ) = 1
        )
        OR
        /* GROUPS 5-6: any qualifying diagnosis */
        (
            qualification_group IN (5,6)
            AND COUNT(*) > 0
        )
),
patient_counts AS (
    SELECT
        patient_id,
        COUNT(DISTINCT ccw_condition_id) AS ccw_condition_count
    FROM qualified_conditions
    GROUP BY patient_id
)
UPDATE work_rohanramirez_a299.hospice_f_candidates
SET ccw_condition_count = c.ccw_condition_count
FROM patient_counts c
WHERE hospice_f_candidates.patient_id = c.patient_id;
/* this perserves the rules 
Group 1     inpatient
Groups 2–3  inpatient OR ≥2 outpatient dates
Group 4     outpatient
Groups 5–6  either setting
*/
/* QUALITY CHECK */
SELECT
    COUNT(*) AS patients,
    SUM(CASE WHEN ccw_condition_count IS NULL THEN 1 ELSE 0 END) AS missing_ccw,
    MIN(ccw_condition_count) AS min_ccw,
    MAX(ccw_condition_count) AS max_ccw,
    AVG(ccw_condition_count) AS mean_ccw
FROM work_rohanramirez_a299.hospice_f_candidates;
/*MY THOUGHTS WELL IT IS BOUNDED BY A MAX OF 30 CONDITIONS SO 29 IS GOOD AT LEAST. A MIN IS 0 MAKES SENSE ALSO I NEED TO SEE THE DISTRIBUTION OF 7  */
/* CCW CONDITION COUNT DISTRIBUTION */
SELECT
    ccw_condition_count,
    COUNT(*) AS patients
FROM work_rohanramirez_a299.hospice_f_candidates
GROUP BY ccw_condition_count
ORDER BY ccw_condition_count;
/* I COUNTED IT and IT DOES SUM to MY COHORT BEING 871,624 SO THE DISTRIBUTION MATCHES with MY EARLIER COUNT */
