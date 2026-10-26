# Fraud Monitor: Financial Transactions Fraud Analysis

An end-to-end analytics project on **6.36 million mobile-money transactions**: data modelling in **PostgreSQL**, analytical SQL views, and a 5-page interactive **Power BI** dashboard that answers one question: *where is fraud happening, how big is it, and is the existing alert system catching it?*

**Tools:** PostgreSQL · SQL · Power BI · DAX · Data Modeling

---

## Key Findings

| # | Finding | Evidence |
|---|---------|----------|
| 1 | **Fraud is confined to two transaction types:** `TRANSFER` and `CASH_OUT`. | All 8,213 fraud cases fall in these two types; the other three types have none. |
| 2 | **TRANSFER is about 4x riskier per transaction than CASH_OUT.** | Fraud rate 0.77% (TRANSFER) vs 0.18% (CASH_OUT). |
| 3 | **Fraud transactions are about 8x larger than normal ones.** | Average fraud amount 1.47M vs 178K for normal transactions; the largest cases hit the 10M cap. |
| 4 | **Large amounts carry the highest risk.** | Fraud rate is about 2% for transactions above 1M, and near zero for small amounts. |
| 5 | **The existing alert system is almost blind.** | It flagged only **16 of 8,213** fraud cases (**0.19%** detection rate), all of them TRANSFER; it never fired on CASH_OUT, which holds about half of all fraud. It raised **zero false alarms**, so the rules are precise but far too narrow. |
| 6 | **Fraud empties the sender's account.** | About **98%** of fraud transactions drain the sender's balance to zero. |
| 7 | **A zero balance at the destination is a strong signal.** | Fraud is roughly 10x more likely when the destination account has a zero balance. |
| 8 | **Sender balance mismatch is not a fraud signal.** | Fraud rate is higher where balances reconcile than where they do not. |
| 9 | **Fraud is spread evenly across the day.** | Night hours (0-5 AM) hold 25% of fraud, exactly their share of the day (6 of 24 hours). The night *rate* looks high only because overall night volume is low. |
| 10 | **No account is reused.** | Maximum 1 fraud transaction per account, so blocklists on repeat accounts would not help. |

### Recommendations
- Extend the alert rules to **CASH_OUT**, which currently has zero coverage.
- Add rules for **account-emptying transfers** and **zero-balance destinations**, especially for **high-value** transactions.
- Prioritise review of transactions **above 1M**, where the fraud rate is highest.
- Do not rely on time-of-day or repeat-account rules, since the data shows fraud is spread evenly and accounts are not reused.

---

## Dashboard (5 pages)

| Page | Purpose |
|------|---------|
| **Overview** | Headline KPIs (total transactions, total amount, fraud count, fraud amount, fraud rate), daily fraud trend, fraud by type and time of day. |
| **Patterns** | Hour-by-day fraud heatmap, fraud rate by type and by hour. |
| **Amounts** | Fraud vs normal amounts, amount buckets, fraud rate by bucket, largest cases. |
| **Detection** | Detection rate, detected vs missed fraud, false alarms, confusion-style matrix, the 16 caught cases. |
| **Risk** | Account-depletion, destination zero-balance and balance-mismatch signals, risky senders and receivers. |

Slicers for **transaction type** and **week** are available on every page.

<!-- Add screenshots to /images and keep these paths -->
![Overview](images/1_overview.png)
![Patterns](images/2_patterns.png)
![Amounts](images/3_amounts.png)
![Detection](images/4_detection.png)
![Risk](images/5_risk.png)

---

## Data Model

A **star schema** built in PostgreSQL:

- **`fact_transactions`**: amount, balances (origin and destination, before and after), `is_fraud`, `is_flagged_fraud`, and keys to the dimensions
- **`dim_customers`**: account number, customer ID, customer type
- **`dim_time`**: step, day number, hour of day, time of day
- **`dim_transaction_type`**: type ID, type name

![Data model](images/6_data_model.png)

### Analytical SQL views
The analysis was done in SQL, and each view feeds a dashboard page:

`vw_kpi_overview` · `vw_fraud_by_type` · `vw_amount_buckets` · `vw_fraud_signals` · `vw_detection_matrix` · `vw_detection_by_type` · `vw_fraud_transactions` · `vw_risky_accounts` · `vw_risky_receivers`

DAX measures (average fraud amount, average normal amount, fraud-to-normal ratio, bucket fraud rate, and others) are kept in a dedicated `_Measure` table.

![SQL views](images/7_sql_views.png)

---

## Dataset

- **Source:** [https://www.kaggle.com/datasets/ealaxi/paysim1]
- **Size:** about 6.36 million transactions, 8,213 labelled as fraud
- **Note:** this is a **synthetic** dataset that simulates mobile-money transactions, so findings illustrate analytical method rather than real-world fraud rates.

## Repository Structure

```
├── README.md
├── sql/            # table creation, star schema, analytical views
├── powerbi/        # .pbit template (no data) + PDF export of the dashboard
└── images/         # dashboard and data model screenshots
```

## How to Reproduce
1. Create the database and load the raw dataset into PostgreSQL.
2. Run the scripts in `sql/` to build the star schema and the analytical views.
3. Open `powerbi/*.pbit` in Power BI Desktop, enter your PostgreSQL connection details when prompted, and refresh the data. (The full `.pbix` is about 700 MB because it embeds the data, so only the data-free template is included here.)

## Author
**Batool Abd Alrazag Hamed**:  Data Analyst
[LinkedIn](https://www.linkedin.com/in/batool-abd-alrzag-ab472424a) · batolabdo9@gmail.com