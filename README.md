# HIV and Hospice Care: Cohort Construction and Clinical Enrichment

## Project overview

This repository documents code developed for a retrospective study of **characteristics of hospice patients with and without identified human immunodeficiency virus (HIV)** in the Komodo Research Dataset. The analysis begins with patients who have an identifiable hospice admission; it is **not** an analysis comparing hospice users with people who never entered hospice.

The workflow combines Amazon Redshift SQL (developed in DBeaver), R, and a Python/PowerShell drug-class mapping utility. It covers:

- Identification of hospice admission and creation of a one-row-per-patient study cohort.
- One-year pre-admission medical and pharmacy eligibility checks.
- Three-route HIV identification using diagnoses and qualifying antiretroviral medication fills.
- Demographic, insurance, geographic, frailty, comorbidity, and chronic-condition enrichment.
- Antiretroviral therapy (ART) adherence measured with proportion of days covered (PDC).
- Non-ART polypharmacy from overlapping medication-class exposures.
- Cohort flow diagrams, quality assurance (QA), exploratory data analysis (EDA), and planned statistical analyses.

**Important:** The repository contains both (1) the **hospice-specific, index-date workflow** and (2) a separate **shareable 2022 calendar-year clinical-metrics implementation**. The latter is reference/reusable code; it should not be mistaken for the complete hospice-specific pipeline.

## Research outputs and privacy

Analysis code and selected, disclosure-reviewed figures can be shared in this public repository. The `Outputs/` directory is excluded through `.gitignore` and is not intended for publication. Patient-level claims, derived patient-level data, access credentials, private crosswalks, and any output restricted by the data-use agreement must remain in approved environments.

GitHub cannot make an individual file private inside an otherwise public repository. Access to separately stored results must be governed by the permissions of the approved storage platform. **Do not publish patient-level files or use unrestricted sharing links for restricted data.** An ignored file that was previously committed may still exist in Git history.

Selected figure: [HIV/hospice cohort flow diagram](images/consort_hiv_hospice.png) (generated with `consort_diagram_r.Rmd`). The diagram currently records a final eligible cohort of **871,624 patients**, including **2,364 HIV-positive** and **869,260 HIV-algorithm-negative** patients. These are values embedded in the supplied diagram code; verify them against final Redshift QA results before reporting them as finalized study findings.

## Repository organization

```text
DBeaver_making/
    preprocessing.sql
    inpatients_standardizing.sql
    hospice_admission_index.sql
    optional_check.sql
    candidates.sql
    enriching_stage_4.sql
    ART_final.sql
    Stage5_ARTPolypharmacy.sql

polypharmacy/
    1_configure_polypharmacy.R
    2_prepare_polypharmacy_inputs.R
    2.5_map_ndc11_to_atc.ps1
    n2c_mapper.py
    3_build_polypharmacy_exposures.R
    4_calculate_and_validate_polypharmacy.R
    README.md
    LICENSE-n2c.txt

1_configure_clinical_metrics.R
2_prepare_metric_patient_years.R
3_prepare_cfi_gagne_evidence.R
4_calculate_cfi.R
5_calculate_gagne.R
6_prepare_ccw30_hiv_evidence.R
7_calculate_ccw30.R
8_calculate_hiv.R
9_build_and_validate_clinical_metrics.R

consort_diagram_r.Rmd
progress_oct6.Rmd
HIVDrugAbbrev.xlsx
images/
Outputs/                   # ignored; local/restricted outputs only
```

Paths above reflect the project layout shown in the working repository. Some older script headers or `source()` statements still reference the original `Code/shareable_clinical_metrics/` folder; match those paths to your actual checkout before attempting to run the scripts. The repository is **not** a turnkey, one-command reproducible pipeline: some SQL sections are year-batched, rely on prebuilt lookup tables, and include historical exploratory statements.

## Hospice-specific processing order

The recommended dependency order is shown below. Run the **relevant statements or year batches**, not every line of each SQL file indiscriminately: several scripts contain `CREATE`, `DROP`, `DELETE`, `ALTER`, and `UPDATE` statements that operate on persistent tables.

