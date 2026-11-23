SELECT
    MIN(claim_from_date)::DATE AS min_claim_from_date,
    MAX(claim_from_date)::DATE AS max_claim_from_date
FROM komodo_202606.inpatient_events;
/* let me check the granualarity */
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(*) - COUNT(DISTINCT utilization_id)
        AS duplicate_utilization_ids
FROM komodo_202606.inpatient_events; 
SELECT
    COUNT(*) AS duplicated_patient_utilization_groups
FROM (
    SELECT
        patient_id,
        utilization_id
    FROM komodo_202606.inpatient_events
    WHERE patient_id IS NOT NULL
      AND utilization_id IS NOT NULL
    GROUP BY patient_id, utilization_id
    HAVING COUNT(*) > 1
) x;
/* thoughts is that unique patients and yes no duplcate utilization ids */
/* this is btw the total unique inpatients so not only including hospice */ 
/* this is the count of patients with any hospice related evidence*/ 
WITH inpatient_hospice AS (
    SELECT DISTINCT
        patient_id
    FROM komodo_202606.inpatient_events
    WHERE patient_id IS NOT NULL
      AND (
             bill_type_code LIKE '81%'
          OR bill_type_code LIKE '82%'
          OR revenue_codes LIKE '%"0651"%'
          OR revenue_codes LIKE '%"0652"%'
          OR revenue_codes LIKE '%"0655"%'
          OR revenue_codes LIKE '%"0656"%'
          OR cpt_hcpcs_codes LIKE '%"Q5001"%'
          OR cpt_hcpcs_codes LIKE '%"Q5002"%'
          OR cpt_hcpcs_codes LIKE '%"Q5003"%'
          OR cpt_hcpcs_codes LIKE '%"Q5004"%'
          OR cpt_hcpcs_codes LIKE '%"Q5005"%'
          OR cpt_hcpcs_codes LIKE '%"Q5006"%'
          OR cpt_hcpcs_codes LIKE '%"Q5007"%'
          OR cpt_hcpcs_codes LIKE '%"Q5008"%'
          OR cpt_hcpcs_codes LIKE '%"Q5009"%'
          OR cpt_hcpcs_codes LIKE '%"Q5010"%'
      )
),
nonip_hospice AS (
    SELECT DISTINCT
        patient_id
    FROM komodo_202606.non_inpatient_events
    WHERE patient_id IS NOT NULL

      AND (
             bill_type_code LIKE '81%'
          OR bill_type_code LIKE '82%'
          OR revenue_code IN ('0651','0652','0655','0656')
          OR procedure_code IN (
                'Q5001','Q5002','Q5003','Q5004','Q5005',
                'Q5006','Q5007','Q5008','Q5009','Q5010'
             )
      )
)
SELECT
    /* All hospice patients seen in inpatient */
    (
        SELECT COUNT(*)
        FROM inpatient_hospice
    ) AS inpatient_hospice_patients,
    /* All hospice patients seen in non-inpatient */
    (
        SELECT COUNT(*)
        FROM nonip_hospice
    ) AS nonip_hospice_patients,
    /* Seen in BOTH sources */
    (
        SELECT COUNT(*)
        FROM inpatient_hospice i
        INNER JOIN nonip_hospice n
            ON i.patient_id = n.patient_id
    ) AS both_sources,
    /* Inpatient ONLY */
    (
        SELECT COUNT(*)
        FROM inpatient_hospice i
        LEFT JOIN nonip_hospice n
            ON i.patient_id = n.patient_id
        WHERE n.patient_id IS NULL
    ) AS inpatient_only,
    /* Non-inpatient ONLY */
    (
        SELECT COUNT(*)
        FROM nonip_hospice n
        LEFT JOIN inpatient_hospice i
            ON n.patient_id = i.patient_id
        WHERE i.patient_id IS NULL
    ) AS noninpatient_only,
    /* Union across both sources */
    (
        SELECT COUNT(*)
        FROM (
            SELECT patient_id FROM inpatient_hospice
            UNION
            SELECT patient_id FROM nonip_hospice
        ) u
    ) AS total_unique_hospice_patients;
