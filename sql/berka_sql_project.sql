-- ============================================================================
--  BERKA BANK PROJECT  (MySQL, database: berka)
--  Every query from the project, in the order we ran them, with comments.
--
--  HOW TO USE
--   * In every new query tab, run   USE berka;   first, then check with
--     SELECT DATABASE();   (a tab can default to another schema).
--   * Run ONE statement at a time: highlight it, then use the "run current
--     statement" button (the second lightning bolt in MySQL Workbench).
--   * Do NOT run the whole file at once. Parts 1.1, 1.2, 1.4, 3.1, 3.2 and 3.4
--     DROP and recreate tables (marked CAUTION), and the LOAD statements must
--     be run once only. Once the tables exist, skip those sections.
--   * A green tick does not prove success. Always check the row count.
--   * A few exploratory queries are rewritten here in a cleaner form. The
--     logic is the same as what we ran. Sections marked (rebuilt) are rebuilt
--     from notes, so compare their output with what you expect.
--
--  WORKFLOW USED THROUGHOUT
--   raw table (all text) -> profile in SQL -> typed table designed from what
--   we observed -> validate (counts, totals, spot check) -> analysis
--
--  DATA DICTIONARY (from the dataset documentation)
--   trans.type     PRIJEM = credit, VYDAJ = debit (withdrawal)
--   trans.operation  VYBER = withdrawal in cash, VYBER KARTOU = credit card
--                    withdrawal, VKLAD = credit in cash, PREVOD Z UCTU =
--                    collection from another bank, PREVOD NA UCET =
--                    remittance to another bank
--   trans.k_symbol POJISTNE insurance payment, SLUZBY payment of statement,
--                  UROK interest credited, SANKC. UROK sanction interest if
--                  negative balance, SIPO household payment, DUCHOD old-age
--                  pension, UVER loan payment
--   trans.balance  balance of the account AFTER the transaction
--   trans.bank / trans.account  bank and account of the PARTNER
--   loan.date      date the loan was granted (YYMMDD)
--   loan.payments  monthly payments on loan
--   loan.status    A finished, no problems | B finished, loan not paid
--                  C running, OK thus far  | D running, client in debt
-- ============================================================================


-- ============================================================================
-- 0. SETUP
-- ============================================================================
CREATE DATABASE IF NOT EXISTS berka;
USE berka;

-- LOAD DATA LOCAL INFILE must be allowed on BOTH the server and the client
-- connection. If you get error 3948 ("Loading local data is disabled"):
--   server:  SET GLOBAL local_infile = 1;     (resets when MySQL restarts)
--   client:  in MySQL Workbench, edit the connection, Advanced tab, Others:
--            OPT_LOCAL_INFILE=1
-- SHOW VARIABLES LIKE 'local_infile';          -- must show ON

-- Folder with the CSV files (semicolon separated, Windows line endings).
-- Replace the path in every LOAD statement below with your own:
--   /Users/abinashkanagalingam/Downloads/berca/


-- ============================================================================
-- PART 1. TRANS (the 1,056,320-row transactions file)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1.1  Raw staging table: every column is text, so nothing is changed or
--      rejected while loading. We profile the real values before typing.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS trans_raw;      -- CAUTION: deletes the table
CREATE TABLE trans_raw (
    trans_id   VARCHAR(20),
    account_id VARCHAR(20),
    `date`     VARCHAR(20),
    `type`     VARCHAR(50),
    operation  VARCHAR(50),
    amount     VARCHAR(30),
    balance    VARCHAR(30),
    k_symbol   VARCHAR(50),
    bank       VARCHAR(20),
    account    VARCHAR(30)
);

-- If you ever need to reload from scratch (CAUTION: empties the table):
-- TRUNCATE TABLE trans_raw;

-- KEY LESSON: the file uses Windows line endings (CR+LF, i.e. '\r\n').
-- Our first load used '\n', which left a hidden CR (character code 13) at the
-- end of the last field and broke rows whose last value was in quotes.
LOAD DATA LOCAL INFILE '/Users/abinashkanagalingam/Downloads/berca/trans.csv'
INTO TABLE trans_raw
FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES;                      -- skip the header line

-- Check: must return 1,056,320 (1,056,321 file lines minus the header)
SELECT COUNT(*) FROM trans_raw;
SELECT COUNT(DISTINCT trans_id) FROM trans_raw;   -- also 1,056,320

-- ----------------------------------------------------------------------------
-- 1.2  Diagnosing the load problem (kept for reference)
--      Idea: load the file one line per row into a single text column, then
--      inspect the raw lines with SQL only.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS trans_lines;    -- CAUTION: deletes the table
CREATE TABLE trans_lines (
    line_no INT AUTO_INCREMENT PRIMARY KEY,
    line    TEXT
);

