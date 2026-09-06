# Data Catalog: Gold Layer

## Overview

The gold layer is the business-facing representation of the warehouse. It is modelled as a star
schema: four fact tables sharing four conformed dimensions, plus a security dimension used only for
row-level security and a convenience view for FX reporting.

Every gold object is a **view** over the silver layer, with one exception: `gold.dim_date` is a
physical table, because it has no source system and is generated once inside the warehouse.

Surrogate keys are generated with `ROW_NUMBER()` inside each dimension view, so warehouse keys stay
independent of source system identifiers. `ROW_NUMBER()` returns `BIGINT`, which is why the key
columns are `BIGINT` rather than `INT`.

| Object | Type | Grain | Rows |
|---|---|---|---|
| `gold.dim_date` | Table | One calendar day | 7,670 |
| `gold.dim_customers` | View | One customer | 18,484 |
| `gold.dim_products` | View | One current product | 295 |
| `gold.dim_currency` | View | One currency | 5 |
| `gold.dim_security` | View | One user and country grant | 12 |
| `gold.fact_sales` | View | One order line | 60,398 |
| `gold.fact_inventory` | View | One product, warehouse and day | 8,850 |
| `gold.fact_fx_rates` | View | One currency pair on one day | varies by run |
| `gold.fact_web_events` | View | One clickstream event | varies by run |
| `gold.vw_fx_rates_readable` | View | Reporting view over `fact_fx_rates` | varies by run |

---

## 1. gold.dim_date

**Purpose:** The shared calendar every fact joins to. Generated with a recursive CTE covering
2015-01-01 to 2035-12-31.

**Type:** Table. It is the only gold object that is not a view, because no source system supplies a
calendar.

**Source:** None. Generated in `ddl_gold_dim_date.sql`.

**Grain:** One row per calendar day.

| Column | Data type | Description |
|---|---|---|
| `date_key` | INT | Primary key. The date as an integer in `YYYYMMDD` form, for example `20251009`. Three of the four fact tables join on this column. |
| `full_date` | DATE | Alternate key. The same date as a real DATE value. `fact_sales` joins on this column, and it is the column marked as the date column when the table is registered as a date table in the reporting layer. |
| `year` | INT | Four digit calendar year. |
| `month` | INT | Month number, 1 to 12. |
| `month_name` | NVARCHAR(30) | Full month name, for example `January`. |
| `day` | INT | Day of month, 1 to 31. |
| `quarter` | INT | Calendar quarter, 1 to 4. |
| `weekday_name` | NVARCHAR(30) | Full weekday name, for example `Thursday`. |
| `is_weekend` | INT | 1 when the day is Saturday or Sunday, otherwise 0. |

**Note:** The table carries both an integer key and a real date because they serve different
consumers. The integer joins fast and is what the facts carry. The DATE value is what time
intelligence functions need in order to understand what "previous year" means.

---

## 2. gold.dim_customers

**Purpose:** Customer master, combining the CRM record with demographic and geographic attributes
held in the ERP.

**Source:** `silver.crm_cust_info` left joined to `silver.erp_cust_az12` and `silver.erp_loc_a101`,
both on the customer key.

**Grain:** One row per customer.

| Column | Data type | Description |
|---|---|---|
| `customer_key` | BIGINT | Primary key. Surrogate key generated in this view, ordered by `customer_id`. |
| `customer_id` | INT | The CRM system's own numeric identifier for the customer. Natural key. |
| `customer_number` | NVARCHAR(50) | The CRM alphanumeric customer reference, for example `AW00018775`. Used to join to the ERP tables. |
| `first_name` | NVARCHAR(50) | Customer first name, trimmed of leading and trailing whitespace in silver. |
| `last_name` | NVARCHAR(50) | Customer surname, trimmed in silver. |
| `country` | NVARCHAR(50) | Country of residence, sourced from the ERP location table. Standardised in silver, so `DE` becomes `Germany` and both `US` and `USA` become `United States`. Blank values become `n/a`. |
| `marital_status` | NVARCHAR(50) | `Married`, `Single` or `n/a`. Decoded in silver from the single character source codes `M` and `S`. |
| `gender` | NVARCHAR(50) | `Male`, `Female` or `n/a`. The CRM value wins where it is populated; otherwise the ERP value is used. |
| `birthdate` | DATE | Date of birth, from the ERP. Values in the future are nulled in silver. Deliberately **not** shifted by the date rebase applied to sales, because shifting an attribute date would change every customer's age. |
| `create_date` | DATE | The date the customer record was created in the CRM. See the data quality note below before using this column. |