/* table used to make finalized format of inpatient table*/
/* Final standardized inpatient hospice-event table shell */
/* big difference is this is already at the claim level so a claim per row */
/* oh also my intention was primary diagnosis code and a diagnosis codes */ 
CREATE TABLE work_rohanramirez_a299.hospice_inpatient_events
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS
SELECT
    i.patient_id,
    i.utilization_id,
    CAST('inpatient' AS VARCHAR(20))
        AS claim_source,
    /* Standardized event date:
       claim_from_date preferred, otherwise admit_date */
    COALESCE(
        i.claim_from_date::DATE,
        i.admit_date::DATE
    ) AS event_date,
    CASE
        WHEN i.claim_from_date IS NOT NULL
            THEN CAST('claim_from_date' AS VARCHAR(30))
        WHEN i.admit_date IS NOT NULL
            THEN CAST('admit_date' AS VARCHAR(30))
        ELSE CAST(NULL AS VARCHAR(30))
    END AS event_date_source,
    CAST(i.bill_type_code AS VARCHAR(50))
        AS bill_type_code,
    /* Standardized hospice level/place */
    CAST(NULL AS VARCHAR(4))
        AS level_code,
    CAST(NULL AS VARCHAR(5))
        AS place_code,
    /* ALL revenue codes already stored at inpatient claim level */
    CAST(i.revenue_codes AS VARCHAR(65535))
        AS revenue_codes,
    /* Only hospice revenue codes:
       0651, 0652, 0655, 0656 */
    CAST(NULL AS VARCHAR(65535))
        AS qualifying_revenue_codes,
    /* ALL CPT/HCPCS codes already stored at inpatient claim level */
    CAST(i.cpt_hcpcs_codes AS VARCHAR(65535))
        AS cpt_hcpcs_codes,
    /* Only hospice place codes:
       Q5001-Q5010 */
    CAST(NULL AS VARCHAR(65535))
        AS qualifying_cpt_hcpcs_codes,
    i.service_area_type,
    /* Convert inpatient primary diagnosis:
       F3160 -> ["F3160"] */
    CAST(
        CASE
            WHEN i.primary_diagnosis_code IS NOT NULL
                 AND TRIM(i.primary_diagnosis_code) <> ''
            THEN
                '["' || TRIM(i.primary_diagnosis_code) || '"]'
            ELSE NULL
        END
        AS VARCHAR(65535)
    ) AS primary_diagnosis_codes,
    /* Standardized full diagnosis list:
       primary diagnosis + secondary diagnoses */
    CAST(
        CASE
            /* Primary + secondary diagnoses */
            WHEN i.primary_diagnosis_code IS NOT NULL
                 AND TRIM(i.primary_diagnosis_code) <> ''
                 AND i.secondary_diagnosis_codes IS NOT NULL
                 AND TRIM(i.secondary_diagnosis_codes) NOT IN ('', '[]', 'NA')
            THEN
                '["'
                || TRIM(i.primary_diagnosis_code)
                || '",'
                || SUBSTRING(
                       TRIM(i.secondary_diagnosis_codes),
                       2
                   )
            /* Primary diagnosis only */
            WHEN i.primary_diagnosis_code IS NOT NULL
                 AND TRIM(i.primary_diagnosis_code) <> ''
            THEN
                '["'
                || TRIM(i.primary_diagnosis_code)
                || '"]'
            /* Secondary diagnoses only */
            WHEN i.secondary_diagnosis_codes IS NOT NULL
                 AND TRIM(i.secondary_diagnosis_codes) NOT IN ('', '[]', 'NA')
            THEN
                TRIM(i.secondary_diagnosis_codes)
            ELSE NULL
        END
        AS VARCHAR(65535)
    ) AS diagnosis_codes,
    /* Inpatient dates */
    i.admit_date::DATE
        AS admit_date,
    i.discharge_date::DATE
        AS discharge_date,
    i.claim_from_date::DATE
        AS claim_from_date,
    i.claim_through_date::DATE
        AS claim_through_date,
    /* Non-inpatient-only dates */
    CAST(NULL AS DATE)
        AS service_date,
    CAST(NULL AS DATE)
        AS service_to_date,
    /* Non-inpatient line-level audit fields */
    CAST(NULL AS BIGINT)
        AS line_count,
    CAST(NULL AS BIGINT)
        AS first_line_number,
    CAST(NULL AS BIGINT)
        AS last_line_number,
    CAST(NULL AS VARCHAR(65535))
        AS line_numbers
