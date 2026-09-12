# SafariConnect: from a broken Excel export to a board-ready analysis

SafariConnect is a Nairobi bus and matatu booking platform. Every booking since 2024 had lived in one shared Excel file, and the Operations Director wanted six questions answered: which routes make money, which drivers to promote, how revenue moves month by month, where passengers come from, what cancellations cost, and when the busiest times are.

This is the whole project in PostgreSQL: 290 raw rows loaded as they arrived, cleaned column by column, loaded into a typed production table, analysed with CTEs and window functions, and exposed as views for a Power BI dashboard.

The write-up is on dev.to: **SafariConnect: From a Broken Excel Export to a Board-Ready Analysis in PostgreSQL** (link added once published — see [dev.to/leahkivuti](https://dev.to/leahkivuti)).

## What's in this repository

`sql/01_load_raw_data.sql` creates the `safari_connect` schema and a staging table with all 290 raw rows, every column as text, nothing cleaned. Run it first.

`sql/02_clean_and_build.sql` is the cleaning script: audit queries first, then a working copy, then each fix — casing, eight spellings of gender, nine of seat class, ten of payment method, phone numbers damaged by Excel, fares stored as `KES 1,200`, dates in two formats, ratings of 0, 6 and 7, one duplicate booking, one row with −1 seats. It ends with the production `bookings` table (CHECK constraints on every category column) and the `v_clean_trips` view that the analysis runs on.

`sql/03_analysis_six_questions.sql` answers the six business questions in twenty queries, each with its key result in a comment. CTEs, `RANK`, `LAG`, running totals with `SUM() OVER`, percentage-of-total, `NTILE` quartiles, `CASE WHEN` pivots.

`sql/04_views_and_indexes.sql` creates the five views the dashboard connects to and seven indexes, all safe to re-run.

`sql/05_load_with_reject_table.sql` is the same load done a safer way, added after a reader asked how the load handles failures. Instead of deleting bad rows and quietly emptying bad values, it sorts every problem into one of two kinds. A row that cannot be loaded at all — a duplicate booking id, seats that are not a positive number — goes to a `rejected_bookings` table with the reason and its whole original row kept as JSON. A single bad value in an otherwise real booking — a trip rating of 6, a phone number Excel destroyed — is repaired or emptied, and the change is counted in a `cleaning_log` table. The run order becomes 01 → 05 → 03 → 04. It produces a `bookings` table identical to the one `02` produces, row for row; the difference is that afterwards you can answer what was dropped and why.

Every check in `05` is done on text with a regular expression rather than on a cast, because a cast inside a validation check raises an error on the first bad value and stops the whole load — the thing the reject table exists to prevent.

`data/` holds the raw export as CSV (what PostgreSQL imports) and as an Excel workbook with every column kept as text (so Excel can't damage the phone numbers again).

`dashboard/` holds the Power BI report built on the views and the one-page analysis summary presented to the board.

`screenshots/` shows five moments in pgAdmin: the gender column before cleaning, the phone numbers after Excel had been at them, revenue by route, the monthly LAG query, and the booking status breakdown.

## The numbers

| | |
|---|---|
| Raw rows | 290 |
| After removing the duplicate and the −1-seat row | 288 |
| Completed trips (what the revenue questions use) | 253 |
| Total revenue | KES 227,810 |
| Seats sold | 452 |
| Revenue lost to cancellations and no-shows | KES 32,150 (12.4% of what was earned) |
| Rows refused by the reject-table loader | 2, both with a written reason |

## What the analysis found

Three routes make 58.5% of the money and Nairobi to Mombasa alone makes 22.7% (KES 51,600 from 41 seats). Nairobi to Thika is the busiest route by seats (62) and the worst earner (KES 7,620), because its fare is KES 126 a seat against 1,292 for Mombasa. Popularity and profit are different questions.

The platform's driver rating does not predict passenger satisfaction. Drivers rated 4.5 or higher averaged 3.38 stars from passengers; drivers rated below 4.5 averaged 3.62. The top earner, Isaac Korir (KES 33,045), has the lowest driver rating of the eight.

There is no growth trend across 2024. Revenue sat between KES 13,400 and 24,190 every month; August was the worst month (down 41.4%) and October the best. The January 2025 row is a partial month, not a collapse.

Nairobi passengers account for 113 of 253 trips and just under half of revenue. Women booked slightly more trips than men and brought in more revenue. Nearly one trip in five is rated 1 or 2 stars.

Cancellations and no-shows cost one shilling in eight. Mombasa to Malindi has the worst rate (18.5%, mostly no-shows); Nairobi to Eldoret the best (3.6%).

Monday to Thursday carry the business. The 19:00 departures earn the most on fewer seats, so evening travel carries the higher-fare passengers.

## What went wrong, and the lesson

The phone numbers were damaged before the data reached the database: the CSV had been opened and saved in Excel, which drops the leading zero from `0712345678` and turns `254712345678` into `2.54712E+11`. 249 numbers lost their zero (recoverable), 15 became scientific notation (not recoverable by any query). The fix is a rule about how CSVs are handled, not a cleverer query.

## How to run it

Open pgAdmin's Query Tool on any database and run the SQL files in order — either 01 → 02 → 03 → 04, or 01 → 05 → 03 → 04 to get the reject table and cleaning log as well. Each ends with a check whose expected result is in the comments; `02` should finish with 253 / 227810 / 452. The first file drops and recreates a schema called `safari_connect`, so rename it at the top of each file if you already have one.

To open the dashboard, install Power BI Desktop, open `dashboard/SafariConnect_Performance.pbix`, and point the PostgreSQL connection at your own server (Get Data → PostgreSQL → server `localhost`, schema `safari_connect`, select the `v_` views).

## Tools

PostgreSQL 16, pgAdmin 4, Power BI Desktop.
