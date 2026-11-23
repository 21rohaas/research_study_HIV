/* how i got the date ranges for non inpatient table */
SELECT
    MIN(service_date)::DATE AS min_service_date,
    MAX(service_date)::DATE AS max_service_date
FROM komodo_202606.non_inpatient_events;
/* table used to make finalized format of non inpatient table*/
/* Final standardized non-inpatient hospice-event table shell */
/* drop table if exists work_rohanramirez_a299.hospice_nonip_events; */
CREATE TABLE work_rohanramirez_a299.hospice_nonip_events
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS
SELECT
    n.patient_id,
    n.utilization_id,
    CAST('non_inpatient' AS VARCHAR(20))
        AS claim_source,
    n.service_date::DATE
        AS event_date,
    CAST(NULL AS VARCHAR(30))
        AS event_date_source,
    CAST(n.bill_type_code AS VARCHAR(50))
        AS bill_type_code,
    /* Standardized hospice level/place */
    CAST(NULL AS VARCHAR(4))
        AS level_code,
    CAST(NULL AS VARCHAR(5))
        AS place_code,
    /* ALL revenue codes observed across the dated claim */
    CAST(NULL AS VARCHAR(65535))
        AS revenue_codes,
    /* Only hospice revenue codes:
       0651, 0652, 0655, 0656 */
    CAST(NULL AS VARCHAR(65535))
        AS qualifying_revenue_codes,
    /* ALL procedure/CPT-HCPCS codes observed across the dated claim */
    CAST(NULL AS VARCHAR(65535))
        AS cpt_hcpcs_codes,
    /* Only hospice place codes:
       Q5001-Q5010 */
    CAST(NULL AS VARCHAR(65535))
        AS qualifying_cpt_hcpcs_codes,
    n.service_area_type,
    CAST(n.primary_diagnosis_code_array AS VARCHAR(65535))
        AS primary_diagnosis_codes,
    CAST(n.diagnosis_codes AS VARCHAR(65535))
        AS diagnosis_codes,
    /* Inpatient-only fields */
    CAST(NULL AS DATE)
        AS admit_date,
    CAST(NULL AS DATE)
        AS discharge_date,
    CAST(NULL AS DATE)
        AS claim_from_date,
    CAST(NULL AS DATE)
        AS claim_through_date,
    /* Non-inpatient dates */
    n.service_date::DATE
        AS service_date,
    n.service_to_date::DATE
        AS service_to_date,
    /* Audit information from the original claim lines */
    CAST(NULL AS BIGINT)
        AS line_count,
    CAST(NULL AS BIGINT)
        AS first_line_number,
    CAST(NULL AS BIGINT)
        AS last_line_number,
    CAST(NULL AS VARCHAR(65535))
        AS line_numbers
FROM komodo_202606.non_inpatient_events n
WHERE 1 = 0;
 /* this isused to check the cols i made earlier for the table */
SELECT
    ordinal_position,
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'work_rohanramirez_a299'
  AND table_name = 'hospice_nonip_events'
ORDER BY ordinal_position;
/* bruh it deleted my fucking work
SELECT
    table_schema,
    table_name
FROM information_schema.tables
WHERE table_schema = 'work_rohanramirez_a299'
ORDER BY table_name;*/
/*batch_keys
- identifies the exact hospice-bearing
  patient_id + utilization_id + service_date groups
batch_lines*/
CREATE TABLE work_rohanramirez_a299.hospice_nonip_batch_keys
DISTKEY(patient_id) AS
SELECT DISTINCT
    patient_id,
    utilization_id,
    service_date::DATE AS service_date
FROM komodo_202606.non_inpatient_events
WHERE patient_id IS NOT NULL
  AND utilization_id IS NOT NULL
  AND service_date >= '2026-01-01'
  AND service_date <  '2026-07-01'
  AND (
         bill_type_code LIKE '81%'
      OR bill_type_code LIKE '82%'
      OR revenue_code IN ('0651','0652','0655','0656')
      OR procedure_code IN (
            'Q5001','Q5002','Q5003','Q5004','Q5005',
            'Q5006','Q5007','Q5008','Q5009','Q5010'
         )
  );
 /* quality check */ 
 SELECT
    COUNT(*) AS qualifying_dated_events,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    MIN(service_date) AS min_service_date,
    MAX(service_date) AS max_service_date