**Data quality note on `create_date`.** Source create dates run from October 2025 to January 2026,
while sales transactions run from December 2022 to January 2026 after the date rebase. The two
source files were generated independently, so 60,379 of 60,398 sales rows predate their customer's
create date. This column is therefore unsafe for customer tenure, cohort analysis or new customer
counts. Derive those from the customer's first order date in `fact_sales` instead.

---

## 3. gold.dim_products

**Purpose:** Product catalogue with category hierarchy, filtered to currently active products.

**Source:** `silver.crm_prd_info` left joined to `silver.erp_px_cat_g1v2` on category id, filtered
to `prd_end_dt IS NULL`.

**Grain:** One row per current product. The source holds 397 historical product versions; the end
date filter reduces this to the 295 currently active.

| Column | Data type | Description |
|---|---|---|
| `product_key` | BIGINT | Primary key. Surrogate key generated in this view, ordered by start date then product key. |
| `product_id` | INT | The CRM system's own numeric product identifier. Natural key. |
| `product_number` | NVARCHAR(50) | Product code with the category prefix stripped, for example `FR-R92B-58`. Silver takes this from position 7 of the raw `prd_key`. This is the column the OLTP inventory feed and the clickstream feed join on. |
| `product_name` | NVARCHAR(50) | Descriptive product name including type, colour and size. |
| `category_id` | NVARCHAR(50) | Category identifier derived in silver from the first five characters of the raw product key, with the hyphen replaced by an underscore, for example `CO_RF`. Joins to the ERP category table. |
| `category` | NVARCHAR(50) | Top level classification, for example `Bikes` or `Components`. |
| `subcategory` | NVARCHAR(50) | Second level classification, for example `Road Frames`. |
| `maintenance` | NVARCHAR(50) | Whether the product requires maintenance. `Yes`, `No` or `n/a`. |
| `cost` | INT | Base cost of the product in whole currency units. Nulls in the source become 0 in silver. |
| `product_line` | NVARCHAR(50) | Product line, decoded in silver from single character codes: `Mountain`, `Road`, `Touring`, `Other Sales` or `n/a`. |
| `start_date` | DATE | The date the product version became active. Shifted forward twelve years in silver, matching the rebase applied to sales dates so the catalogue timeline stays consistent with the transactions referencing it. |

**Note on the end date filter.** `prd_end_dt` is not exposed in gold. It is computed in silver as
`LEAD(prd_start_dt) - 1` partitioned by product key, so each version ends the day before its
successor begins and the current version has a null end date. That null is what this view filters
on. The structure is in place for a Type 2 slowly changing dimension; gold currently exposes only
the current version.

---

## 4. gold.dim_currency

**Purpose:** The five currencies the FX feed covers.

**Source:** None. A hardcoded list inside the view, because no source system supplies a currency
reference.

**Grain:** One row per currency.

| Column | Data type | Description |
|---|---|---|
| `currency_key` | BIGINT | Primary key. Surrogate key generated in this view, ordered by currency code. |
| `currency_code` | VARCHAR(3) | ISO 4217 three letter code: `AUD`, `CAD`, `EUR`, `GBP`, `USD`. |
| `currency_name` | VARCHAR(20) | Full currency name, for example `British Pound`. |

**Note:** This dimension is joined twice by `fact_fx_rates`, once as the base currency and once as
the target. That is a role-playing dimension. In the reporting layer the target relationship is
active and the base relationship is inactive.

---

## 5. gold.dim_security

**Purpose:** Maps users to the countries whose data they are permitted to see. Consumed only by the
row-level security rule in the reporting layer.

**Source:** None. A hardcoded list inside the view.

**Grain:** One row per user and country grant. A user with access to several countries has several
rows.

| Column | Data type | Description |
|---|---|---|
| `user_email` | VARCHAR(40) | The user's login email. Matched against the identity of whoever opens the report. |
| `user_name` | VARCHAR(20) | Display name, for documentation only. Not used by the security rule. |
| `job_role` | VARCHAR(30) | `Location Marketing Manager` or `Global Marketing Manager`. Documentation only. |
| `country` | VARCHAR(20) | A country the user is permitted to see. Matched against `dim_customers.country`. |