-- A tab as the field separator means the whole line lands in one column.
-- '\n' (not '\r\n') is used here on purpose so the hidden CR stays visible.
LOAD DATA LOCAL INFILE '/Users/abinashkanagalingam/Downloads/berca/trans.csv'
INTO TABLE trans_lines
FIELDS TERMINATED BY '\t' ESCAPED BY ''
LINES TERMINATED BY '\n'
(line);

SELECT COUNT(*) FROM trans_lines;    -- 1,056,321 lines (header + data)

-- Suspect 1: extra semicolons. Every line should have exactly 9.
SELECT LENGTH(line) - LENGTH(REPLACE(line, ';', '')) AS semicolons,
       COUNT(*) AS n_lines
FROM trans_lines
GROUP BY LENGTH(line) - LENGTH(REPLACE(line, ';', ''));

-- Suspect 2: unbalanced quote marks. Counts should all be even.
SELECT LENGTH(line) - LENGTH(REPLACE(line, '"', '')) AS quote_marks,
       COUNT(*) AS n_lines
FROM trans_lines
GROUP BY LENGTH(line) - LENGTH(REPLACE(line, '"', ''));

-- Suspect 3: backslashes (CHAR(92) is the backslash). We found none.
SELECT COUNT(*) AS lines_with_backslash
FROM trans_lines
WHERE LOCATE(CHAR(92), line) > 0;

-- First data line that contains a quote (the header is line 1, so skip it).
-- We found line 17, the first row where the failure showed up.
SELECT MIN(line_no) AS first_quoted_data_line
FROM trans_lines
WHERE line_no > 1 AND line LIKE '%"%';

-- The cause: does every line end with character code 13 (CR)? Yes, all of them.
SELECT SUM(RIGHT(line, 1) = CHAR(13)) AS ends_with_code13,
       COUNT(*)                       AS n_lines
FROM trans_lines;

-- Fix applied: LINES TERMINATED BY '\r\n' in the load above.
-- After the fix, no account value should end with a CR. Expect 0:
SELECT COUNT(*) AS cr_left_in_account
FROM trans_raw
WHERE RIGHT(account, 1) = CHAR(13);

-- ----------------------------------------------------------------------------
-- 1.3  Profiling trans_raw (raw text, before choosing types)
-- ----------------------------------------------------------------------------

-- Category columns: the distinct values, their byte length, and how often
-- each appears. LENGTH counts BYTES (use CHAR_LENGTH to count characters).
-- Comparing lengths exposes hidden spaces or stray characters.
SELECT `type`, LENGTH(`type`) AS len, COUNT(*) AS n
FROM trans_raw GROUP BY `type`, LENGTH(`type`) ORDER BY n DESC;

SELECT operation, LENGTH(operation) AS len, COUNT(*) AS n
FROM trans_raw GROUP BY operation, LENGTH(operation) ORDER BY n DESC;

SELECT k_symbol, LENGTH(k_symbol) AS len, COUNT(*) AS n
FROM trans_raw GROUP BY k_symbol, LENGTH(k_symbol) ORDER BY n DESC;

-- k_symbol has two blank-looking groups. HEX shows what they really are:
-- HEX 20 = a single space (53,433 rows), empty string = 481,881 rows.
SELECT HEX(k_symbol) AS hex_value, LENGTH(k_symbol) AS len, COUNT(*) AS n
FROM trans_raw
WHERE LENGTH(k_symbol) <= 1
GROUP BY HEX(k_symbol), LENGTH(k_symbol);

-- Date column: every value should be exactly 6 characters (YYMMDD).
SELECT LENGTH(`date`) AS len, COUNT(*) AS n
FROM trans_raw GROUP BY LENGTH(`date`);

-- MIN / MAX on TEXT compares left to right, so it is only meaningful when all
-- values have the same length (they do: 6). Result: 930101 to 981231.
SELECT MIN(`date`) AS min_date, MAX(`date`) AS max_date FROM trans_raw;

-- Split the date into its parts and look at each part separately.
SELECT SUBSTRING(`date`, 1, 2) AS yy, COUNT(*) AS n FROM trans_raw GROUP BY yy ORDER BY yy;
SELECT SUBSTRING(`date`, 3, 2) AS mm, COUNT(*) AS n FROM trans_raw GROUP BY mm ORDER BY mm;
SELECT SUBSTRING(`date`, 5, 2) AS dd, COUNT(*) AS n FROM trans_raw GROUP BY dd ORDER BY dd;

-- Values that cannot be read as a date. Expect 0.
-- (Assumption: %y maps 93..98 to 1993..1998. It fits the data range.)
SELECT SUM(STR_TO_DATE(`date`, '%y%m%d') IS NULL) AS bad_dates FROM trans_raw;

-- Amount and balance: any value that is not a plain number? Expect 0.
-- The pattern allows an optional minus sign and optional decimals.
SELECT SUM(amount  NOT REGEXP '^-?[0-9]+([.][0-9]+)?$') AS bad_amount,
       SUM(balance NOT REGEXP '^-?[0-9]+([.][0-9]+)?$') AS bad_balance
