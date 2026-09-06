# Machine Learning

`05_analytics/5.2 ML` · source: `gold.fact_sales`, `gold.dim_customers`, `gold.fact_web_events`

Status: **planned**

---

## Scope

```
1.  Churn prediction        classification
2.  Customer lifetime value probabilistic forecast
```

---

## Pipeline

```
gold views (SQL Server)
        ↓  pyodbc
feature engineering  →  rfm_features.parquet
        ↓
train / test split (time-based, not random)
        ↓
    ┌───────────────┬───────────────┐
    ↓               ↓               ↓
 baseline        model          evaluation
 (logistic)   (LightGBM)      (AUC, recall, SHAP)
    └───────────────┴───────────────┘
        ↓
scored_customers.csv  →  Power BI page
```

---

## 1. Churn

### Label

```
No cancellation event exists  →  churn must be DEFINED

churn = 1  if  days_since_last_order  >  N
N = 80th percentile of inter-purchase gap

reference date = MAX(order_date) in fact_sales   ← NOT today()
                 sales end 2026-01-28
```

### Features

| Group | Features | From |
|---|---|---|
| Recency | days since last order | `fact_sales` |
| Frequency | order count, distinct months active | `fact_sales` |
| Monetary | total spend, average order value, max order | `fact_sales` |
| Tenure | days first order → last order | `fact_sales` |
| Cadence | mean and stdev of inter-purchase gap | `fact_sales` |
| Basket | distinct categories, distinct products | `fact_sales` + `dim_products` |
| Geography | country | `dim_customers` |
| Behaviour | sessions, cart adds, conversion rate | `fact_web_events` |

```
EXCLUDED:  dim_customers.create_date
           60,379 / 60,398 sales predate it → unusable for tenure
```

### Models

```
baseline    →  Logistic Regression      interpretable floor
main        →  LightGBM / XGBoost       wins on tabular
compare     →  Random Forest            variance check
```

### Metrics

```
AUC-ROC          ranking quality
Precision/Recall churn class is imbalanced → accuracy is misleading
F1               balance point
SHAP             why, not just what  ← the business cares about this
```

---

## 2. Customer lifetime value

### Approach

```
BG/NBD          →  predicts number of future transactions
      +
Gamma-Gamma     →  predicts monetary value per transaction
      =
CLV over horizon (12 months)
```

`lifetimes` library. Standard for non-contractual retail: customers do not
cancel, they simply stop, so purchase timing is probabilistic.

### Inputs

```
per customer:
    frequency   repeat purchase count
    recency     age at last purchase
    T           age at end of observation
    monetary    average order value
```

### Alternative

```
Regression on RFM  →  predict next-12-month spend directly
                      simpler, weaker justification
```

Primary is BG/NBD. Regression kept as a comparison baseline.

---

## 3. Segmentation feeding both

```
RFM scoring (quintiles)
        ↓
Champions · Loyal · Potential · At Risk · Hibernating · Lost
        ↓
   ┌────────────────────┬────────────────────┐
   ↓                    ↓                    ↓
churn feature       CLV cohort        marketing action
```

---

## Planned files

```
05_analytics/5.2 ML/
├── README.md
├── requirements.txt              pandas, scikit-learn, lightgbm, lifetimes, shap
├── 01_extract_features.py        gold views → rfm_features.parquet
├── 02_churn_model.ipynb          EDA, label definition, training, SHAP
├── 03_clv_model.ipynb            BG/NBD + Gamma-Gamma
├── 04_score_customers.py         batch scoring → scored_customers.csv
├── models/
│   ├── churn_lgbm.pkl
│   └── clv_bgnbd.pkl
└── outputs/
    ├── rfm_features.parquet
    └── scored_customers.csv
```

---

## Build order

```
[ ]  1.  Extract RFM features from gold
[ ]  2.  Define churn window from inter-purchase distribution
[ ]  3.  Baseline logistic regression
[ ]  4.  LightGBM + hyperparameter tuning
[ ]  5.  SHAP feature importance
[ ]  6.  BG/NBD + Gamma-Gamma CLV
[ ]  7.  Score full customer base
[ ]  8.  Power BI page: churn risk + CLV tier by country
[ ]  9.  Write findings into this README
```

---

## Constraints carried from the warehouse

```
create_date         unusable for tenure          → use first order date
sales end 2026-01   churn relative to max(date)  → not today()
19 null order_dates 0.03%                        → drop from feature set
fx_rates 1 day only truncates each run           → no multi-currency CLV yet
```

---

## Serving

```
scored_customers.csv
        ↓
option A  →  load to gold.fact_customer_scores  →  Power BI direct
option B  →  read CSV in Power BI                →  simpler, no schema change
```

Option A preferred. Predictions are a business artefact and belong in gold.