FROM komodo_202606.inpatient_events i
/* Create empty permanent shell only */
WHERE 1 = 0;
/* now we will follow the same format --batch keys */
/* we do not need batch lines or batch core. or even vist id. */
CREATE TABLE work_rohanramirez_a299.hospice_inpatient_batch_keys
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS
SELECT
    patient_id,
    utilization_id,
    /* Standardized inpatient chronology date */
    COALESCE(
        claim_from_date::DATE,
        admit_date::DATE
    ) AS event_date
FROM komodo_202606.inpatient_events
WHERE patient_id IS NOT NULL
  AND utilization_id IS NOT NULL
  /* year batch */
  AND COALESCE(claim_from_date::DATE, admit_date::DATE) >= '2026-01-01'
  AND COALESCE(claim_from_date::DATE, admit_date::DATE) <  '2027-01-01'
  /* Any hospice evidence */
  AND (
         bill_type_code LIKE '81%'
      OR bill_type_code LIKE '82%'
      OR revenue_codes LIKE '%"0651"%'
      OR revenue_codes LIKE '%"0652"%'
      OR revenue_codes LIKE '%"0655"%'
      OR revenue_codes LIKE '%"0656"%'
      OR cpt_hcpcs_codes LIKE '%"Q5001"%'
      OR cpt_hcpcs_codes LIKE '%"Q5002"%'
      OR cpt_hcpcs_codes LIKE '%"Q5003"%'
      OR cpt_hcpcs_codes LIKE '%"Q5004"%'
      OR cpt_hcpcs_codes LIKE '%"Q5005"%'
      OR cpt_hcpcs_codes LIKE '%"Q5006"%'
      OR cpt_hcpcs_codes LIKE '%"Q5007"%'
      OR cpt_hcpcs_codes LIKE '%"Q5008"%'
      OR cpt_hcpcs_codes LIKE '%"Q5009"%'
      OR cpt_hcpcs_codes LIKE '%"Q5010"%'
  );
 /* quality check */
 SELECT
    COUNT(*) AS qualifying_inpatient_claims,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    MIN(event_date) AS min_event_date,
    MAX(event_date) AS max_event_date
