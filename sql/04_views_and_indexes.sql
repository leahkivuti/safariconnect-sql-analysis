-- ============================================================
-- SafariConnect: 04 - views for the dashboard, and indexes
--
-- Power BI connects to these views, never to the raw or staging
-- tables. A view holds no data of its own: change a row in
-- bookings and every view reflects it on the next query, so the
-- SQL lives in one place and the BI tool only asks for results.
-- All views use CREATE OR REPLACE, so this file is safe to re-run.
-- ============================================================

SET search_path TO safari_connect;

-- Route performance (Q1)
CREATE OR REPLACE VIEW v_route_performance AS
SELECT route_code,
       route_from || ' -> ' || route_to AS route,
       COUNT(*)                         AS bookings,
       SUM(seats_booked)                AS seats,
       SUM(total_fare)                  AS revenue,
       ROUND(AVG(trip_rating), 2)       AS avg_rating
FROM v_clean_trips
GROUP BY route_code, route_from, route_to;

-- Driver performance (Q2)
CREATE OR REPLACE VIEW v_driver_performance AS
SELECT driver_name,
       COUNT(*)                   AS total_trips,
       SUM(total_fare)            AS total_driver_revenue,
       ROUND(AVG(trip_rating), 2) AS avg_trip_rating,
       MAX(driver_rating)         AS driver_rating
FROM v_clean_trips
GROUP BY driver_name;

-- Monthly revenue trend (Q3)
CREATE OR REPLACE VIEW v_monthly_revenue AS
WITH monthly AS (
    SELECT TO_CHAR(departure_date, 'YYYY-MM') AS month,
           COUNT(*)        AS bookings,
           SUM(total_fare) AS revenue
    FROM v_clean_trips
    GROUP BY 1
)
SELECT month, bookings, revenue,
       revenue - LAG(revenue) OVER (ORDER BY month) AS change,
       ROUND((revenue - LAG(revenue) OVER (ORDER BY month))
             / NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100, 1) AS change_pct
FROM monthly;

-- Passenger city insights (Q4)
CREATE OR REPLACE VIEW v_passenger_insights AS
SELECT passenger_city,
       COUNT(*)                     AS total_bookings,
       SUM(total_fare)              AS total_revenue_per_city,
       ROUND(AVG(fare_per_seat), 0) AS total_average_fare
FROM v_clean_trips
GROUP BY passenger_city;

-- Cancellation analysis (Q5) - on bookings, so it sees every status
CREATE OR REPLACE VIEW v_cancellation_analysis AS
SELECT route_code,
       route_from || ' -> ' || route_to AS route,
       COUNT(*)                                                          AS total_bookings,
       SUM(CASE WHEN booking_status = 'Completed' THEN 1 ELSE 0 END)     AS completed,
       SUM(CASE WHEN booking_status = 'Cancelled' THEN 1 ELSE 0 END)     AS cancelled,
       SUM(CASE WHEN booking_status = 'No Show'   THEN 1 ELSE 0 END)     AS no_show,
       ROUND(SUM(CASE WHEN booking_status IN ('Cancelled', 'No Show') THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 1)                                      AS cancel_rate_pct,
       SUM(CASE WHEN booking_status IN ('Cancelled', 'No Show') THEN total_fare ELSE 0 END) AS lost_revenue
FROM bookings
GROUP BY route_code, route_from, route_to;


-- ------------------------------------------------------------
-- Indexes on the columns the views group and filter by
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_depdate  ON bookings (departure_date);
CREATE INDEX IF NOT EXISTS idx_bookings_route    ON bookings (route_code);
CREATE INDEX IF NOT EXISTS idx_bookings_driver   ON bookings (driver_name);
CREATE INDEX IF NOT EXISTS idx_bookings_status   ON bookings (booking_status);
CREATE INDEX IF NOT EXISTS idx_bookings_payment  ON bookings (payment_method);
CREATE INDEX IF NOT EXISTS idx_bookings_vehicle  ON bookings (vehicle_type);
CREATE INDEX IF NOT EXISTS idx_bookings_passcity ON bookings (passenger_city);


-- ------------------------------------------------------------
-- Checks: 5 views + v_clean_trips, 7 indexes + the primary key
-- ------------------------------------------------------------
SELECT viewname  FROM pg_views   WHERE schemaname = 'safari_connect' ORDER BY 1;
SELECT indexname FROM pg_indexes WHERE schemaname = 'safari_connect' ORDER BY 1;

SELECT * FROM v_route_performance ORDER BY revenue DESC;
SELECT * FROM v_monthly_revenue   ORDER BY month;
