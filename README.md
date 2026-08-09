# Vahan Product Analytics Case Study

## Overview

This repository contains a Product Analytics Internship case-study submission for Vahan, analyzing lead-source cohort performance, funnel conversion, and the drivers of FT (First Trip) conversion across 18,198 leads.

## Business Problem

Vahan sources gig-work candidate leads from multiple channels ("cohorts" / `lead_source`), calls them, and needs to know: 
(1) which cohorts convert best and on what metric, 
(2) how the raw data aggregates at a cohort level, and (3) what factors predict a candidate reaching FT.

## Dataset

- **18,198 rows, 19 columns**, one row per lead (`Uploaded Leads` = 1 on every row).
- **16 cohorts** (`lead_source`), each corresponding to a single upload batch, spanning **18 Jul - 6 Aug 2026**.
- **17,097 unique `candidate_phone` values**; 1,100 rows share a phone with another row, always across a *different* cohort/date (0 true same-cohort duplicates) i.e. candidates are sometimes re-targeted into a later campaign.
- 1 row has a blank `candidate_phone` (kept in all aggregates; excluded only from phone-uniqueness checks).

## Analytical Approach

Grain = one lead (candidate_phone × lead_source × upload_date). Cohort = `lead_source`. All metrics were built with auditable Excel formulas (COUNTIFS/SUMIFS) and cross-checked against equivalent SQL.

## Data Quality

| Issue | Evidence | Treatment |
|---|---|---|
| Missing `candidate_phone` | 1 row | Kept in aggregates; excluded from uniqueness checks |
| Duplicate `candidate_phone` across cohorts | 1,100 rows | Not deduplicated each row is an independent lead/business event |
| `Interested` doesn't gate OB/FT | 116/119 OB and 53/54 FT events have `Interested`=0 | Treated as a process metric only, never a funnel gate |
| Right-censored cohorts | Recent uploads show 0/low FT | Top-3 ranking restricted to cohorts ≥5 days old |
| Tiny cohorts | 5 of 16 have <5 leads | Excluded from ranking via a ≥1,000-lead minimum |

## Funnel Definition

Lead → Attempted → Connected → Interested → OB_after_upload → FT_after_upload

| Stage | Count | % of Total Leads |
|---|---|---|
| Lead | 18,198 | 100.00% |
| Attempted | 11,973 | 65.79% |
| Connected | 5,550 | 30.50% |
| Interested | 348 | 1.91% |
| OB_after_upload | 119 | 0.65% |
| FT_after_upload | 54 | 0.30% |

**Largest drop-off:** Lead → Attempted - 34.2% of all leads are never called even once, the single largest and most operationally-controllable leak in the funnel.

## Cohort Methodology

Cohorts ranked on **Lead → FT_after_upload conversion rate** (the end business outcome), filtered to leads ≥ 1,000 (excludes single-event-sized cohorts) and age ≥ 5 days since upload (excludes right-censored/immature cohorts).

## Key Metrics

| Metric | Result | Interpretation |
|---|---|---|
| Overall Attempt Rate | 65.79% | Over a third of leads never get called |
| Overall Connect Rate (of attempted) | 46.35% | More than half of attempted calls don't connect |
| Overall Lead → FT Rate | 0.30% | Extremely low base rate; expect small counts to swing cohort-level percentages |
| OB → FT Rate | 45.38% | Once onboarded, close to half eventually go FT |

## Top Performing Cohorts

| Rank | Cohort | Leads | Age (days) | FT | Lead→FT % |
|---|---|---|---|---|---|
| 1 | Single Referral > 7 days - 24th Jul | 1,500 | 12 | 14 | 0.933% |
| 2 | Khanna - 2W 26th Jul | 1,546 | 10 | 14 | 0.906% |
| 3 | PreOb-Ob Fees Paid 29th Jul (set 1) | 1,483 | 8 | 7 | 0.472% |

Both PreOb-Ob batches (set 1 and set 2, uploaded on consecutive days) show a similar, above-average FT rate, strengthening confidence that this is a genuine campaign effect rather than single-batch noise.

## Key Findings

| Finding | Evidence | Business Implication | Recommended Action |
|---|---|---|---|
| 34% of leads never attempted | 6,225 / 18,198 leads, Attempted = 0 | Largest controllable volume leak | Audit call-routing/capacity to guarantee first-attempt coverage |
| `Interested` doesn't gate conversion | 53/54 FT events have Interested=0 | Current dashboards/incentives may misread this metric | Stop treating Interested as a funnel gate; standardize tagging if kept |
| Cohort effect survives model controls | Single Referral / Khanna-2W retain positive coefficients after controlling for Attempted/Connected | Sourcing mix matters beyond just call volume | Shift incremental sourcing toward high-converting channel types |
| Attempted → Connected is the 2nd-largest leak | 35.3% of all leads lost at this step | Partly candidate-dependent, harder to move than attempt gap | Investigate call-timing optimization (needs timestamp data) |

## Conversion Drivers

Logistic regression (5-fold CV, class-weighted for the 0.3% base rate), target = `FT_after_upload`, excluding OB fields as leakage.

- **ROC-AUC: 0.798** - good ranking ability.
- **Recall: 79.6%**, **Precision: 0.7%** - expected at this event rate; use for prioritization/ranking, not hard classification.
- **Strongest positive driver:** `Attempted` (being called at all) - larger effect than any single cohort.
- **Cohort-specific lift:** Single Referral, Khanna-2W, and both PreOb-Ob batches remain positive even after controlling for call behavior.
- All relationships are **correlational, not causal**.

## Product Recommendations

1. **[Highest priority]** Close the never-attempted gap (34% of leads) - audit routing/capacity.
2. Shift sourcing mix toward Single-Referral / Khanna-2W-style channels; deprioritize zero-FT mature cohorts.
3. Stop using `Interested` as a funnel gate; standardize tagging if retained as a metric.
4. Investigate Attempted → Connected call-timing optimization (needs additional data).
5. Use the driver-model score to triage/prioritize call-center capacity.

## Assumptions & Limitations

- "Today" for cohort-age/maturity purposes = the latest `upload_date` in the file (6 Aug 2026), since no separate extraction timestamp is given.
- Only 54 FT events total - every statistic here carries meaningful sampling uncertainty.
- No cost/revenue data - cohorts are ranked on conversion rate only, not cost-efficiency.
- No call-timestamp/agent data - limits how actionable the Attempted → Connected finding can be made.
- All driver-model relationships are correlational; none should be read as causal without a controlled experiment.

## Key Takeaways

Vahan's biggest near-term opportunity is operational, not acquisition-driven: over a third of leads are never even attempted, a fully controllable gap that dwarfs any single cohort-mix improvement. Among sourcing channels, referral- and pre-qualification-based cohorts (Single Referral, Khanna-2W, PreOb-Ob Fees Paid) show a genuine, model-corroborated edge in FT conversion. The `Interested` tag, as currently captured, should not be trusted as a funnel checkpoint most conversions bypass it entirely. All findings should be validated with the outlined A/B experiments before being treated as final.
