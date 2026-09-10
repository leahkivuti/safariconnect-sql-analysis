-- ============================================================
-- SafariConnect: 02 - clean the bookings and build the tables
--
-- Input : safari_connect.bookings_staging (290 raw rows, all TEXT)
-- Output: safari_connect.bookings       (typed, constrained)
--         safari_connect.v_clean_trips  (completed trips + derived columns)
--
-- Run 01_load_raw_data.sql first. The raw table is never changed;
-- all cleaning happens on a working copy.
-- ============================================================

SET search_path TO safari_connect;

-- ------------------------------------------------------------
-- 0. Audit before touching anything (run these, read the output)
-- ------------------------------------------------------------
SELECT passenger_gender, COUNT(*) FROM bookings_staging GROUP BY 1 ORDER BY 2 DESC;  -- 8 spellings
SELECT seat_class,       COUNT(*) FROM bookings_staging GROUP BY 1 ORDER BY 2 DESC;  -- 9 spellings
SELECT payment_method,   COUNT(*) FROM bookings_staging GROUP BY 1 ORDER BY 2 DESC;  -- 10 spellings
SELECT booking_status,   COUNT(*) FROM bookings_staging GROUP BY 1 ORDER BY 2 DESC;  -- 8 spellings
SELECT vehicle_type,     COUNT(*) FROM bookings_staging GROUP BY 1 ORDER BY 2 DESC;  -- 6 spellings

-- phones that are not 07XXXXXXXX: 277 of 290
SELECT passenger_phone, COUNT(*)
FROM bookings_staging
WHERE passenger_phone !~ '^0\d{9}$'
GROUP BY 1 ORDER BY 2 DESC;

-- dates: 281 rows DD/MM/YYYY, 9 rows MM-DD-YYYY, none in YYYY-MM-DD
SELECT CASE WHEN departure_date LIKE '%/%'              THEN 'DD/MM/YYYY'
            WHEN departure_date ~ '^\d{2}-\d{2}-\d{4}$' THEN 'MM-DD-YYYY'
            ELSE 'other' END AS date_format, COUNT(*)
FROM bookings_staging GROUP BY 1;


-- ------------------------------------------------------------
-- 1. Working copy
-- ------------------------------------------------------------
DROP TABLE IF EXISTS cleaning;
CREATE TABLE cleaning AS SELECT * FROM bookings_staging;


-- ------------------------------------------------------------
-- 2. Names, cities, drivers, vehicle types: casing and whitespace
-- ------------------------------------------------------------
UPDATE cleaning
SET passenger_name = INITCAP(TRIM(passenger_name)),
    driver_name    = INITCAP(TRIM(driver_name)),
    vehicle_type   = INITCAP(TRIM(vehicle_type)),
    route_from     = INITCAP(TRIM(route_from)),
    route_to       = INITCAP(TRIM(route_to));

-- blank cities become 'Unknown' rather than NULL so they still
-- appear in a GROUP BY
UPDATE cleaning SET passenger_city = 'Unknown'
WHERE passenger_city IS NULL OR TRIM(passenger_city) = '';

UPDATE cleaning SET passenger_city = INITCAP(TRIM(passenger_city));


-- ------------------------------------------------------------
-- 3. Category columns: many spellings -> the standard values
-- ------------------------------------------------------------
-- gender: 8 spellings -> Male / Female
UPDATE cleaning
SET passenger_gender = CASE
    WHEN UPPER(TRIM(passenger_gender)) IN ('MALE', 'M')   THEN 'Male'
    WHEN UPPER(TRIM(passenger_gender)) IN ('FEMALE', 'F') THEN 'Female'
    ELSE passenger_gender
END;

-- seat class: 9 spellings -> Economy / Business
UPDATE cleaning
SET seat_class = CASE
    WHEN UPPER(TRIM(seat_class)) IN ('ECONOMY', 'ECO', 'ECONOMY CLASS')     THEN 'Economy'
    WHEN UPPER(TRIM(seat_class)) IN ('BUSINESS', 'BUS', 'BUSINESS CLASS')   THEN 'Business'
    ELSE seat_class
END;

-- payment method: 10 spellings -> M-Pesa / Cash / Card
UPDATE cleaning
SET payment_method = CASE
    WHEN UPPER(TRIM(payment_method)) IN ('MPESA', 'M-PESA', 'M PESA') THEN 'M-Pesa'
    WHEN UPPER(TRIM(payment_method)) = 'CASH'                         THEN 'Cash'
    WHEN UPPER(TRIM(payment_method)) = 'CARD'                         THEN 'Card'
    ELSE payment_method
END;

-- booking status: 8 spellings -> Completed / Cancelled / No Show
UPDATE cleaning
SET booking_status = CASE
    WHEN UPPER(TRIM(booking_status)) = 'COMPLETED' THEN 'Completed'
    WHEN UPPER(TRIM(booking_status)) = 'CANCELLED' THEN 'Cancelled'
    WHEN UPPER(TRIM(booking_status)) = 'NO SHOW'   THEN 'No Show'
    ELSE booking_status
END;