FROM work_rohanramirez_a299.hospice_nonip_batch_keys;
/* batch lines
-retrieves ALL raw lines for those groups
-already contains:
     revenue_code
     procedure_code 
 */
CREATE TABLE work_rohanramirez_a299.hospice_nonip_batch_lines
DISTKEY(patient_id) AS
SELECT
    n.patient_id,
    n.utilization_id,
    n.line_number,
    n.service_date::DATE AS service_date,
    n.service_to_date::DATE AS service_to_date,
    n.bill_type_code,
    n.revenue_code,
    n.procedure_code,
    n.service_area_type,
    CAST(n.primary_diagnosis_code_array AS VARCHAR(65535))
        AS primary_diagnosis_codes,
    CAST(n.diagnosis_codes AS VARCHAR(65535))
        AS diagnosis_codes
FROM komodo_202606.non_inpatient_events n
INNER JOIN work_rohanramirez_a299.hospice_nonip_batch_keys h
    ON n.patient_id = h.patient_id
   AND n.utilization_id = h.utilization_id
   AND n.service_date = h.service_date
WHERE n.service_date >= '2026-01-01'
  AND n.service_date <  '2026-07-01';
/* check for batch lines buh takes so long*/
 SELECT
    COUNT(*) AS raw_lines,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    MIN(service_date) AS min_service_date,
    MAX(service_date) AS max_service_date
FROM work_rohanramirez_a299.hospice_nonip_batch_lines;
/* batch core now 
 patient_id + utilization_id + service_date. no filtering here */
 /* DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_nonip_batch_core; */ 
CREATE TABLE work_rohanramirez_a299.hospice_nonip_batch_core
DISTKEY(patient_id)
SORTKEY(patient_id, utilization_id, service_date) AS
WITH core_stats AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        COUNT(*) AS line_count,
        MIN(line_number) AS first_line_number,
        MAX(line_number) AS last_line_number,
        /* Keep bill type when observed values agree */
        CASE
            WHEN MIN(
                NULLIF(TRIM(CAST(bill_type_code AS VARCHAR(50))), '')
            ) =
            MAX(
                NULLIF(TRIM(CAST(bill_type_code AS VARCHAR(50))), '')
            )
            THEN MAX(
                NULLIF(TRIM(CAST(bill_type_code AS VARCHAR(50))), '')
            )
        END AS bill_type_code,
        MAX(service_area_type) AS service_area_type,
        MAX(primary_diagnosis_codes)
            AS primary_diagnosis_codes,
        MAX(diagnosis_codes)
            AS diagnosis_codes,
        MAX(service_to_date)::DATE AS service_to_date
    FROM work_rohanramirez_a299.hospice_nonip_batch_lines
    GROUP BY
        patient_id,
        utilization_id,
        service_date
),
/* Preserve line numbers */
line_list AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        '[' ||
        LISTAGG(
            CAST(line_number AS VARCHAR(20)),
            ','
        ) WITHIN GROUP (
            ORDER BY line_number
        )
        || ']' AS line_numbers
    FROM work_rohanramirez_a299.hospice_nonip_batch_lines
    WHERE line_number IS NOT NULL
    GROUP BY
        patient_id,
        utilization_id,
        service_date
),
/* Find each unique revenue code and where it first appeared */
distinct_revenue AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        TRIM(CAST(revenue_code AS VARCHAR(100)))
            AS revenue_code,
        MIN(line_number) AS first_line_number
    FROM work_rohanramirez_a299.hospice_nonip_batch_lines
    WHERE NULLIF(
        TRIM(CAST(revenue_code AS VARCHAR(100))),
        ''
    ) IS NOT NULL
    GROUP BY
        patient_id,
        utilization_id,
        service_date,
        TRIM(CAST(revenue_code AS VARCHAR(100)))
),
/* ALL revenue codes */
revenue_list AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        '[' ||
        LISTAGG(
            CHR(34) || revenue_code || CHR(34),
            ','
        ) WITHIN GROUP (
            ORDER BY first_line_number
        )
        || ']' AS revenue_codes
    FROM distinct_revenue
    GROUP BY
        patient_id,
        utilization_id,
        service_date
),
/* Hospice-specific revenue codes */
qualifying_revenue AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        '[' ||
        LISTAGG(
            CHR(34) || revenue_code || CHR(34),
            ','
        ) WITHIN GROUP (
            ORDER BY first_line_number
        )
        || ']' AS qualifying_revenue_codes,
        CASE
            WHEN COUNT(*) = 1
            THEN MAX(revenue_code)
        END AS level_code
    FROM distinct_revenue
    WHERE revenue_code IN (
        '0651','0652','0655','0656'
    )
    GROUP BY
        patient_id,
        utilization_id,
        service_date
),
/* Find each unique procedure code and where it first appeared */
distinct_procedure AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        TRIM(CAST(procedure_code AS VARCHAR(100)))
            AS procedure_code,
        MIN(line_number) AS first_line_number
    FROM work_rohanramirez_a299.hospice_nonip_batch_lines
    WHERE NULLIF(
        TRIM(CAST(procedure_code AS VARCHAR(100))),
        ''
    ) IS NOT NULL
    GROUP BY
        patient_id,
        utilization_id,
        service_date,
        TRIM(CAST(procedure_code AS VARCHAR(100)))
),
/* ALL CPT/HCPCS codes */
procedure_list AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        '[' ||
        LISTAGG(
            CHR(34) || procedure_code || CHR(34),
            ','
        ) WITHIN GROUP (
            ORDER BY first_line_number
        )
        || ']' AS cpt_hcpcs_codes
    FROM distinct_procedure
    GROUP BY
        patient_id,
        utilization_id,
        service_date
),
/* Hospice-specific Q500x codes */
qualifying_procedure AS (
    SELECT
        patient_id,
        utilization_id,
        service_date,
        '[' ||
        LISTAGG(
            CHR(34) || procedure_code || CHR(34),
            ','
        ) WITHIN GROUP (
            ORDER BY first_line_number
        )
        || ']' AS qualifying_cpt_hcpcs_codes,
        CASE
            WHEN COUNT(*) = 1
            THEN MAX(procedure_code)
        END AS place_code
    FROM distinct_procedure
    WHERE procedure_code IN (
        'Q5001','Q5002','Q5003','Q5004','Q5005',
        'Q5006','Q5007','Q5008','Q5009','Q5010'
    )
    GROUP BY
        patient_id,
        utilization_id,
        service_date
)
SELECT
    c.patient_id,
    c.utilization_id,
    c.service_date,
    c.line_count,
    c.first_line_number,
    c.last_line_number,
    l.line_numbers,
    c.bill_type_code,
    /* Preserve everything */
    r.revenue_codes,
    p.cpt_hcpcs_codes,
    /* Preserve hospice-specific subsets separately */
    qr.qualifying_revenue_codes,
    qp.qualifying_cpt_hcpcs_codes,
    /* Descriptive standardized fields */
    qr.level_code,
    qp.place_code,
    c.service_area_type,
    c.primary_diagnosis_codes,
    c.diagnosis_codes,
    c.service_to_date
