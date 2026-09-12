-- ============================================================
-- SafariConnect: 05 - loading with a reject table
--
-- Input : safari_connect.bookings_staging (290 raw rows, all TEXT)
-- Output: safari_connect.bookings            (typed, constrained - same as 02)
--         safari_connect.rejected_bookings   (rows that could not be loaded, with the reason)
--         safari_connect.cleaning_log        (every field-level repair, with a count)
--
-- Why this file exists
-- --------------------
-- 02_clean_and_build.sql deletes the bad rows and NULLs the bad values.
-- The result is correct, but afterwards nobody can answer "what did you
-- drop, and why?" This file produces the SAME bookings table from the
-- same staging data, and keeps a record of every row it refused and
-- every value it changed.
--
-- Two kinds of problem, handled differently:
--
--   Row-level   the row cannot be loaded at all (no usable date, seats
--               that are not a positive number, a duplicate booking id).
--               The whole row goes to rejected_bookings with a reason.
--
--   Field-level one value is wrong but the booking is still real (a trip
--               rating of 6, a blank city, a phone Excel destroyed).
--               The field is repaired or set to NULL and the change is
--               counted in cleaning_log. The row still loads.
--
-- Where it fits: 01 -> 05 -> 03 -> 04.  This file REPLACES 02; it reads
-- the same staging table and produces the same bookings table and
-- v_clean_trips view. It drops bookings with CASCADE, so if you have
-- already run 04, run 04 again afterwards to recreate the five
-- dashboard views. Safe to re-run.
-- ============================================================

SET search_path TO safari_connect;


-- ------------------------------------------------------------
-- 1. The two audit tables
-- ------------------------------------------------------------
DROP TABLE IF EXISTS rejected_bookings;
CREATE TABLE rejected_bookings (
    reject_id     SERIAL PRIMARY KEY,
    booking_id    TEXT,
    reject_reason TEXT        NOT NULL,
    rejected_at   TIMESTAMP   NOT NULL DEFAULT NOW(),
    raw_row       JSONB       NOT NULL      -- the whole original row, nothing lost
);

DROP TABLE IF EXISTS cleaning_log;
CREATE TABLE cleaning_log (
    log_id        SERIAL PRIMARY KEY,
    step          TEXT,
    column_name   TEXT,
    action        TEXT,
    rows_affected INTEGER,
    logged_at     TIMESTAMP NOT NULL DEFAULT NOW()
);


-- ------------------------------------------------------------
-- 2. Working copy. The raw import is never touched.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS cleaning;
CREATE TABLE cleaning AS
SELECT s.*, TO_JSONB(s) AS raw_row     -- each row's original form, kept per row
FROM bookings_staging s;


-- ------------------------------------------------------------
-- 3. Field-level repairs, each one counted
--
--    The pattern below is a data-modifying CTE: the UPDATE runs
--    inside a WITH, RETURNING one row per row it changed, and the
--    INSERT counts them. That is how the log gets its numbers
--    without a single manual count.
-- ------------------------------------------------------------