-- ------------------------------------------------------------
-- 4. Phone numbers
--    The CSV had been opened and saved in Excel: 249 numbers lost
--    their leading zero, 15 became '2.54712E+11' (digits gone for
--    good), 13 had dashes, 13 were blank.
-- ------------------------------------------------------------
UPDATE cleaning SET passenger_phone = NULL
WHERE passenger_phone IS NULL OR TRIM(passenger_phone) = '' OR passenger_phone ~ 'E\+';

UPDATE cleaning
SET passenger_phone = REGEXP_REPLACE(passenger_phone, '[^0-9]', '', 'g')
WHERE passenger_phone IS NOT NULL;

UPDATE cleaning
SET passenger_phone = '0' || SUBSTRING(passenger_phone FROM 4)
WHERE passenger_phone LIKE '254%';

UPDATE cleaning
SET passenger_phone = '0' || passenger_phone
WHERE passenger_phone ~ '^7\d{8}$';


-- ------------------------------------------------------------
-- 5. Fares stored as text ('KES 2400', 'KES 1,200')
-- ------------------------------------------------------------
UPDATE cleaning
SET total_fare    = REGEXP_REPLACE(total_fare,    '[^0-9.-]', '', 'g'),
    fare_per_seat = REGEXP_REPLACE(fare_per_seat, '[^0-9.-]', '', 'g');


-- ------------------------------------------------------------
-- 6. Dates: one UPDATE per format, identified by the separator
-- ------------------------------------------------------------
UPDATE cleaning
SET departure_date = TO_DATE(departure_date, 'DD/MM/YYYY')::TEXT
WHERE departure_date LIKE '%/%';

UPDATE cleaning
SET departure_date = TO_DATE(departure_date, 'MM-DD-YYYY')::TEXT
WHERE departure_date ~ '^\d{2}-\d{2}-\d{4}$';

-- must return zero rows
SELECT booking_id, departure_date FROM cleaning
WHERE departure_date !~ '^\d{4}-\d{2}-\d{2}$';


-- ------------------------------------------------------------
-- 7. Ratings outside 1-5 (0, 6, 7 and blanks) -> NULL
-- ------------------------------------------------------------
UPDATE cleaning SET trip_rating = NULL
WHERE TRIM(trip_rating) NOT IN ('1', '2', '3', '4', '5');


-- ------------------------------------------------------------
-- 8. The duplicate (BK0005 twice) and the negative-seat row
--    290 rows -> 288
-- ------------------------------------------------------------
DELETE FROM cleaning
WHERE ctid NOT IN (SELECT MIN(ctid) FROM cleaning GROUP BY booking_id);

DELETE FROM cleaning WHERE seats_booked::INTEGER < 1;


-- ------------------------------------------------------------
-- 9. Production table: real types, and the rules written in as
--    CHECK constraints. If any spelling slipped through the
--    cleaning, this INSERT refuses it and says which value.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS bookings CASCADE;

CREATE TABLE bookings (
    booking_id        VARCHAR(10)   PRIMARY KEY,
    passenger_name    VARCHAR(100),
    passenger_phone   VARCHAR(15),
    passenger_gender  VARCHAR(10)   CHECK (passenger_gender IN ('Male', 'Female')),
    passenger_city    VARCHAR(60),
    route_code        VARCHAR(10),
    route_from        VARCHAR(60),
    route_to          VARCHAR(60),
    vehicle_plate     VARCHAR(15),
    vehicle_type      VARCHAR(20)   CHECK (vehicle_type IN ('Bus', 'Matatu', 'Minibus')),
    driver_name       VARCHAR(100),
    driver_rating     NUMERIC(3,1),
    departure_date    DATE,
    departure_time    VARCHAR(10),
    seat_class        VARCHAR(20)   CHECK (seat_class IN ('Economy', 'Business')),
    seats_booked      INTEGER       CHECK (seats_booked > 0),
    fare_per_seat     NUMERIC(10,2),
    total_fare        NUMERIC(12,2),
    payment_method    VARCHAR(20)   CHECK (payment_method IN ('M-Pesa', 'Cash', 'Card')),
    booking_status    VARCHAR(20)   CHECK (booking_status IN ('Completed', 'Cancelled', 'No Show')),
    trip_rating       INTEGER       CHECK (trip_rating BETWEEN 1 AND 5)
);

INSERT INTO bookings
SELECT booking_id, passenger_name, passenger_phone, passenger_gender, passenger_city,
       route_code, route_from, route_to, vehicle_plate, vehicle_type,
       driver_name, driver_rating::NUMERIC, departure_date::DATE, departure_time,
       seat_class, seats_booked::INTEGER, fare_per_seat::NUMERIC, total_fare::NUMERIC,
       payment_method, booking_status, trip_rating::INTEGER
FROM cleaning;


-- ------------------------------------------------------------
-- 10. The analysis view: completed trips only, plus the derived
--     columns the six questions need
-- ------------------------------------------------------------
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
-- 11. The three numbers everything else is checked against
--     expect 290 staging, 288 production, 253 / 227810 / 452
-- ------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM bookings_staging) AS staging_rows,
       (SELECT COUNT(*) FROM bookings)         AS production_rows;

SELECT COUNT(*) AS completed_trips, SUM(total_fare) AS revenue, SUM(seats_booked) AS seats
FROM v_clean_trips;