| Order | File / environment | Role and dependencies |
| --- | --- | --- |
| 1a | `DBeaver_making/preprocessing.sql` — DBeaver | Standardize non-inpatient claims into claim-level hospice events; aggregate line-level billing, revenue, procedure, and diagnosis data. Builds `hospice_nonip_events`, then `hospice_nonip_admission_events`. |
| 1b | `DBeaver_making/inpatients_standardizing.sql` — DBeaver | Standardize inpatient claims, hospice level/place codes, and admission-type claims. Builds `hospice_inpatient_events`, then `hospice_inpatient_admission_events`. Steps 1a and 1b can be completed independently. |
| Optional | `DBeaver_making/hospice_admission_index.sql` / `optional_check.sql` — DBeaver | Reconcile admissions between source and standardized tables and investigate unmatched records. **The uploaded versions are identical audit scripts**, not separate index builders. They can be run after steps 1a–1b. |
| 2 | `DBeaver_making/candidates.sql` — DBeaver | Combine admission-event sources; select earliest eligible event per patient; assess continuous closed medical/pharmacy claims and stable insurance; derive age at admission; create `hospice_f_candidates`; identify HIV through diagnosis and qualifying pharmacy routes. |
| 3 | `DBeaver_making/enriching_stage_4.sql` — DBeaver | Add sex, race/ethnicity, primary insurance, dual eligibility, admission-date geography; apply missing-data/claims-history exclusions; derive hospice-specific CFI, frailty, Gagne, and CCW-30 values. |
| 4a | `DBeaver_making/ART_final.sql` — DBeaver | For HIV-positive patients, build valid ART fill/component intervals and daily regimen coverage; summarize 365-day ART PDC and nonadherence indicators. Requires existing ART medication-name/component lookups. |
| 4b | `polypharmacy/2_prepare_polypharmacy_inputs.R` — RStudio | Build each patient's pre-index window and save eligible paid pharmacy fills. Requires the eligible cohort and the configured index/date columns. |
| 5 | `DBeaver_making/Stage5_ARTPolypharmacy.sql` — DBeaver | Build/review the ART NDC11 exclusions from saved polypharmacy fills, including the year-batched NDC catalog; create `hospice_poly12m_art_exclusions_v2`. **Run the exclusion-building portions after R stage 2 and before R stage 3.** The same SQL file also contains later checks and EDA that depend on completed polypharmacy results. |
| 6 | `polypharmacy/2.5_map_ndc11_to_atc.ps1` — PowerShell, invoking `n2c_mapper.py` | Produce the frozen National Drug Code (NDC11)-to-Anatomical Therapeutic Chemical (ATC) class crosswalk for the exported NDC11 list. Its mapping version/policy must match the R configuration. |
| 7 | `polypharmacy/3_build_polypharmacy_exposures.R` — RStudio | Apply the mapped crosswalk and the 14 verified supplemental mappings; exclude matched ART fills except the designated Vemlidy exception; create and merge ATC3 exposure intervals. |
| 8 | `polypharmacy/4_calculate_and_validate_polypharmacy.R` — RStudio | Calculate days with at least five concurrent non-ART ATC3 classes, the polypharmacy flag, class counts, unmapped fills, and QA summaries. |
| 9 | `consort_diagram_r.Rmd` — RStudio | Generate the cohort-flow figure from the verified cohort counts; continue with QA tables, EDA, matching, and statistical modeling. |

**Order caveats:** `ART_final.sql` and polypharmacy extraction are distinct pharmacy branches; either may proceed after the required HIV/cohort tables and lookups are ready. `Stage5_ARTPolypharmacy.sql` is not entirely an initial construction script—its later blocks query already-computed polypharmacy metrics. The ART/PDC and ART/NDC exclusion scripts have year-specific SQL sections and must be reviewed before rerunning them.

### Main Redshift objects in the hospice workflow

