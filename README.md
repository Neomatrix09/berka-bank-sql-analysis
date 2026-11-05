# Berka Bank: SQL Analysis of Transactions and Loans

An end-to-end SQL project in MySQL on a bank dataset of **1,056,320 transactions** and **682 loans**: loading and cleaning the raw files, building validated tables, and answering three business questions.

Everything, from loading the files to the final analysis, is done in SQL (MySQL Workbench).

## Key findings

1. **Cash withdrawals spike every January.** January has roughly 3x February's volume of cash withdrawals in every full year (1994-1998), and the pattern is spread across most accounts, not driven by a few.
2. **A loan's monthly payment is just its amount divided by its duration.** This holds exactly on all 682 loans, so the payment carries no information of its own, and no interest is visible in it. Loan size rises steadily with duration (average 53,636 at 12 months, 244,451 at 60 months).
3. **Problem loans come from accounts that ran low on money before the loan.** In the 90 days before the loan was granted, 15 of the 76 loans that later ended in a problem status had an account balance that went negative. None of the 606 loans without a problem did.

## Dataset

| Table | Rows | Used for |
|---|---|---|
| `trans` | 1,056,320 | Transactions on 4,500 accounts, 1993-01-01 to 1998-12-31 |
| `loan` | 682 | One loan per account, granted 1993-07-05 to 1998-12-08 |

The other six files in the dataset (`account`, `client`, `disp`, `order`, `card`, `district`) were not needed for these questions. The data files are not included in this repo. The dataset's documentation page I used for column definitions: https://webpages.charlotte.edu/mirsad/itcs6265/group1/domain.html

## Approach

For each table I followed the same steps:

1. **Load raw.** Every column goes into a text-only staging table, so nothing is changed or rejected on the way in.
2. **Profile in SQL.** Check lengths, distinct values, number formats, date ranges, blanks and unexpected characters, and let the findings decide the column types.
3. **Build a typed table.** Real `DATE`, `INT` and `DECIMAL` columns, with the raw table kept untouched.
4. **Validate.** Row counts, matching totals between raw and typed tables, NULL counts and a spot check against a line read straight from the file.
5. **Analyze.**

### Data quality decisions