FROM trans_raw;

-- Number of decimals. Result: always 2 (so DECIMAL(12,2) fits).
SELECT LENGTH(amount)  - LOCATE('.', amount)  AS amount_decimals,  COUNT(*) AS n
FROM trans_raw GROUP BY amount_decimals;
SELECT LENGTH(balance) - LOCATE('.', balance) AS balance_decimals, COUNT(*) AS n
FROM trans_raw GROUP BY balance_decimals;

-- Smallest / largest values, converted to numbers inside the query only.
SELECT MIN(CAST(amount  AS DECIMAL(12,2))) AS min_amount,
       MAX(CAST(amount  AS DECIMAL(12,2))) AS max_amount,
       MIN(CAST(balance AS DECIMAL(12,2))) AS min_balance,
       MAX(CAST(balance AS DECIMAL(12,2))) AS max_balance
FROM trans_raw;

-- Zero-value transactions.
SELECT SUM(CAST(amount AS DECIMAL(12,2)) = 0) AS zero_amounts FROM trans_raw;

-- bank / account (the partner's bank and account): how many are blank?
SELECT SUM(bank    = '') AS blank_bank,
       SUM(account = '') AS blank_account
FROM trans_raw;

-- The account column also holds a lone '0' (HEX 30 = the visible digit 0,
-- NOT a hidden character) on 21,881 rows. We treat it as "no account".
SELECT HEX(account) AS hex_value, COUNT(*) AS n
FROM trans_raw
WHERE LENGTH(account) = 1
GROUP BY HEX(account);

-- Do bank and account go blank together?
SELECT (bank = '')    AS bank_blank,
       (account = '') AS account_blank,
       COUNT(*)       AS n
FROM trans_raw
GROUP BY (bank = ''), (account = '');

-- Identifier columns: all digits? how many distinct? Expect 0 bad values.
SELECT SUM(trans_id   NOT REGEXP '^[0-9]+$') AS bad_trans_id,
       SUM(account_id NOT REGEXP '^[0-9]+$') AS bad_account_id,
       MAX(CAST(trans_id   AS UNSIGNED))     AS max_trans_id,
       COUNT(DISTINCT account_id)            AS distinct_accounts
FROM trans_raw;
-- trans_id values have gaps: they are labels, not a counter.
-- One row = one transaction record (grain). 4,500 distinct accounts.

-- Longest value in each column. This tells us how wide each typed column
-- needs to be (and shows nothing is unexpectedly long).
SELECT MAX(LENGTH(trans_id))   AS trans_id_len,
       MAX(LENGTH(account_id)) AS account_id_len,
       MAX(LENGTH(`date`))     AS date_len,
       MAX(LENGTH(`type`))     AS type_len,
       MAX(LENGTH(operation))  AS operation_len,
       MAX(LENGTH(amount))     AS amount_len,
       MAX(LENGTH(balance))    AS balance_len,
       MAX(LENGTH(k_symbol))   AS k_symbol_len,
       MAX(LENGTH(bank))       AS bank_len,
       MAX(LENGTH(account))    AS account_len
FROM trans_raw;

-- ----------------------------------------------------------------------------
-- 1.4  Typed table, designed from what we measured
--      trans_raw stays untouched as the original copy.
--      Decisions:
--        * k_symbol and operation: kept as they are (blank stays blank)
--        * bank / account: blank and the lone '0' account become NULL
--          (the rows themselves are NOT dropped: ~74% have no partner)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS trans;          -- CAUTION: deletes the table
CREATE TABLE trans (
    trans_id    INT           NOT NULL,
    account_id  INT           NOT NULL,
    trans_date  DATE          NOT NULL,
    trans_type  VARCHAR(10)   NOT NULL,
    operation   VARCHAR(20)   NOT NULL,
    amount      DECIMAL(12,2) NOT NULL,
    balance     DECIMAL(12,2) NOT NULL,
    k_symbol    VARCHAR(20)   NOT NULL,
    bank        CHAR(2)       NULL,
    account     VARCHAR(10)   NULL,
    PRIMARY KEY (trans_id)
);

-- Highlight this WHOLE statement before running it. (Earlier, only the COUNT
-- below it was highlighted, so the INSERT never ran and the count was 0.)
INSERT INTO trans (trans_id, account_id, trans_date, trans_type, operation,
                   amount, balance, k_symbol, bank, account)
SELECT CAST(trans_id AS UNSIGNED),
       CAST(account_id AS UNSIGNED),
       STR_TO_DATE(`date`, '%y%m%d'),
       `type`,
       operation,
       CAST(amount  AS DECIMAL(12,2)),
       CAST(balance AS DECIMAL(12,2)),
       k_symbol,
       NULLIF(bank, ''),                      -- blank -> NULL
       NULLIF(NULLIF(account, ''), '0')       -- blank or '0' -> NULL
FROM trans_raw;

-- ----------------------------------------------------------------------------
-- 1.5  Validation: typed table vs raw table
-- ----------------------------------------------------------------------------
SELECT COUNT(*) FROM trans;                                -- 1,056,320

-- Same totals on both sides (they must match exactly):
SELECT COUNT(*)                              AS n_rows,
       SUM(CAST(amount  AS DECIMAL(12,2)))   AS sum_amount,
       SUM(CAST(balance AS DECIMAL(12,2)))   AS sum_balance,
       SUM(bank <> '')                       AS rows_with_bank,
       SUM(account NOT IN ('', '0'))         AS rows_with_account
FROM trans_raw;

SELECT COUNT(*)      AS n_rows,
       SUM(amount)   AS sum_amount,
       SUM(balance)  AS sum_balance,
       COUNT(bank)   AS rows_with_bank,       -- COUNT(col) skips NULLs
       COUNT(account) AS rows_with_account
FROM trans;

-- Spot check one row against the raw text (we checked row 637742):
SELECT * FROM trans_raw WHERE trans_id = 637742;
SELECT * FROM trans     WHERE trans_id = 637742;


-- ============================================================================
-- PART 2. QUESTION 1: how is activity (transactions) spread over time?
-- ============================================================================

-- 2.1  Per year: transactions, active accounts, transactions per account (rebuilt)
--      Finding: activity grows every year. Growth to 1997 comes mostly from more
--      active accounts; growth in 1998 comes from more activity per account.
SELECT YEAR(trans_date)                        AS yr,
       COUNT(*)                                AS transactions,
       COUNT(DISTINCT account_id)              AS active_accounts,
       ROUND(COUNT(*) / COUNT(DISTINCT account_id), 1) AS tx_per_account
FROM trans
GROUP BY YEAR(trans_date)
ORDER BY yr;

-- 2.2  Month-by-year grid (rebuilt). SUM(condition) counts the rows where the
--      condition is true, because true = 1 and false = 0.
--      Finding: January is high every year from 1994; 1993 ramps up from ~0.
SELECT YEAR(trans_date) AS yr,
       SUM(MONTH(trans_date) = 1)  AS jan,
       SUM(MONTH(trans_date) = 2)  AS feb,
       SUM(MONTH(trans_date) = 3)  AS mar,
       SUM(MONTH(trans_date) = 4)  AS apr,
       SUM(MONTH(trans_date) = 5)  AS may,
       SUM(MONTH(trans_date) = 6)  AS jun,
       SUM(MONTH(trans_date) = 7)  AS jul,
       SUM(MONTH(trans_date) = 8)  AS aug,
       SUM(MONTH(trans_date) = 9)  AS sep,
       SUM(MONTH(trans_date) = 10) AS oct,
       SUM(MONTH(trans_date) = 11) AS nov,
       SUM(MONTH(trans_date) = 12) AS dec_
FROM trans
GROUP BY YEAR(trans_date)
ORDER BY yr;

-- 2.3  Day of the month (rebuilt). Very uneven: days 30 and 31 hold ~31% of rows.
SELECT DAY(trans_date) AS dd, COUNT(*) AS n
FROM trans
GROUP BY DAY(trans_date)
ORDER BY dd;

-- 2.4  January vs February 1997 by operation.
--      Result: VYBER (cash withdrawal) alone is +13,395 of the +13,858 gap.
SELECT operation,
       SUM(MONTH(trans_date) = 1) AS jan,
       SUM(MONTH(trans_date) = 2) AS feb,
       SUM(MONTH(trans_date) = 1) - SUM(MONTH(trans_date) = 2) AS jan_minus_feb
FROM trans
WHERE YEAR(trans_date) = 1997
GROUP BY operation
ORDER BY jan_minus_feb DESC;

-- 2.5  Same by k_symbol. Result: the surplus sits in the blank group, so
--      k_symbol does not explain January (it is not a useful lens here).
SELECT k_symbol,
       SUM(MONTH(trans_date) = 1) AS jan,
       SUM(MONTH(trans_date) = 2) AS feb,
       SUM(MONTH(trans_date) = 1) - SUM(MONTH(trans_date) = 2) AS jan_minus_feb
FROM trans
WHERE YEAR(trans_date) = 1997
GROUP BY k_symbol
ORDER BY jan_minus_feb DESC;

-- 2.6  VYBER (cash withdrawal) by month for every year.
--      Result: January is about 3x February in every full year, 1994-1998.
SELECT YEAR(trans_date) AS yr,
       SUM(MONTH(trans_date) = 1)  AS jan,
       SUM(MONTH(trans_date) = 2)  AS feb,
       SUM(MONTH(trans_date) = 3)  AS mar,
       SUM(MONTH(trans_date) = 4)  AS apr,
       SUM(MONTH(trans_date) = 5)  AS may,
       SUM(MONTH(trans_date) = 6)  AS jun,
       SUM(MONTH(trans_date) = 7)  AS jul,
       SUM(MONTH(trans_date) = 8)  AS aug,
       SUM(MONTH(trans_date) = 9)  AS sep,
       SUM(MONTH(trans_date) = 10) AS oct,
       SUM(MONTH(trans_date) = 11) AS nov,
       SUM(MONTH(trans_date) = 12) AS dec_
FROM trans
WHERE operation = 'VYBER'
GROUP BY YEAR(trans_date)
ORDER BY yr;

-- 2.7  Is the January surplus broad or concentrated? Group by account (1997).
--      Query 1: summary over all accounts. The inner query makes one row per
--      account; the outer query compares January with February.
--      Result: 2,803 accounts higher in Jan, 373 higher in Feb, 1,320 equal.
SELECT SUM(jan > feb) AS accounts_more_in_jan,
       SUM(jan < feb) AS accounts_more_in_feb,
       SUM(jan = feb) AS accounts_equal,
       SUM(jan)       AS total_jan,       -- 33,060
       SUM(feb)       AS total_feb        -- 19,202
FROM (
    SELECT account_id,
           SUM(MONTH(trans_date) = 1) AS jan,
           SUM(MONTH(trans_date) = 2) AS feb
    FROM trans
    WHERE YEAR(trans_date) = 1997
    GROUP BY account_id
) AS per_account;

--      Query 2: the 10 accounts with the biggest January-minus-February gap.
--      Result: gaps of only 11-13 each (<1% of the total gap), so it is broad.
SELECT account_id,
       SUM(MONTH(trans_date) = 1) AS jan,
       SUM(MONTH(trans_date) = 2) AS feb,
       SUM(MONTH(trans_date) = 1) - SUM(MONTH(trans_date) = 2) AS jan_minus_feb
FROM trans
WHERE YEAR(trans_date) = 1997
GROUP BY account_id
ORDER BY jan_minus_feb DESC
LIMIT 10;

-- 2.8  Which days of the month? VYBER, January vs February 1997.
--      Result: the last day of each month has ~3,300 rows in both months;
--      January's ordinary days are ~4-5x February's.
SELECT DAY(trans_date) AS dd,
       SUM(MONTH(trans_date) = 1) AS jan,
       SUM(MONTH(trans_date) = 2) AS feb
FROM trans
WHERE operation = 'VYBER'
  AND YEAR(trans_date) = 1997
  AND MONTH(trans_date) IN (1, 2)
GROUP BY DAY(trans_date)
ORDER BY dd;

-- 2.9  Month-end rows vs ordinary days, VYBER, every month of 1997.
--      LAST_DAY(d) = last date of d's month.
--      Result: month-end rows grow smoothly (3,257 -> 4,161); January's
--      ordinary-day level (561/day) is far above the other months (123-219),
--      with smaller bumps in June (219) and December (289).
SELECT MONTH(trans_date) AS mth,
       SUM(trans_date = LAST_DAY(trans_date))  AS month_end_rows,
       SUM(trans_date <> LAST_DAY(trans_date)) AS other_rows,
       ROUND(SUM(trans_date <> LAST_DAY(trans_date))
             / (DAY(LAST_DAY(MIN(trans_date))) - 1)) AS avg_per_other_day
FROM trans
WHERE operation = 'VYBER'
  AND YEAR(trans_date) = 1997
GROUP BY MONTH(trans_date)
ORDER BY mth;


-- ============================================================================
-- PART 3. LOAN (682 loans)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 3.1  First look at the file: load the raw lines (one line per row)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS loan_lines;     -- CAUTION: deletes the table
CREATE TABLE loan_lines (
    line_no INT AUTO_INCREMENT PRIMARY KEY,
    line    TEXT
);

LOAD DATA LOCAL INFILE '/Users/abinashkanagalingam/Downloads/berca/loan.csv'
INTO TABLE loan_lines
FIELDS TERMINATED BY '\t' ESCAPED BY ''
LINES TERMINATED BY '\r\n'
(line);

SELECT COUNT(*) FROM loan_lines;                       -- 683 = header + 682 rows
SELECT line_no, line FROM loan_lines ORDER BY line_no LIMIT 6;

-- The grid cuts long text, so show the rest of the header:
-- "loan_id";"account_id";"date";"amount";"duration";"payments";"status"
SELECT SUBSTRING(line, 25) AS header_rest FROM loan_lines WHERE line_no = 1;

-- Every line should have 6 semicolons (7 fields). Result: all 683 do.
SELECT LENGTH(line) - LENGTH(REPLACE(line, ';', '')) AS semicolons,
       COUNT(*) AS n_lines
FROM loan_lines
GROUP BY LENGTH(line) - LENGTH(REPLACE(line, ';', ''));

-- ----------------------------------------------------------------------------
-- 3.2  Raw staging table and load (run the LOAD once only)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS loan_raw;       -- CAUTION: deletes the table
CREATE TABLE loan_raw (
    loan_id    VARCHAR(20),
    account_id VARCHAR(20),
    `date`     VARCHAR(20),
    amount     VARCHAR(30),
    duration   VARCHAR(20),
    payments   VARCHAR(30),
    status     VARCHAR(20)
);

LOAD DATA LOCAL INFILE '/Users/abinashkanagalingam/Downloads/berca/loan.csv'
INTO TABLE loan_raw
FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES;

SELECT COUNT(*) FROM loan_raw;                         -- 682

-- status values: all length 1 means quotes and line endings were handled.
-- Result: C 403, A 203, D 45, B 31.
SELECT status, LENGTH(status) AS len, COUNT(*) AS n
FROM loan_raw
GROUP BY status, LENGTH(status)
ORDER BY n DESC;

-- ----------------------------------------------------------------------------
-- 3.3  Profiling loan_raw
-- ----------------------------------------------------------------------------

-- Grain and ID columns: 682 rows, 682 distinct loans, 682 distinct accounts
-- (one loan per account), all digits, loan_id always 4 characters.
SELECT COUNT(*)                                AS n_rows,
       COUNT(DISTINCT loan_id)                 AS distinct_loans,
       COUNT(DISTINCT account_id)              AS distinct_accounts,
       SUM(loan_id    NOT REGEXP '^[0-9]+$')   AS bad_loan_id,
       SUM(account_id NOT REGEXP '^[0-9]+$')   AS bad_account_id,
       MIN(LENGTH(loan_id))    AS min_len_loan,
       MAX(LENGTH(loan_id))    AS max_len_loan,
       MIN(LENGTH(account_id)) AS min_len_acct,
       MAX(LENGTH(account_id)) AS max_len_acct
FROM loan_raw;

-- Dates: all 6 characters, 930705 to 981208, no unreadable dates.
SELECT MIN(LENGTH(`date`)) AS min_len,
       MAX(LENGTH(`date`)) AS max_len,
       MIN(`date`)         AS min_date,
       MAX(`date`)         AS max_date,
       SUM(STR_TO_DATE(`date`, '%y%m%d') IS NULL) AS bad_dates
FROM loan_raw;

-- Number formats. Result: nothing malformed; amount has no decimals,
-- payments always has them.
SELECT SUM(amount   NOT REGEXP '^[0-9]+([.][0-9]+)?$') AS bad_amount,
       SUM(duration NOT REGEXP '^[0-9]+$')             AS bad_duration,
       SUM(payments NOT REGEXP '^[0-9]+([.][0-9]+)?$') AS bad_payments,
       SUM(amount   LIKE '%.%')                        AS amount_with_dot,
       SUM(payments LIKE '%.%')                        AS payments_with_dot
FROM loan_raw;

-- duration takes only 12, 24, 36, 48, 60 (131 / 138 / 130 / 138 / 145 loans).
SELECT duration, COUNT(*) AS n
FROM loan_raw
GROUP BY duration
ORDER BY CAST(duration AS UNSIGNED);

-- Sizes and decimals (used to choose the column types).
-- Result: amount 4,980-590,820; payments 304.00-9,910.00, always 2 decimals;
-- no zeros; longest values 6 and 7 characters.
SELECT MIN(CAST(amount AS UNSIGNED))         AS min_amount,
       MAX(CAST(amount AS UNSIGNED))         AS max_amount,
       SUM(CAST(amount AS UNSIGNED) = 0)     AS zero_amount,
       MIN(CAST(payments AS DECIMAL(12,2)))  AS min_payments,
       MAX(CAST(payments AS DECIMAL(12,2)))  AS max_payments,
       SUM(CAST(payments AS DECIMAL(12,2)) = 0) AS zero_payments,
       MIN(LENGTH(payments) - LOCATE('.', payments)) AS min_decimals,
       MAX(LENGTH(payments) - LOCATE('.', payments)) AS max_decimals,
       MAX(LENGTH(amount))   AS max_len_amount,
       MAX(LENGTH(payments)) AS max_len_payments
FROM loan_raw;

-- ----------------------------------------------------------------------------
-- 3.4  Typed loan table, designed from the measurements above
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS loan;           -- CAUTION: deletes the table
CREATE TABLE loan (
    loan_id    INT              NOT NULL,
    account_id INT              NOT NULL,
    loan_date  DATE             NOT NULL,
    amount     INT              NOT NULL,
    duration   TINYINT UNSIGNED NOT NULL,
    payments   DECIMAL(10,2)    NOT NULL,
    status     CHAR(1)          NOT NULL,
    PRIMARY KEY (loan_id)
);

-- Highlight the whole statement before running.
INSERT INTO loan (loan_id, account_id, loan_date, amount, duration, payments, status)
SELECT CAST(loan_id AS UNSIGNED),
       CAST(account_id AS UNSIGNED),
       STR_TO_DATE(`date`, '%y%m%d'),
       CAST(amount AS UNSIGNED),
       CAST(duration AS UNSIGNED),
       CAST(payments AS DECIMAL(10,2)),
       status
FROM loan_raw;

SELECT COUNT(*) FROM loan;                             -- 682

-- ----------------------------------------------------------------------------
-- 3.5  Validation: same totals on raw and typed (they must match)
--      Expected: 682 rows | 103,261,740 | 24,888 | 2,858,033.00 | 403
-- ----------------------------------------------------------------------------
SELECT COUNT(*)                              AS n_rows,
       SUM(CAST(amount   AS UNSIGNED))       AS sum_amount,
       SUM(CAST(duration AS UNSIGNED))       AS sum_duration,
       SUM(CAST(payments AS DECIMAL(10,2)))  AS sum_payments,
       SUM(status = 'C')                     AS status_c
FROM loan_raw;

SELECT COUNT(*)      AS n_rows,
       SUM(amount)   AS sum_amount,
       SUM(duration) AS sum_duration,
       SUM(payments) AS sum_payments,
       SUM(status = 'C') AS status_c
FROM loan;

-- Spot check against a line we read in the file:
-- 5314;1787;930705;96396;12;8033.00;"B"
SELECT * FROM loan WHERE loan_id = 5314;


-- ============================================================================
-- PART 4. QUESTION 2: how do loan size and repayment relate?
-- ============================================================================

-- 4.1  By duration. Result: amount rises steadily with duration (avg 53,636
--      at 12 up to 244,451 at 60), while payments stay about the same.
SELECT duration,
       COUNT(*)                AS loans,
       MIN(amount)             AS min_amount,
       ROUND(AVG(amount))      AS avg_amount,
       MAX(amount)             AS max_amount,
       MIN(payments)           AS min_payments,
       ROUND(AVG(payments), 2) AS avg_payments,
       MAX(payments)           AS max_payments
FROM loan
GROUP BY duration
ORDER BY duration;

-- 4.2  Is payments just amount / duration? payments is stored to the cent, so
--      rounding can cause a gap of at most 0.005 x duration.
--      Result: 682 of 682 within rounding, max gap 0.00. So payments is derived
--      (it adds no information of its own, and shows no sign of interest).
SELECT COUNT(*) AS loans,
       SUM(ABS(payments * duration - amount) <= duration * 0.005) AS within_rounding,
       MAX(ABS(payments * duration - amount))                     AS max_diff
FROM loan;

-- 4.3  By status.
--      Result: A and B are shorter and end by 1997; C and D are longer and
--      run into 1998.
SELECT status,
       COUNT(*)                AS loans,
       ROUND(AVG(amount))      AS avg_amount,
       ROUND(AVG(payments), 2) AS avg_payments,
       ROUND(AVG(duration), 1) AS avg_duration,
       MIN(loan_date)          AS first_loan,
       MAX(loan_date)          AS last_loan
FROM loan
GROUP BY status
ORDER BY status;

-- 4.4  Does status agree with the contract end date? End date = grant date +
--      duration months. The cutoff (end of 1998) is our assumption: the last
--      date in trans.
--      Result: every A and B ends on or before 1998-12-28; every C and D ends
--      on or after 1999-01-03. This also confirms duration is in months.
SELECT status,
       COUNT(*) AS loans,
       MIN(DATE_ADD(loan_date, INTERVAL duration MONTH)) AS earliest_end,
       MAX(DATE_ADD(loan_date, INTERVAL duration MONTH)) AS latest_end,
       SUM(DATE_ADD(loan_date, INTERVAL duration MONTH) > '1998-12-31') AS ends_after_1998
FROM loan
GROUP BY status
ORDER BY status;


-- ============================================================================
-- PART 5. QUESTION 3: loans vs the account's history before the loan
-- ============================================================================

-- 5.1  Do all loan accounts exist in trans? LEFT JOIN keeps every loan; a loan
--      with no match shows NULL on the trans side. The DISTINCT list stops an
--      account with many transactions from matching many times.
--      Result: 682 loans, 0 without transactions.
SELECT COUNT(*)                  AS loans,
       SUM(t.account_id IS NULL) AS loans_without_transactions
FROM loan AS l
LEFT JOIN (SELECT DISTINCT account_id FROM trans) AS t
       ON l.account_id = t.account_id;

-- 5.2  Transactions before each loan: first 10 loans.
--      The date condition is in ON (not WHERE) so a loan with no earlier
--      transactions is kept with a count of 0.
SELECT l.loan_id,
       l.status,
       l.loan_date,
       COUNT(t.trans_id) AS tx_before_loan
FROM loan AS l
LEFT JOIN trans AS t
       ON t.account_id = l.account_id
      AND t.trans_date < l.loan_date
GROUP BY l.loan_id, l.status, l.loan_date
ORDER BY l.loan_id
LIMIT 10;

-- 5.3  Summary by status. no_history = loans with zero earlier transactions.
--      Result: no_history = 0 in every group; B has the lowest average (58.4).
SELECT status,
       COUNT(*)             AS loans,
       MIN(n)               AS min_tx,
       ROUND(AVG(n), 1)     AS avg_tx,
       MAX(n)               AS max_tx,
       SUM(n = 0)           AS no_history
FROM (
    SELECT l.loan_id,
           l.status,
           COUNT(t.trans_id) AS n
    FROM loan AS l
    LEFT JOIN trans AS t
           ON t.account_id = l.account_id
          AND t.trans_date < l.loan_date
    GROUP BY l.loan_id, l.status
) AS per_loan
GROUP BY status
ORDER BY status;

-- 5.4  Separate "how long" from "how active". History length = days from the
--      account's first transaction in the data to the loan date. A plain JOIN
--      is safe here because 5.3 showed no loan lacks earlier transactions.
--      Result: B's history is shorter (297 days vs 377-416); transactions per
--      30 days are similar in all groups (A 5.8, B 5.2, C 5.7, D 5.5).
SELECT status,
       COUNT(*)                             AS loans,
       ROUND(AVG(history_days))             AS avg_history_days,
       ROUND(AVG(n), 1)                     AS avg_tx,
       ROUND(AVG(n / history_days * 30), 1) AS avg_tx_per_30_days
FROM (
    SELECT l.loan_id,
           l.status,
           COUNT(t.trans_id)                        AS n,
           DATEDIFF(l.loan_date, MIN(t.trans_date)) AS history_days
    FROM loan AS l
    JOIN trans AS t
      ON t.account_id = l.account_id
     AND t.trans_date < l.loan_date
    GROUP BY l.loan_id, l.status, l.loan_date
) AS per_loan
GROUP BY status
ORDER BY status;

-- 5.5  The account's balance in the 90 days before each loan: first 10 loans.
--      balance = balance after each transaction. The 90-day window is our
--      choice. We use the average and the minimum because several transactions
--      can share a date and trans_id is not a reliable time order, so "the
--      last balance" is ambiguous.
--      Result (10 loans): all had 13-28 transactions in the window; the three
--      B/D loans had very low minimums (715.00, -1,011.20, 379.00), all seven
--      A/C loans stayed above about 15,000.
SELECT l.loan_id,
       l.status,
       l.loan_date,
       COUNT(t.trans_id)     AS tx_90d,
       ROUND(AVG(t.balance)) AS avg_balance_90d,
       MIN(t.balance)        AS min_balance_90d
FROM loan AS l
LEFT JOIN trans AS t
       ON t.account_id = l.account_id
      AND t.trans_date <  l.loan_date
      AND t.trans_date >= DATE_SUB(l.loan_date, INTERVAL 90 DAY)
GROUP BY l.loan_id, l.status, l.loan_date
ORDER BY l.loan_id
LIMIT 10;

-- 5.6  The same balance measure for all 682 loans, summarized by status.
--      Result: no loan lacked transactions in the window.
--        A: 203 loans, avg of lowest balance 25,345, 0 went negative
--        C: 403 loans, avg of lowest balance 24,902, 0 went negative
--        B:  31 loans, avg of lowest balance 15,541, 3 went negative (9.7%)
--        D:  45 loans, avg of lowest balance  8,700, 12 went negative (26.7%)
--      Every loan whose account went negative is in B or D (15 of 76 problem
--      loans, 0 of 606 others). Association only: groups B and D are small and
--      status is a snapshot at about the end of 1998.
SELECT status,
       COUNT(*)                   AS loans,
       SUM(n_tx = 0)              AS no_tx_in_window,
       ROUND(AVG(avg_bal))        AS avg_of_avg_balance,
       ROUND(AVG(min_bal))        AS avg_of_min_balance,
       SUM(min_bal < 0)           AS ever_negative,
       ROUND(100 * SUM(min_bal < 0) / COUNT(min_bal), 1) AS pct_negative
FROM (
    SELECT l.loan_id,
           l.status,
           COUNT(t.trans_id) AS n_tx,
           AVG(t.balance)    AS avg_bal,
           MIN(t.balance)    AS min_bal
    FROM loan AS l
    LEFT JOIN trans AS t
           ON t.account_id = l.account_id
          AND t.trans_date <  l.loan_date
          AND t.trans_date >= DATE_SUB(l.loan_date, INTERVAL 90 DAY)
    GROUP BY l.loan_id, l.status
) AS per_loan
GROUP BY status
ORDER BY status;


-- ============================================================================
-- CLEAN-UP (optional). The two *_lines tables were only for diagnosis.
-- CAUTION: uncomment and run only if you no longer need them.
-- ============================================================================
-- DROP TABLE IF EXISTS trans_lines;
-- DROP TABLE IF EXISTS loan_lines;
