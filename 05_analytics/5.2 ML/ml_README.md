# Machine Learning

`05_analytics/5.2 ML` · Status: **planned**

Two questions the warehouse can already answer about the past, that models can
answer about the future.

---

## 1. Who is about to stop buying?

**Churn prediction.**

Nobody cancels an account at a bike shop, they just quietly stop coming back.
So the model learns what a customer looks like shortly before they disappear,
then flags live customers showing the same pattern.

```
Past behaviour  →  model  →  "this customer is 78% likely to lapse"
```

**What it uses:** how recently someone bought, how often, how much they spend,
how long the gaps between orders usually are, and what they browse on the site.

**Why it's useful:** a retention offer costs less than winning a new customer.
Sending it to the right 500 people beats sending it to everyone.

---

## 2. Who is worth the most over time?

**Customer lifetime value.**

Not what someone spent last month, but what they are likely to be worth over
the next year.

```
Buying pattern  →  model  →  "expected £2,400 over 12 months"
```

**Why it's useful:** it changes where the marketing budget goes. A customer who
spent £50 once and a customer who spends £50 every month look identical on a
sales report and are worth very different amounts.

---

## The two together

```
                  High value
                       │
      Protect          │        Grow
   (at risk, £££)      │    (loyal, £££)
                       │
  ─────────────────────┼─────────────────────  Churn risk
                       │
      Let go           │       Nurture
   (at risk, £)        │     (loyal, £)
                       │
                   Low value
```

Churn risk alone says who is leaving. Value alone says who matters. Together
they say **who to spend money keeping**.

---

## Approach

| | |
|---|---|
| **Churn** | Gradient boosting (LightGBM), with logistic regression as a baseline to beat |
| **Value** | BG/NBD and Gamma-Gamma, the standard pair for retail where purchases are irregular |
| **Explaining it** | SHAP, so every prediction comes with the reason behind it |

Predictions are written back into the gold layer and surfaced in Power BI, so
the marketing team sees a risk score and a value tier next to each customer
rather than a model output they have to interpret.