FROM work_rohanramirez_a299.hospice_inpatient_batch_keys;
/* batch events */
CREATE TABLE work_rohanramirez_a299.hospice_inpatient_batch_events
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS
WITH src AS (
    SELECT
        i.*,
        /* Hospice revenue-code indicators */
        CASE WHEN i.revenue_codes LIKE '%"0651"%' THEN 1 ELSE 0 END AS r0651,
        CASE WHEN i.revenue_codes LIKE '%"0652"%' THEN 1 ELSE 0 END AS r0652,
        CASE WHEN i.revenue_codes LIKE '%"0655"%' THEN 1 ELSE 0 END AS r0655,
        CASE WHEN i.revenue_codes LIKE '%"0656"%' THEN 1 ELSE 0 END AS r0656,
        /* Hospice place-code indicators */
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5001"%' THEN 1 ELSE 0 END AS q5001,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5002"%' THEN 1 ELSE 0 END AS q5002,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5003"%' THEN 1 ELSE 0 END AS q5003,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5004"%' THEN 1 ELSE 0 END AS q5004,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5005"%' THEN 1 ELSE 0 END AS q5005,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5006"%' THEN 1 ELSE 0 END AS q5006,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5007"%' THEN 1 ELSE 0 END AS q5007,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5008"%' THEN 1 ELSE 0 END AS q5008,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5009"%' THEN 1 ELSE 0 END AS q5009,
        CASE WHEN i.cpt_hcpcs_codes LIKE '%"Q5010"%' THEN 1 ELSE 0 END AS q5010
    FROM komodo_202606.inpatient_events i
    INNER JOIN work_rohanramirez_a299.hospice_inpatient_batch_keys k
        ON i.patient_id = k.patient_id
       AND i.utilization_id = k.utilization_id
),
codes AS (
    SELECT
        *,
        r0651 + r0652 + r0655 + r0656
            AS revenue_hospice_count,
        q5001 + q5002 + q5003 + q5004 + q5005
        + q5006 + q5007 + q5008 + q5009 + q5010
            AS place_hospice_count,
        /* Build qualifying revenue-code string */
        CASE WHEN r0651 + r0652 + r0655 + r0656 > 0
        THEN
            '[' ||
            LEFT(
                  CASE WHEN r0651 = 1 THEN '"0651",' ELSE '' END
                || CASE WHEN r0652 = 1 THEN '"0652",' ELSE '' END
                || CASE WHEN r0655 = 1 THEN '"0655",' ELSE '' END
                || CASE WHEN r0656 = 1 THEN '"0656",' ELSE '' END,
                LENGTH(
                      CASE WHEN r0651 = 1 THEN '"0651",' ELSE '' END
                    || CASE WHEN r0652 = 1 THEN '"0652",' ELSE '' END
                    || CASE WHEN r0655 = 1 THEN '"0655",' ELSE '' END
                    || CASE WHEN r0656 = 1 THEN '"0656",' ELSE '' END
                ) - 1
            )
            || ']'
        END AS qualifying_revenue_codes_new,
        /* Build qualifying Q-code string */
        CASE WHEN
            q5001 + q5002 + q5003 + q5004 + q5005
          + q5006 + q5007 + q5008 + q5009 + q5010 > 0
        THEN
            '[' ||
            LEFT(
                  CASE WHEN q5001 = 1 THEN '"Q5001",' ELSE '' END
                || CASE WHEN q5002 = 1 THEN '"Q5002",' ELSE '' END
                || CASE WHEN q5003 = 1 THEN '"Q5003",' ELSE '' END
                || CASE WHEN q5004 = 1 THEN '"Q5004",' ELSE '' END
                || CASE WHEN q5005 = 1 THEN '"Q5005",' ELSE '' END
                || CASE WHEN q5006 = 1 THEN '"Q5006",' ELSE '' END
                || CASE WHEN q5007 = 1 THEN '"Q5007",' ELSE '' END
                || CASE WHEN q5008 = 1 THEN '"Q5008",' ELSE '' END
                || CASE WHEN q5009 = 1 THEN '"Q5009",' ELSE '' END
                || CASE WHEN q5010 = 1 THEN '"Q5010",' ELSE '' END,
                LENGTH(
                      CASE WHEN q5001 = 1 THEN '"Q5001",' ELSE '' END
                    || CASE WHEN q5002 = 1 THEN '"Q5002",' ELSE '' END
                    || CASE WHEN q5003 = 1 THEN '"Q5003",' ELSE '' END
                    || CASE WHEN q5004 = 1 THEN '"Q5004",' ELSE '' END
                    || CASE WHEN q5005 = 1 THEN '"Q5005",' ELSE '' END
                    || CASE WHEN q5006 = 1 THEN '"Q5006",' ELSE '' END
                    || CASE WHEN q5007 = 1 THEN '"Q5007",' ELSE '' END
                    || CASE WHEN q5008 = 1 THEN '"Q5008",' ELSE '' END
                    || CASE WHEN q5009 = 1 THEN '"Q5009",' ELSE '' END
                    || CASE WHEN q5010 = 1 THEN '"Q5010",' ELSE '' END
                ) - 1
            )
            || ']'
        END AS qualifying_cpt_hcpcs_codes_new
    FROM src
)
SELECT
    patient_id,
    utilization_id,
    CAST('inpatient' AS VARCHAR(20))
        AS claim_source,
    COALESCE(
        claim_from_date::DATE,
        admit_date::DATE
    ) AS event_date,
    CASE
        WHEN claim_from_date IS NOT NULL
            THEN CAST('claim_from_date' AS VARCHAR(30))
        WHEN admit_date IS NOT NULL
            THEN CAST('admit_date' AS VARCHAR(30))
        ELSE NULL
    END AS event_date_source,
    CAST(bill_type_code AS VARCHAR(50))
        AS bill_type_code,
    /* One qualifying revenue code only */
    CASE
        WHEN revenue_hospice_count = 1 THEN
            CASE
                WHEN r0651 = 1 THEN '0651'
                WHEN r0652 = 1 THEN '0652'
                WHEN r0655 = 1 THEN '0655'
                WHEN r0656 = 1 THEN '0656'
            END
        ELSE NULL
    END AS level_code,
    /* One qualifying Q code only */
    CASE
        WHEN place_hospice_count = 1 THEN
            CASE
                WHEN q5001 = 1 THEN 'Q5001'
                WHEN q5002 = 1 THEN 'Q5002'
                WHEN q5003 = 1 THEN 'Q5003'
                WHEN q5004 = 1 THEN 'Q5004'
                WHEN q5005 = 1 THEN 'Q5005'
                WHEN q5006 = 1 THEN 'Q5006'
                WHEN q5007 = 1 THEN 'Q5007'
                WHEN q5008 = 1 THEN 'Q5008'
                WHEN q5009 = 1 THEN 'Q5009'
                WHEN q5010 = 1 THEN 'Q5010'
            END
        ELSE NULL
    END AS place_code,
    /* Preserve ALL original codes */
    CAST(revenue_codes AS VARCHAR(65535))
        AS revenue_codes,
    CAST(qualifying_revenue_codes_new AS VARCHAR(65535))
        AS qualifying_revenue_codes,
    CAST(cpt_hcpcs_codes AS VARCHAR(65535))
        AS cpt_hcpcs_codes,
    CAST(qualifying_cpt_hcpcs_codes_new AS VARCHAR(65535))
        AS qualifying_cpt_hcpcs_codes,
    service_area_type,
    /* Primary diagnosis standardized as list */
    CAST(
        CASE
            WHEN primary_diagnosis_code IS NOT NULL
                 AND TRIM(primary_diagnosis_code) <> ''
            THEN
                '["' || TRIM(primary_diagnosis_code) || '"]'
            ELSE NULL
        END
        AS VARCHAR(65535)
    ) AS primary_diagnosis_codes,
    /* Full diagnosis list = primary + secondary */
    CAST(
        CASE
            WHEN primary_diagnosis_code IS NOT NULL
                 AND TRIM(primary_diagnosis_code) <> ''
                 AND secondary_diagnosis_codes IS NOT NULL
                 AND TRIM(secondary_diagnosis_codes) NOT IN ('', '[]', 'NA')
            THEN
                '["'
                || TRIM(primary_diagnosis_code)
                || '",'
                || SUBSTRING(TRIM(secondary_diagnosis_codes), 2)
            WHEN primary_diagnosis_code IS NOT NULL
                 AND TRIM(primary_diagnosis_code) <> ''
            THEN
                '["'
                || TRIM(primary_diagnosis_code)
                || '"]'
            WHEN secondary_diagnosis_codes IS NOT NULL
                 AND TRIM(secondary_diagnosis_codes) NOT IN ('', '[]', 'NA')
            THEN
                TRIM(secondary_diagnosis_codes)
            ELSE NULL
        END
        AS VARCHAR(65535)
    ) AS diagnosis_codes,
    admit_date::DATE
        AS admit_date,
    discharge_date::DATE
        AS discharge_date,
    claim_from_date::DATE
        AS claim_from_date,
    claim_through_date::DATE
        AS claim_through_date,
    /* Non-IP-only fields */
    CAST(NULL AS DATE)
        AS service_date,
    CAST(NULL AS DATE)
        AS service_to_date,
    CAST(NULL AS BIGINT)
        AS line_count,
    CAST(NULL AS BIGINT)
        AS first_line_number,
    CAST(NULL AS BIGINT)
        AS last_line_number,
    CAST(NULL AS VARCHAR(65535))
        AS line_numbers