| Object | Purpose |
| --- | --- |
| `hospice_nonip_events`, `hospice_inpatient_events` | Standardized hospice-related claim events. |
| `hospice_nonip_admission_events`, `hospice_inpatient_admission_events` | Events with qualifying admission/election billing types. |
| `hospice_candidates` | Earliest admission event and initial eligibility fields. |
| `hospice_f_candidates` | Selected eligible hospice cohort and enriched patient-level fields. |
| `hospice_hiv_dx_summary`, `hospice_hiv_rx_summary` | Diagnosis- and pharmacy-route HIV evidence. |
| `cfi_gagne_feature_matches`, `ccw30_evidence` | Hospice-specific clinical evidence used for enrichment. |
| `hiv_art_rx_fills_12m`, `hiv_art_component_fills_12m` | ART fills and component-level coverage. |
| `hiv_art_daily_coverage_12m`, `hiv_art_pdc_summary` | Daily ART coverage and patient-level PDC. |
| `hospice_poly12m_fills`, `hospice_poly12m_art_exclusions_v2` | Pre-index pharmacy fills and exclusions used for non-ART polypharmacy. |
| `hospice_poly12m_crosswalk`, `hospice_poly12m_intervals`, `hospice_poly12m_metrics` | ATC mapping, medication-class intervals, and final polypharmacy metrics (using the hospice-specific table prefix). |
| `hospice_poly12m_pipeline_state` | Workflow lineage and READY/STALE status of pharmacy extraction and enrichment. |

Most persistent hospice tables are written within the researcher's personal Redshift schema, illustrated in the scripts as `work_<username>`. The files are documentation of the working SQL sequence rather than safe-to-run-from-top-to-bottom migrations.

## Hospice-specific operational definitions

### Hospice index and cohort eligibility

- Define the index date (`T0`) as the earliest retained qualifying hospice admission/election claim event for a patient, considering both standardized source tables.
- The current admission-event SQL accepts billing types `81A`, `82A`, `812`, `822`, `811`, and `821`.
- Require age **50 or older** at hospice admission.
- Require continuous, closed medical (`MX CLOSED`) and pharmacy (`RX CLOSED`) claims coverage and stable insurance groups during the required pre-admission window.
- Exclude admissions without sufficient earlier normalized-claims history and patients missing required demographic or admission-date geography fields, as implemented in the enrichment SQL.
- Preserve one index record per patient; subsequent analyses look backward from this date.

### HIV identification: three routes

A patient is classified HIV-positive if **at least one** of the following holds by the hospice index date:

1. **Inpatient route:** At least one qualifying inpatient HIV diagnosis.
2. **Outpatient route:** At least two distinct dates with qualifying non-inpatient HIV diagnoses.
3. **Pharmacy route:** At least two distinct dates with qualifying HIV medication fills/refills. The pharmacy lookback is capped at **six years before hospice admission**, and never begins before **January 1, 2016**.

The hospice-specific pharmacy route retains valid paid claims with terminal `FINAL`/`STANDALONE` status and uses explicitly curated medication names/aliases. The script excludes specified products that may reflect pre-exposure prophylaxis (PrEP), hepatitis B treatment, boosters, or other nonqualifying use. Patients may meet multiple routes; `hiv_most_recent_date` uses the latest qualifying evidence from the route summaries. **HIV-algorithm-negative** means that the algorithm did not identify HIV, not proof that the patient is HIV-free.

**Separate implementation:** `8_calculate_hiv.R` in the shareable **2022** metric bundle uses diagnosis routes only for 2022; it is **not** the three-route hospice algorithm in `candidates.sql`.

### Claims-Based Frailty Index (CFI)

The hospice enrichment scores clinical features during the patient's pre-hospice lookback rather than a fixed calendar year. Features receive the weights from the supplied lookup, with an intercept of `0.10288`. The hospice-specific SQL assigns:

| CFI score | Frailty level |
| --- | --- |
| Below 0.25 | Nonfrail |
| 0.25 to below 0.35 | Mildly frail |
| 0.35 or above | Moderately-to-severely frail |

### Gagne Combined Comorbidity Score

Evidence of each qualifying comorbidity group contributes its supplied weight **once**. The patient-level score is the sum of group weights, with zero for patients who have no matched groups. Gagne represents comorbidity burden and is conceptually distinct from CFI-derived frailty.

### Chronic Conditions Data Warehouse (CCW-30)

Thirty chronic-condition indicators are derived from qualifying diagnosis evidence. The active qualification rules are:

| Group | Required evidence |
| --- | --- |
| 1 | At least one inpatient diagnosis |
| 2–3 | At least one inpatient diagnosis **or** at least two distinct outpatient diagnosis dates |
| 4 | At least one outpatient diagnosis |
| 5–6 | Evidence from either setting |