FROM core_stats c
LEFT JOIN line_list l
    ON c.patient_id = l.patient_id
   AND c.utilization_id = l.utilization_id
   AND c.service_date = l.service_date
LEFT JOIN revenue_list r
    ON c.patient_id = r.patient_id
   AND c.utilization_id = r.utilization_id
   AND c.service_date = r.service_date
LEFT JOIN qualifying_revenue qr
    ON c.patient_id = qr.patient_id
   AND c.utilization_id = qr.utilization_id
   AND c.service_date = qr.service_date
LEFT JOIN procedure_list p
    ON c.patient_id = p.patient_id
   AND c.utilization_id = p.utilization_id
   AND c.service_date = p.service_date
LEFT JOIN qualifying_procedure qp
    ON c.patient_id = qp.patient_id
   AND c.utilization_id = qp.utilization_id
   AND c.service_date = qp.service_date;
  /* check the collapse to make sure it worked*/
  SELECT
    COUNT(*) AS core_events,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    SUM(line_count) AS lines_represented,
    MIN(service_date) AS min_service_date,
    MAX(service_date) AS max_service_date
FROM work_rohanramirez_a299.hospice_nonip_batch_core;
/* batch events now building standardized code information made */ 
CREATE TABLE work_rohanramirez_a299.hospice_nonip_batch_events
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS
SELECT
    c.patient_id,
    c.utilization_id,
    CAST('non_inpatient' AS VARCHAR(20))
        AS claim_source,
    c.service_date AS event_date,
    CASE
        WHEN c.service_date IS NOT NULL
        THEN CAST('service_date' AS VARCHAR(30))
    END AS event_date_source,
    c.bill_type_code,
    c.level_code,
    c.place_code,
    /* ALL observed claim codes */
    c.revenue_codes,
    /* Hospice-specific subset */
    c.qualifying_revenue_codes,
    /* ALL observed procedure/CPT-HCPCS codes */
    c.cpt_hcpcs_codes,
    /* Hospice-specific Q500x subset */
    c.qualifying_cpt_hcpcs_codes,
    c.service_area_type,
    c.primary_diagnosis_codes,
    c.diagnosis_codes,
    /* Inpatient-only dates remain NULL */
    CAST(NULL AS DATE) AS admit_date,
    CAST(NULL AS DATE) AS discharge_date,
    CAST(NULL AS DATE) AS claim_from_date,
    CAST(NULL AS DATE) AS claim_through_date,
    c.service_date,
    c.service_to_date,
    c.line_count,
    c.first_line_number,
    c.last_line_number,
    c.line_numbers