FROM codes;
/* QUALITY CHECK */ 
SELECT
    COUNT(*) AS batch_events,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    MIN(event_date) AS min_event_date,
    MAX(event_date) AS max_event_date
FROM work_rohanramirez_a299.hospice_inpatient_batch_events;
/* RECONCILING */ 
SELECT
    (
        SELECT COUNT(*)
        FROM work_rohanramirez_a299.hospice_inpatient_batch_keys
    ) AS batch_keys,

    (
        SELECT COUNT(*)
        FROM work_rohanramirez_a299.hospice_inpatient_batch_events
    ) AS batch_events;
/* CHECKING TO SEE IT HAS NOT BEEN INSERTED */
SELECT
    COUNT(*) AS existing_2016_rows
FROM work_rohanramirez_a299.hospice_inpatient_events
WHERE event_date >= '2026-01-01'
  AND event_date <  '2027-01-01';
/* NOW into PERMANENNT table*/ 
 INSERT INTO work_rohanramirez_a299.hospice_inpatient_events
(
    patient_id,
    utilization_id,
    claim_source,
    event_date,
    event_date_source,
    bill_type_code,
    level_code,
    place_code,
    revenue_codes,
    qualifying_revenue_codes,
    cpt_hcpcs_codes,
    qualifying_cpt_hcpcs_codes,
    service_area_type,
    primary_diagnosis_codes,
    diagnosis_codes,
    admit_date,
    discharge_date,
    claim_from_date,
    claim_through_date,
    service_date,
    service_to_date,
    line_count,
    first_line_number,
    last_line_number,
    line_numbers
)
SELECT
    patient_id,
    utilization_id,
    claim_source,
    event_date,
    event_date_source,
    bill_type_code,
    level_code,
    place_code,
    revenue_codes,
    qualifying_revenue_codes,
    cpt_hcpcs_codes,
    qualifying_cpt_hcpcs_codes,
    service_area_type,
    primary_diagnosis_codes,
    diagnosis_codes,
    admit_date,
    discharge_date,
    claim_from_date,
    claim_through_date,
    service_date,
    service_to_date,
    line_count,
    first_line_number,
    last_line_number,
    line_numbers