**Note:** This is a security bridge, not a dimension of any fact table. It joins to
`dim_customers.country`, and the filter cascades from there to `fact_sales` and `fact_web_events`.
Six regional managers hold one country each; one global manager holds six rows, one per country,
which is how unrestricted access is expressed without a second role. `fact_inventory` and
`fact_fx_rates` are deliberately left unsecured, since warehouse stock and exchange rates are not
country sensitive.

---

## 6. gold.fact_sales

**Purpose:** Sales transactions at order line level. The primary fact table of the warehouse.

**Source:** `silver.crm_sales_details`, left joined to `dim_products` on product number and to
`dim_customers` on customer id to resolve surrogate keys.

**Grain:** One row per line on one order. `order_number` repeats across the lines of a multi-item
order.

| Column | Data type | Description |
|---|---|---|
| `order_number` | NVARCHAR(50) | The sales order reference, for example `SO68055`. Repeats across the lines of the same order, so it is not a primary key. Kept in the fact as a degenerate dimension because a lookup table holding only an order number would add nothing. |
| `product_key` | BIGINT | Foreign key to `dim_products`. |
| `customer_key` | BIGINT | Foreign key to `dim_customers`. |
| `order_date` | DATE | Foreign key to `dim_date.full_date`. The date the order was placed. This carries the active date relationship in the reporting layer, because revenue by month conventionally means the month the order was placed. |
| `shipping_date` | DATE | Foreign key to `dim_date.full_date`. The date the order shipped. Inactive relationship. |
| `due_date` | DATE | Foreign key to `dim_date.full_date`. The date payment fell due. Inactive relationship. |
| `sales_amount` | INT | Line value in whole currency units. Recalculated in silver as `quantity × ABS(price)` wherever the source value is null, non-positive, or disagrees with that product. |
| `quantity` | INT | Units ordered on this line. |
| `price` | INT | Unit price in whole currency units. Derived in silver as `sales / NULLIF(quantity, 0)` wherever the source value is null or non-positive. The `NULLIF` prevents a divide by zero rather than trapping the error afterwards. |

**Date rebase.** Order, shipping and due dates were shifted forward twelve years in the silver
layer. The source transactions run 2010 to 2014 while the inventory, FX and clickstream feeds sit in
2026, which made cross-fact analysis impossible. Shifting by whole years keeps months and
seasonality intact, so October remains October, and lands the history at 2022-12-29 to 2026-01-28,
inside the range of `dim_date` and adjacent to the other three facts. This is a documented
transformation, commented in `proc_load_slv_crm_erp.sql`, not a cleansing step.

**Null order dates.** 19 rows of 60,398 have malformed source order dates, either zeroes or values
of the wrong length, and are nulled in silver. At 0.03 percent this is immaterial. They are left as
null rather than given a sentinel date, because no date value honestly means "unknown".

**No date key.** This is the only fact table that carries real dates rather than an integer
`date_key`, which is why it joins `dim_date` on the alternate key. The other three facts carry
`date_key` and join on the primary key. Deriving three date key columns in silver would make the
model consistent and is noted in the project roadmap.

---

## 7. gold.fact_inventory

**Purpose:** Daily stock snapshots by product and warehouse.

**Source:** `silver.inventory`, left joined to `dim_products` on product number.

**Grain:** One row per product, per warehouse, per snapshot date. Currently 295 products across six
UK warehouses over five days.

| Column | Data type | Description |
|---|---|---|
| `product_key` | BIGINT | Foreign key to `dim_products`. |
| `date_key` | INT | Foreign key to `dim_date`. Derived in silver from `snapshot_date` using `CAST(CONVERT(VARCHAR(8), snapshot_date, 112) AS INT)`. |
| `warehouse` | NVARCHAR(50) | Warehouse location: London, Manchester, Edinburgh, Glasgow, Cardiff or Belfast. Held in the fact as a degenerate dimension, since the six values carry no attributes of their own. A `dim_warehouse` would be warranted if region, capacity or manager were ever added. |
| `stock_quantity` | INT | Units on hand at that warehouse on that date. |
| `reorder_level` | INT | The stock level at which the product should be reordered. |

**Note on the source.** These snapshots come from `BikeShopOLTP`, a separate operational database
read cross-database by the bronze layer. That database holds its own product catalogue loaded from
the CRM extract, so it does not depend on the warehouse it feeds. Stock quantities are randomised;
this is a simulated operational system, not real inventory data.

---

## 8. gold.fact_fx_rates