-- 3a. names, drivers, routes, vehicle types: casing and stray spaces
WITH fixed AS (
    UPDATE cleaning
    SET passenger_name = INITCAP(TRIM(passenger_name)),
        driver_name    = INITCAP(TRIM(driver_name)),
        vehicle_type   = INITCAP(TRIM(vehicle_type)),
        route_from     = INITCAP(TRIM(route_from)),
        route_to       = INITCAP(TRIM(route_to))
    WHERE passenger_name <> INITCAP(TRIM(passenger_name))
       OR driver_name    <> INITCAP(TRIM(driver_name))
       OR vehicle_type   <> INITCAP(TRIM(vehicle_type))
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3a', 'name/driver/vehicle/route', 'INITCAP + TRIM', COUNT(*) FROM fixed;

-- 3b. blank passenger_city becomes 'Unknown' so it still shows in a GROUP BY
WITH fixed AS (
    UPDATE cleaning SET passenger_city = 'Unknown'
    WHERE passenger_city IS NULL OR TRIM(passenger_city) = ''
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3b', 'passenger_city', 'blank -> Unknown', COUNT(*) FROM fixed;

UPDATE cleaning SET passenger_city = INITCAP(TRIM(passenger_city));

-- 3c. gender: 8 spellings down to 2
WITH fixed AS (
    UPDATE cleaning
    SET passenger_gender = CASE
            WHEN UPPER(TRIM(passenger_gender)) IN ('MALE','M')   THEN 'Male'
            WHEN UPPER(TRIM(passenger_gender)) IN ('FEMALE','F') THEN 'Female'
            ELSE passenger_gender
        END
    WHERE passenger_gender NOT IN ('Male','Female')
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3c', 'passenger_gender', 'standardise spelling', COUNT(*) FROM fixed;

-- 3d. seat class: 9 spellings down to 2
WITH fixed AS (
    UPDATE cleaning
    SET seat_class = CASE
            WHEN UPPER(TRIM(seat_class)) IN ('ECONOMY','ECO','ECONOMY CLASS')   THEN 'Economy'
            WHEN UPPER(TRIM(seat_class)) IN ('BUSINESS','BUS','BUSINESS CLASS') THEN 'Business'
            ELSE seat_class
        END
    WHERE seat_class NOT IN ('Economy','Business')
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3d', 'seat_class', 'standardise spelling', COUNT(*) FROM fixed;

-- 3e. payment method: 10 spellings down to 3
WITH fixed AS (
    UPDATE cleaning
    SET payment_method = CASE
            WHEN UPPER(TRIM(payment_method)) IN ('MPESA','M-PESA','M PESA') THEN 'M-Pesa'
            WHEN UPPER(TRIM(payment_method)) = 'CASH'                       THEN 'Cash'
            WHEN UPPER(TRIM(payment_method)) = 'CARD'                       THEN 'Card'
            ELSE payment_method
        END
    WHERE payment_method NOT IN ('M-Pesa','Cash','Card')
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3e', 'payment_method', 'standardise spelling', COUNT(*) FROM fixed;

-- 3f. booking status: 8 spellings down to 3
WITH fixed AS (
    UPDATE cleaning
    SET booking_status = CASE
            WHEN UPPER(TRIM(booking_status)) = 'COMPLETED' THEN 'Completed'
            WHEN UPPER(TRIM(booking_status)) = 'CANCELLED' THEN 'Cancelled'
            WHEN UPPER(TRIM(booking_status)) = 'NO SHOW'   THEN 'No Show'
            ELSE booking_status
        END
    WHERE booking_status NOT IN ('Completed','Cancelled','No Show')
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3f', 'booking_status', 'standardise spelling', COUNT(*) FROM fixed;

-- 3g. phones Excel destroyed: scientific notation cannot be recovered
WITH fixed AS (
    UPDATE cleaning SET passenger_phone = NULL
    WHERE passenger_phone ~ 'E\+'
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3g', 'passenger_phone', 'scientific notation, unrecoverable -> NULL', COUNT(*) FROM fixed;

WITH fixed AS (
    UPDATE cleaning SET passenger_phone = NULL
    WHERE TRIM(passenger_phone) = ''     -- NULL does not match, so the 15 above are not counted again
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3g2', 'passenger_phone', 'blank -> NULL', COUNT(*) FROM fixed;

-- 3h. phones with dashes or a 254 prefix, and the lost leading zero
WITH fixed AS (
    UPDATE cleaning
    SET passenger_phone = REGEXP_REPLACE(passenger_phone, '[^0-9]', '', 'g')
    WHERE passenger_phone ~ '[^0-9]'
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3h', 'passenger_phone', 'strip non-digits', COUNT(*) FROM fixed;

UPDATE cleaning SET passenger_phone = '0' || SUBSTRING(passenger_phone FROM 4)
WHERE passenger_phone LIKE '254%';

WITH fixed AS (
    UPDATE cleaning SET passenger_phone = '0' || passenger_phone
    WHERE passenger_phone ~ '^7\d{8}$'
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3i', 'passenger_phone', 'restore leading zero', COUNT(*) FROM fixed;

-- 3j. fares stored as 'KES 2400' or 'KES 1,200'
WITH fixed AS (
    UPDATE cleaning
    SET total_fare    = REGEXP_REPLACE(total_fare,    '[^0-9.-]', '', 'g'),
        fare_per_seat = REGEXP_REPLACE(fare_per_seat, '[^0-9.-]', '', 'g')
    WHERE total_fare ~ '[^0-9.-]' OR fare_per_seat ~ '[^0-9.-]'
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3j', 'total_fare / fare_per_seat', 'strip currency text', COUNT(*) FROM fixed;

-- 3k. dates: DD/MM/YYYY, then the nine MM-DD-YYYY rows
WITH fixed AS (
    UPDATE cleaning SET departure_date = TO_DATE(departure_date, 'DD/MM/YYYY')::TEXT
    WHERE departure_date LIKE '%/%'
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3k', 'departure_date', 'DD/MM/YYYY -> ISO', COUNT(*) FROM fixed;

WITH fixed AS (
    UPDATE cleaning SET departure_date = TO_DATE(departure_date, 'MM-DD-YYYY')::TEXT
    WHERE departure_date ~ '^\d{2}-\d{2}-\d{4}$'
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3l', 'departure_date', 'MM-DD-YYYY -> ISO', COUNT(*) FROM fixed;

-- 3m. trip ratings of 0, 6 and 7. The rating is wrong, the booking is not,
--     so the field is emptied and the row still loads.
WITH fixed AS (
    UPDATE cleaning SET trip_rating = NULL
    WHERE TRIM(trip_rating) <> ''
      AND TRIM(trip_rating) NOT IN ('1','2','3','4','5')
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3m', 'trip_rating', 'outside 1-5 (0, 6, 7) -> NULL', COUNT(*) FROM fixed;

WITH fixed AS (
    UPDATE cleaning SET trip_rating = NULL
    WHERE TRIM(trip_rating) = ''         -- NULL does not match, so the 13 above are not counted again
    RETURNING 1
)
INSERT INTO cleaning_log (step, column_name, action, rows_affected)
SELECT '3m2', 'trip_rating', 'not given -> NULL', COUNT(*) FROM fixed;


-- ------------------------------------------------------------
-- 4. Row-level validation
--
--    Every check below is done on TEXT with a regex, never on a
--    cast. A cast inside the check would raise an error on the
--    first bad value and stop the whole load - which is exactly
--    what this file is written to avoid.
--
--    ARRAY_TO_STRING drops the NULLs, so a row that fails three
--    checks collects three reasons in one line.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS validated;
CREATE TABLE validated AS
WITH numbered AS (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY booking_id ORDER BY ctid) AS copy_no
    FROM cleaning c
)
SELECT *,
       NULLIF(ARRAY_TO_STRING(ARRAY[
           CASE WHEN booking_id IS NULL OR TRIM(booking_id) = ''
                THEN 'booking_id missing' END,
           CASE WHEN copy_no > 1
                THEN 'duplicate booking_id (copy ' || copy_no || ')' END,
           CASE WHEN seats_booked !~ '^\d+$' OR seats_booked::NUMERIC < 1
                THEN 'seats_booked is not a positive whole number: ' || COALESCE(seats_booked,'(empty)') END,
           CASE WHEN departure_date !~ '^\d{4}-\d{2}-\d{2}$'
                THEN 'departure_date not a valid date: ' || COALESCE(departure_date,'(empty)') END,
           CASE WHEN total_fare !~ '^\d+(\.\d+)?$'
                THEN 'total_fare is not a number: ' || COALESCE(total_fare,'(empty)') END,
           CASE WHEN fare_per_seat !~ '^\d+(\.\d+)?$'
                THEN 'fare_per_seat is not a number: ' || COALESCE(fare_per_seat,'(empty)') END,
           CASE WHEN passenger_gender NOT IN ('Male','Female')
                THEN 'unknown passenger_gender: ' || COALESCE(passenger_gender,'(empty)') END,
           CASE WHEN seat_class NOT IN ('Economy','Business')
                THEN 'unknown seat_class: ' || COALESCE(seat_class,'(empty)') END,
           CASE WHEN payment_method NOT IN ('M-Pesa','Cash','Card')
                THEN 'unknown payment_method: ' || COALESCE(payment_method,'(empty)') END,
           CASE WHEN booking_status NOT IN ('Completed','Cancelled','No Show')
                THEN 'unknown booking_status: ' || COALESCE(booking_status,'(empty)') END,
           CASE WHEN vehicle_type NOT IN ('Bus','Matatu','Minibus')
                THEN 'unknown vehicle_type: ' || COALESCE(vehicle_type,'(empty)') END
       ], '; '), '') AS reject_reason
FROM numbered;


-- ------------------------------------------------------------
-- 5. The failures, kept with their reason and their whole raw row
-- ------------------------------------------------------------
INSERT INTO rejected_bookings (booking_id, reject_reason, raw_row)
SELECT booking_id, reject_reason, raw_row
FROM validated
WHERE reject_reason IS NOT NULL;


-- ------------------------------------------------------------
-- 6. The survivors, loaded into the typed table
-- ------------------------------------------------------------
DROP TABLE IF EXISTS bookings CASCADE;
CREATE TABLE bookings (
    booking_id          VARCHAR(10) PRIMARY KEY,
    passenger_name      VARCHAR(100),
    passenger_phone     VARCHAR(15),
    passenger_gender    VARCHAR(10) CHECK (passenger_gender IN ('Male','Female')),
    passenger_city      VARCHAR(60),
    route_code          VARCHAR(10),
    route_from          VARCHAR(60),
    route_to            VARCHAR(60),
    vehicle_plate       VARCHAR(15),
    vehicle_type        VARCHAR(20) CHECK (vehicle_type IN ('Bus','Matatu','Minibus')),
    driver_name         VARCHAR(100),
    driver_rating       NUMERIC(3,1),
    departure_date      DATE,
    departure_time      VARCHAR(10),
    seat_class          VARCHAR(20) CHECK (seat_class IN ('Economy','Business')),
    seats_booked        INTEGER     CHECK (seats_booked > 0),
    fare_per_seat       NUMERIC(10,2),
    total_fare          NUMERIC(12,2),
    payment_method      VARCHAR(20) CHECK (payment_method IN ('M-Pesa','Cash','Card')),
    booking_status      VARCHAR(20) CHECK (booking_status IN ('Completed','Cancelled','No Show')),
    trip_rating         INTEGER     CHECK (trip_rating BETWEEN 1 AND 5)
);

INSERT INTO bookings
SELECT booking_id, passenger_name, passenger_phone, passenger_gender, passenger_city,
       route_code, route_from, route_to, vehicle_plate, vehicle_type, driver_name,
       driver_rating::NUMERIC, departure_date::DATE, departure_time, seat_class,
       seats_booked::INTEGER, fare_per_seat::NUMERIC, total_fare::NUMERIC,
       payment_method, booking_status, trip_rating::INTEGER
FROM validated
WHERE reject_reason IS NULL;

-- the analysis view, unchanged from 02
CREATE OR REPLACE VIEW v_clean_trips AS
SELECT *,
       TO_CHAR(departure_date, 'YYYY-MM')  AS travel_month,
       TO_CHAR(departure_date, 'Day')      AS day_name,
       EXTRACT(DOW FROM departure_date)    AS day_of_week,
       CASE
           WHEN trip_rating BETWEEN 4 AND 5 THEN 'Satisfied'
           WHEN trip_rating = 3             THEN 'Neutral'
           WHEN trip_rating BETWEEN 1 AND 2 THEN 'Unsatisfied'
           ELSE 'No Rating'
       END AS satisfaction
FROM bookings
WHERE booking_status = 'Completed';


-- ------------------------------------------------------------
-- 7. Reconcile. Nothing may vanish: in + rejected = loaded.
--    Expect 290 = 2 + 288, and the same 253 / 227810 / 452 as 02.
-- ------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM bookings_staging)   AS rows_in,
       (SELECT COUNT(*) FROM rejected_bookings)  AS rejected,
       (SELECT COUNT(*) FROM bookings)           AS loaded,
       (SELECT COUNT(*) FROM bookings)
     + (SELECT COUNT(*) FROM rejected_bookings)  AS accounted_for;

SELECT COUNT(*) AS completed_trips, SUM(total_fare) AS revenue, SUM(seats_booked) AS seats
FROM v_clean_trips;

-- what was refused, and why
SELECT booking_id, reject_reason FROM rejected_bookings ORDER BY reject_id;

-- what was repaired, and how much of it
SELECT step, column_name, action, rows_affected
FROM cleaning_log
WHERE rows_affected > 0
ORDER BY step;