FROM work_rohanramirez_a299.hospice_inpatient_batch_events;
/* verifying */
SELECT
    COUNT(*) AS events_2016,
    COUNT(DISTINCT patient_id) AS patients_2016,
    COUNT(DISTINCT utilization_id) AS utilizations_2016,
    MIN(event_date) AS min_event_date,
    MAX(event_date) AS max_event_date
FROM work_rohanramirez_a299.hospice_inpatient_events
WHERE event_date >= '2026-01-01'
  AND event_date <  '2027-01-01';
 /* looking at overall built table */ 
 SELECT
    EXTRACT(YEAR FROM event_date) AS event_year,
    COUNT(*) AS events,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    SUM(line_count) AS represented_lines
FROM work_rohanramirez_a299.hospice_inpatient_events
WHERE event_date IS NOT NULL
GROUP BY EXTRACT(YEAR FROM event_date)
ORDER BY event_year;
/* DELETING table */ 
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_inpatient_batch_events;
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_inpatient_batch_keys;
/* 2016 C
 * 2017 C
 * 2018 C
 * 2019 C
 * 2020 C
 * 2021 C
 * 2022 C
 * 2023 C
 * 2024 C
 * 2025 C
 * 2026  C */
/* i need to narrow down these tables as i was too lax on admission 
 1. Have multiple qualifying admission-type claims in inpatient
2. Have multiple qualifying admission-type claims in non-inpatient
3. Appear in BOTH sources
4. Potentially enter hospice more than once over time 
the strict bill codes are:
81A / 82A = Notice of Election
812 / 822 = First claim in series
811 / 821 = Admit through discharge */
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_inpatient_admission_events;

CREATE TABLE work_rohanramirez_a299.hospice_inpatient_admission_events
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS

SELECT *
FROM work_rohanramirez_a299.hospice_inpatient_events
WHERE UPPER(TRIM(bill_type_code)) IN (
    '81A','82A',
    '812','822',
    '811','821'
);
