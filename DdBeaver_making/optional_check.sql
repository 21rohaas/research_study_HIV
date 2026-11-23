/*this code was ysed to see why 7 patients were not included */ 
WITH inpatient AS (
    SELECT DISTINCT patient_id
    FROM work_rohanramirez_a299.hospice_inpatient_admission_events
    WHERE patient_id IS NOT NULL
),

noninpatient AS (
    SELECT DISTINCT patient_id
    FROM work_rohanramirez_a299.hospice_nonip_admission_events
    WHERE patient_id IS NOT NULL
)

SELECT
    (SELECT COUNT(*) FROM inpatient)
        AS inpatient_unique_patients,
    (SELECT COUNT(*) FROM noninpatient)
        AS noninpatient_unique_patients,

    (
        SELECT COUNT(*)
        FROM inpatient i
        INNER JOIN noninpatient n
            ON i.patient_id = n.patient_id
    ) AS patients_in_both,

    (
        SELECT COUNT(*)
        FROM inpatient i
        LEFT JOIN noninpatient n
            ON i.patient_id = n.patient_id
        WHERE n.patient_id IS NULL
    ) AS inpatient_only,

    (
        SELECT COUNT(*)
        FROM noninpatient n
        LEFT JOIN inpatient i
            ON n.patient_id = i.patient_id
        WHERE i.patient_id IS NULL
    ) AS noninpatient_only,

    (
        SELECT COUNT(*)
        FROM (
            SELECT patient_id FROM inpatient
            UNION
            SELECT patient_id FROM noninpatient
        ) x
    ) AS total_unique_patients;
    /* the issue is i a, seeing a count of missing 7 */
   WITH raw_nonip_admission AS (
    SELECT DISTINCT patient_id
    FROM komodo_202606.non_inpatient_events
    WHERE patient_id IS NOT NULL
      AND UPPER(TRIM(bill_type_code)) IN (
          '81A','82A',
          '812','822',
          '811','821'
      )
),

standardized_nonip_admission AS (
    SELECT DISTINCT patient_id
    FROM work_rohanramirez_a299.hospice_nonip_admission_events
    WHERE patient_id IS NOT NULL
)

SELECT r.patient_id
FROM raw_nonip_admission r
LEFT JOIN standardized_nonip_admission s
    ON r.patient_id = s.patient_id
WHERE s.patient_id IS NULL;
/* to see why the 7 disapearred */
SELECT
    patient_id,
    utilization_id,
    service_date,
    service_to_date,
    bill_type_code
FROM komodo_202606.non_inpatient_events
WHERE patient_id IN (
    '2G2F8K4Z',
    '7KSVMZSR',
    'H4CZ7722',
    '9NBEVSLN',
    '564S8FTX',
    'RYL4C38J',
    'KG76NGTV'
)
AND UPPER(TRIM(bill_type_code)) IN (
    '81A','82A',
    '812','822',
    '811','821'
)
ORDER BY patient_id, service_date;