| Issue found | Decision |
|---|---|
| The files use Windows line endings (`\r\n`). A first load with `\n` left a hidden character at the end of the last field and broke rows whose last value was in quotes. Diagnosed in SQL by loading the raw lines into a one-column table. | Load with `LINES TERMINATED BY '\r\n'`. Row count then matched the file exactly. |
| `k_symbol` has two blank-looking values: an empty string (481,881 rows) and a single space (53,433 rows). | Kept as they are. The column was not needed for the analysis. |
| `bank` and `account` (the partner's bank and account) are blank on about 74% of rows. | Blanks become `NULL` and the rows are kept. |
| `account` holds a lone `0` on 21,881 rows. | Treated as "no account" and set to `NULL`. |
| Dates are `YYMMDD`. | Converted with `STR_TO_DATE('%y%m%d')`. Two-digit years 93-98 read as 1993-1998, which fits the documented range. |
| The documentation lists a `disp_id` column for loans, but the loan file has none. | Followed the file. |

## Analysis

### Question 1: How is transaction activity spread over time?

- Activity grows every year. 1993 starts from near zero, growth to 1997 comes mostly from more active accounts, and growth in 1998 comes mostly from more activity per account.
- January is unusually busy every year. Comparing January with February 1997, the gap is 13,858 transactions, and the `VYBER` operation (withdrawal in cash) accounts for 13,395 of it, about 97%.
- Cash withdrawals in January are about three times February's, every full year:

| Year | Jan | Feb | Jan / Feb |
|---|---|---|---|
| 1994 | 5,647 | 1,978 | 2.9 |
| 1995 | 9,884 | 2,982 | 3.3 |
| 1996 | 13,212 | 4,282 | 3.1 |
| 1997 | 20,078 | 6,683 | 3.0 |
| 1998 | 25,662 | 8,311 | 3.1 |

- It is broad, not concentrated. In 1997, 2,803 accounts had more transactions in January than February, 373 had more in February, and 1,320 were equal. The ten biggest gaps are only 11-13 transactions each.
- Within a month, the last day carries a spike (about 3,300 cash withdrawals in both January and February 1997, growing smoothly through the year). January's surplus is on ordinary days: about 561 per day against 123-219 in February-November.
- `k_symbol` does not explain January: the surplus sits in its blank group.

### Question 2: How do loan size and repayment relate?

- Loan duration takes five values (12, 24, 36, 48, 60), spread fairly evenly (131, 138, 130, 138, 145 loans).
- Loan amount rises with duration, while the monthly payment stays about the same:

| Duration | Loans | Avg amount | Avg monthly payment |
|---|---|---|---|
| 12 | 131 | 53,636 | 4,469.63 |
| 24 | 138 | 99,218 | 4,134.08 |
| 36 | 130 | 144,048 | 4,001.34 |
| 48 | 138 | 205,593 | 4,283.18 |
| 60 | 145 | 244,451 | 4,074.18 |

- `payments x duration = amount` on all 682 loans (largest gap 0.00), so the payment is derived and shows no interest. The check also showed that duration is measured in months.
- Loan status is a snapshot. Finished contracts (A, B) all end by 28 December 1998 and running ones (C, D) all end on or after 3 January 1999, so the snapshot sits at about the end of 1998.

| Status | Meaning | Loans |
|---|---|---|
| A | Finished, no problems | 203 |
| B | Finished, loan not paid | 31 |
| C | Running, OK so far | 403 |
| D | Running, client in debt | 45 |

### Question 3: Do accounts behind problem loans look different before the loan?

First I checked that all 682 loan accounts exist in `trans` (they do), then compared the groups on what the account looked like before the loan was granted.

- **Activity is similar.** Transactions per 30 days of history were 5.8 (A), 5.2 (B), 5.7 (C) and 5.5 (D). B's raw count was lower mostly because its accounts had a shorter history (297 days against 377-416).
- **Balances are not.** Using the 90 days before each loan:

| Status | Loans | Avg of lowest balance | Went negative |
|---|---|---|---|
| A | 203 | 25,345 | 0 |
| C | 403 | 24,902 | 0 |
| B | 31 | 15,541 | 3 (9.7%) |
| D | 45 | 8,700 | 12 (26.7%) |

Every loan whose account went negative is in B or D. But a negative balance was seen in only 15 of the 76 problem loans, so most problem loans showed no such warning.

## Limitations

- This is association, not causation. The balance is measured before the loan and the status at the end of 1998, which gives an order in time, but it does not show that low balances cause problems.
- Groups B (31 loans) and D (45) are small, so percentages move a lot with a few loans.
- The 90-day window and the use of averages are my choices, and I did not test other window lengths. Averages of averages are a crude summary.
- Account history is measured from each account's first transaction in the data, and the data starts in January 1993, so older accounts look younger than they were.
- The cause of the January spike in cash withdrawals is not explained by this data.
- Only two of the eight tables were used.

## SQL techniques used

Staging tables and `LOAD DATA LOCAL INFILE`, `GROUP BY` and conditional aggregation (`SUM(condition)`), subqueries in `FROM`, `LEFT JOIN` with date conditions in `ON`, `DISTINCT` in joins, `REGEXP` format checks, `STR_TO_DATE`, `DATE_ADD`/`DATE_SUB`/`DATEDIFF`/`LAST_DAY`, `CAST`, `NULLIF`, `HEX` and string functions for diagnosing file problems.

## How to reproduce

1. Use MySQL 8 and create a database called `berka`.
2. Download the dataset and put the CSV files in a folder.
3. Enable `local_infile` on both the server (`SET GLOBAL local_infile = 1;`) and the client connection (in MySQL Workbench: connection settings, Advanced, add `OPT_LOCAL_INFILE=1`).
4. Edit the file paths in `sql/berka_sql_project.sql` and run it section by section (not all at once: the setup sections drop and recreate tables).

## Repo contents

```
README.md
sql/berka_sql_project.sql    every query, in order, with comments
```