The shareable 2022 implementation also derives `ccw_cancer` as an additional summary of six site-specific cancers, without counting that summary as a 31st condition. Its documented benign prostatic hyperplasia (BPH) and stroke/transient ischemic attack (TIA) encounter-level exclusions are **not applied** because the normalized diagnosis source lacks a reliable claim identifier for those particular rules.

### ART adherence (HIV-positive subgroup)

`ART_final.sql` examines the **365 days preceding hospice admission**. Paid, valid pharmacy fills are linked to canonical ART names and medication components. Each component fill is clipped to the pre-hospice interval; coverage is evaluated at the patient-day level.

In the current SQL, a day counts as regimen-covered when **two or more distinct ART components** are active; the code explicitly uses the version that counts booster components. Patient-level PDC is:

```text
ART PDC = number of days with at least 2 active ART components / 365
```

The SQL creates nonadherence indicators at PDC thresholds **below 80%, 85%, and 95%**. These are operational definitions based on dispensing records, **not** evidence that medications were ingested. Patients without a qualifying mapped ART fill may have an uncalculable PDC rather than a measured value of zero. The definition and booster treatment should be discussed when interpreting results.

### Non-ART polypharmacy

The hospice-specific modified R implementation defines polypharmacy as **at least five concurrently active ATC level-3 medication classes on at least 90 total days** during the **12 calendar months before admission**. Qualifying days need not be consecutive.

- Paid fills with valid NDC11 and positive days supply may contribute when their supplied days overlap the lookback, including fills before the window that carry into it.
- Exposure intervals are clipped to the window. Multiple fills of the same ATC3 class count as **one active class per day**, with no refill stockpiling.
- The modified hospice scripts remove matched ART medication fills from polypharmacy exposure, but specifically retain Vemlidy NDC11 `61958230101` as a non-ART medication for this purpose.
- Stage 3 additionally applies **14 verified supplemental NDC-to-ATC mappings**. Unmapped fills do not add an ATC class and are reported for assessment of mapping completeness.
- The `polypharmacy/README.md` describes the original shareable implementation, which **includes ART**. For this study, consult the updated `3_build_polypharmacy_exposures.R` and `4_calculate_and_validate_polypharmacy.R` for the actual non-ART operationalization.

The mapping workflow uses product-level `ATCPROD` relationships by default. Its Python mapper records a frozen NDC11-to-ATC4 crosswalk and provenance; ATC3 is derived from the first four characters of each valid ATC4 code. Rebuilding a mapping later may produce different results. Preserve the mapping files, manifest, and version used for each analysis in an appropriately protected location.

## Separate reference workflow: Shareable 2022 Komodo Clinical Metrics

This **independent** bundle calculates CFI, Gagne, CCW-30, and diagnosis-only HIV indicators over the **January 1–December 31, 2022** calendar year. It takes an already-constructed 2022 eligible cohort and does not create hospice admissions, three-route HIV status, ART PDC, or hospice-specific polypharmacy. Keep this distinction clear when reusing functions and describing methods.

### Required inputs

Default configuration in `1_configure_clinical_metrics.R` reads:

- `work_<username>.1_2022_komodo_medicare_comparison_cohort_all_eligible`;
- `komodo_202606.normalized_dx_events`;
- `komodo_202606.normalized_procedure_events`;
- the supplied CSV lookup files under `Code/shareable_clinical_metrics/Clinical Metric Look Up Tables/` (including the CCW-30 lookups).

The eligible source must contain `patient_id`, `analysis_year`, and `index_date`, with one row per eligible patient-year. The two normalized sources have already flattened claims diagnoses/procedures; these scripts do not process raw diagnosis arrays. The referenced lookup CSVs and a valid database connection are required in the working environment.

### 2022 script order

1. `1_configure_clinical_metrics.R` — common configuration and Redshift helpers (sourced by other stages).
2. `2_prepare_metric_patient_years.R` — build the patient-year denominator and calendar-year bounds.
3. `3_prepare_cfi_gagne_evidence.R` — screen normalized codes and create CFI/Gagne feature matches.
4. `4_calculate_cfi.R` — assign CFI scores using model feature weights and intercept.
5. `5_calculate_gagne.R` — derive Gagne indicators and weighted scores.
6. `6_prepare_ccw30_hiv_evidence.R` — construct matched CCW-30 and HIV diagnosis evidence.
7. `7_calculate_ccw30.R` — apply CCW-30 qualification rules and calculate indicators/counts.
8. `8_calculate_hiv.R` — derive **2022 diagnosis-only** HIV status (one inpatient or two distinct non-inpatient diagnosis dates).
9. `9_build_and_validate_clinical_metrics.R` — join all metric results back to the source cohort and check denominators, duplicates, missingness, and rule consistency.