FROM work_rohanramirez_a299.hospice_nonip_batch_core c;
/* checking batch events */
SELECT
    COUNT(*) AS final_events,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    SUM(line_count) AS lines_represented,
    MIN(event_date) AS min_event_date,
    MAX(event_date) AS max_event_date
FROM work_rohanramirez_a299.hospice_nonip_batch_events;
/* append 2015 to the permanent non-ip table */
INSERT INTO work_rohanramirez_a299.hospice_nonip_events
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
FROM work_rohanramirez_a299.hospice_nonip_batch_events;
/* verifying now */
SELECT
    COUNT(*) AS events_2016,
    COUNT(DISTINCT patient_id) AS patients_2016,
    COUNT(DISTINCT utilization_id) AS utilizations_2016,
    SUM(line_count) AS represented_lines,
    MIN(event_date) AS min_event_date,
    MAX(event_date) AS max_event_date
FROM work_rohanramirez_a299.hospice_nonip_events
WHERE event_date >= '2026-01-01'
  AND event_date <  '2026-07-01';
 /* checking the range perfect we see it all */
SELECT
    EXTRACT(YEAR FROM event_date) AS event_year,
    COUNT(*) AS events,
    COUNT(DISTINCT patient_id) AS patients,
    COUNT(DISTINCT utilization_id) AS utilizations,
    SUM(line_count) AS represented_lines
FROM work_rohanramirez_a299.hospice_nonip_events
WHERE event_date IS NOT NULL
GROUP BY EXTRACT(YEAR FROM event_date)
ORDER BY event_year;
 /* the permanenet reiterating table i .hospice_nonip_events */ 
/* now we repeat and delete until we get to 2026 */ 
/* Finished 2015 working tables */
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_nonip_batch_events;
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_nonip_batch_core;
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_nonip_batch_lines;
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_nonip_batch_keys; 
/* now we repeat for the other years */ 
/* ranges to use 
 * 2015-01-01 and < 2016-01-01  c
 * 2016-01-01 and 2017-01-01    c
 * 2017-01-01 and 2018-01-01    c
 * 2018-01-01 and 2019-01-01    c
 * 2019-01-01 and 2020-01-01    c
 * 2020-01-01 and 2021-01-01    c had to diide it into 2 2020-01-01 to 2020-07-01, 2020-07-01-2021-01-01
 * 2021-01-01 and 2022-01-01    c dvivide also 
 * 2022-01-01 and 2023-01-01    c  divide
 * 2023-01-01 and 2024-01-01    c   divide 
 * 2024-01-01 and 2025-01-01    c
 * 2025-01-01 and 2026-01-01    c
 * 2026-01-01 and 2027-01-01    c goes to the 5th month 
 * check tables i have made */
SELECT
    table_schema,
    table_name
FROM information_schema.tables
WHERE table_schema = 'work_rohanramirez_a299'
ORDER BY table_name;
/* now to clarify the tables themselves need narrowing down to hospice admission*/
DROP TABLE IF EXISTS work_rohanramirez_a299.hospice_nonip_admission_events;

CREATE TABLE work_rohanramirez_a299.hospice_nonip_admission_events
DISTKEY(patient_id)
SORTKEY(patient_id, event_date, utilization_id) AS

SELECT *
FROM work_rohanramirez_a299.hospice_nonip_events
WHERE UPPER(TRIM(bill_type_code)) IN (
    '81A','82A',
    '812','822',
    '811','821'
);