**Purpose:** Daily exchange rates between currency pairs.

**Source:** `silver.fx_rates`, left joined twice to `dim_currency` to resolve base and target
currency keys.

**Grain:** One row per currency pair, per rate date.

| Column | Data type | Description |
|---|---|---|
| `date_key` | INT | Foreign key to `dim_date`. Derived in silver from `rate_date`. |
| `base_currency_key` | BIGINT | Foreign key to `dim_currency`. The currency being converted from. Currently always GBP. Inactive relationship in the reporting layer. |
| `target_currency_key` | BIGINT | Foreign key to `dim_currency`. The currency being converted to. Active relationship, since the useful question is what the GBP to USD rate was rather than what the base currency was. |
| `exchange_rate` | DECIMAL(18,6) | Units of target currency per one unit of base currency. |

**Note on history.** `fetch_fx_rates.py` truncates the bronze table on every run, so this fact holds
a single day of rates. Switching the script to append would build a rate history and unlock trend
analysis and multi-currency revenue restatement. Noted in the project roadmap.

---

## 9. gold.fact_web_events

**Purpose:** Clickstream events, supporting funnel and conversion analysis.

**Source:** `silver.web_events`, left joined to `dim_products` on product number and to
`dim_customers` on customer id.

**Grain:** One row per clickstream event.

| Column | Data type | Description |
|---|---|---|
| `event_id` | BIGINT | Primary key. Generated by the bronze table's IDENTITY column and carried through unchanged. This is the only fact table in the model with a single column primary key. |
| `date_key` | INT | Foreign key to `dim_date`. Derived in silver from `event_timestamp`. |
| `event_timestamp` | DATETIME2 | The exact moment the event occurred. |
| `session_id` | NVARCHAR(50) | Groups events belonging to one browsing session. Held in the fact as a degenerate dimension. Used for session counts and funnel analysis within a session. |
| `event_type` | NVARCHAR(30) | One of `page_view`, `search`, `product_view`, `add_to_cart` or `purchase_click`. These are the funnel stages. |
| `product_key` | BIGINT NULL | Foreign key to `dim_products`. Null on events that reference no product, such as a homepage view or a search. |
| `customer_key` | BIGINT NULL | Foreign key to `dim_customers`. Null on anonymous sessions, which are roughly 70 percent of traffic by design. |
| `search_term` | NVARCHAR(100) NULL | The text entered on a search event. Null on all other event types. |

**Note on nulls.** The nullable foreign keys are intentional. An anonymous visitor viewing the
homepage has neither a customer nor a product. Those rows join to a blank row on the dimension side
and appear as `(Blank)` in report slicers. A funnel built on this fact therefore counts sessions
reliably but customers only from the point at which a visitor identifies themselves.

---

## 10. gold.vw_fx_rates_readable

**Purpose:** Convenience view exposing FX rates with currency codes rather than surrogate keys, for
ad-hoc SQL. Not part of the star schema and not loaded into the reporting model, where the currency
codes are reached through `dim_currency` instead.

**Source:** `gold.fact_fx_rates` joined to `gold.dim_currency` twice.

**Grain:** One row per currency pair, per rate date.

| Column | Data type | Description |
|---|---|---|
| `date_key` | INT | The rate date as an integer in `YYYYMMDD` form. |
| `base_currency` | VARCHAR(3) | Base currency code, for example `GBP`. |
| `target_currency` | VARCHAR(3) | Target currency code, for example `USD`. |
| `exchange_rate` | DECIMAL(18,6) | Units of target currency per one unit of base currency. |

---

## Key conventions

**Primary key.** A surrogate key generated inside the dimension view with `ROW_NUMBER()`. Every
dimension has exactly one. `fact_web_events` also has one, inherited from bronze.

**Alternate key.** A column that is unique and could serve as the primary key, but was not chosen.
`dim_date.full_date` is the only one, and it is the column `fact_sales` joins on.

**Foreign key.** A column pointing at another table's primary key. All fact tables carry these; no
dimension does.

**Degenerate dimension.** An attribute held in a fact table with no lookup table behind it, because
building one would add nothing. `order_number`, `session_id` and `warehouse` are the three in this
model.

**Surrogate over natural.** Dimensions expose both the warehouse key and the source system
identifier, for example `customer_key` alongside `customer_id`. Facts reference the surrogate, so a
change to a source system's identifier scheme cannot break warehouse relationships.