These stages were originally designed to be sourced individually; there is intentionally no run-all wrapper. The original helper uses a connection opened for each stage and defaults to not replacing existing output tables unless intentional replacement is configured.

### 2022 outputs

| Default Redshift table | Grain / purpose |
| --- | --- |
| `share_2022_metric_ids` | One eligible patient-year: denominator and date bounds |
| `share_2022_cfi_procedure_presence` | CFI-relevant procedure presence |
| `share_2022_cfi_gagne_dx_candidates` | Candidate diagnosis codes |
| `share_2022_cfi_feature_matches` | CFI feature matches |
| `share_2022_gagne_group_matches` | Gagne feature matches |
| `share_2022_cfi_scores` | One CFI result per eligible patient-year |
| `share_2022_gagne_scores` | Gagne group indicators, counts, and score |
| `share_2022_ccw30_matched_evidence` | Diagnosis-date/setting/condition evidence |
| `share_2022_hiv_diagnosis_evidence` | HIV diagnosis-date/setting evidence |
| `share_2022_ccw30_conditions_long` | Qualified condition-level CCW records |
| `share_2022_ccw30_condition_indicators` | Thirty flags, derived cancer flag, and count |
| `share_2022_ccw30_total_counts` | Total qualified CCW condition count |
| `share_2022_hiv_status` | Diagnosis-only annual HIV status |
| `share_2022_clinical_metrics` | Combined eligibility and metric results |

No patient-level data are exported by the provided shareable 2022 R scripts. Their QA checks assess table keys, counts, missingness, and rule consistency. Passing these programmatic checks does not by itself establish clinical validity; review code lists, eligibility, study design, and results in the authorized OHDSI Lab/Redshift environment.

## Analysis plan and interpretation

Following enrichment, the planned primary comparison is between HIV-positive and HIV-algorithm-negative **hospice patients**. The planned 1:1 individual matching uses **sex, state, and frailty level**, with conditional logistic regression for matched-pair comparisons and additional covariates considered according to the study protocol. Analyses of ART PDC are restricted to the HIV-positive subgroup for whom the measure is applicable and calculable. These analyses are described as *planned* unless corresponding model outputs have been separately executed and verified.

## Reproducibility notes

- SQL files are annotated working notebooks, not idempotent database migrations. Review existing tables, year boundaries, `DROP TABLE`, `INSERT`, and `UPDATE` statements before executing a section.
- The hospice clinical enrichment uses each patient's own pre-admission lookback, while the shareable metrics bundle uses calendar-year 2022. ART PDC uses **365 days**, and polypharmacy uses **12 calendar months**; do not silently treat these as identical windows.
- `polypharmacy/1_configure_polypharmacy.R` in the uploaded working version expects a **valid active R database connection named `con`**. This differs from the older bundled README's description of opening a new connection automatically.
- The modified polypharmacy stage 3 appends `_supp14` to the in-memory mapping version after reading its manifest. Ensure stage 4 is configured with the **matching saved effective mapping version** before running; otherwise its pipeline-state validation may reject the results.
- The ART medication aliases, component lookup, CFI/Gagne lookup CSVs, CCW-30 lookup CSVs, and verified supplemental mapping table must be available and checked before execution. Not every supporting lookup is built by the SQL files listed here.
- Keep only aggregate, disclosure-reviewed figures or results in the public repository. For exact reproducibility, preserve versioned scripts, provenance, mapping policy, input definitions, and QA logs in the approved research environment.

## Attribution

The shareable 2022 clinical-metrics and original polypharmacy bundles identify **Nemo Zhou** as their author. Hospice-specific SQL and modifications to the pharmacy workflow reflect subsequent work in this research project. The `n2c_mapper.py` adaptation references Fabrício Kury's **n2c** project; see `polypharmacy/LICENSE-n2c.txt` for its MIT license. That license should not be interpreted as automatically licensing the entire repository or the restricted underlying data.
