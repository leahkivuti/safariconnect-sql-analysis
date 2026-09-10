-- ============================================================
-- SafariConnect: 03 - the six business questions
--
-- Run 01 and 02 first. Every query below runs on v_clean_trips
-- (completed trips only) except question 5, which needs the
-- cancelled and no-show rows and so uses bookings directly.
-- Key results are noted above each query so you can compare.
-- Totals to check against: 253 trips, KES 227,810, 452 seats.
-- ============================================================

SET search_path TO safari_connect;


-- ============================================================
-- Q1. ROUTES: which routes make money, which are popular,
--     which earn the most per seat?
-- ============================================================

-- 1A. Revenue and bookings by route
--     RT001 Nairobi -> Mombasa 51,600 from 41 seats (top)
--     RT005 Nairobi -> Thika 7,620 from 62 seats (most seats, worst earner)
SELECT route_code,
       route_from || ' -> ' || route_to  AS route,
       COUNT(*)                          AS bookings,
       SUM(seats_booked)                 AS seats,
       SUM(total_fare)                   AS revenue,
       ROUND(AVG(fare_per_seat), 0)      AS avg_fare,
       ROUND(AVG(trip_rating), 2)        AS avg_rating
FROM v_clean_trips
GROUP BY route_code, route_from, route_to
ORDER BY revenue DESC;

-- 1B. Revenue per seat sold (efficiency)
--     Mombasa about 1,259 per seat; Thika about 123
SELECT route_code,
       route_from || ' -> ' || route_to          AS route,
       SUM(total_fare)                           AS revenue,
       SUM(seats_booked)                         AS seats,
       ROUND(SUM(total_fare) / SUM(seats_booked), 0) AS revenue_per_seat
FROM v_clean_trips
GROUP BY route_code, route_from, route_to
ORDER BY revenue_per_seat DESC;

-- 1C. Rank and share of total (window functions)
--     Top three routes = 58.5% of revenue; RT001 alone 22.7%
WITH route_rev AS (
    SELECT route_code, SUM(total_fare) AS revenue
    FROM v_clean_trips
    GROUP BY route_code
)
SELECT route_code,
       revenue,
       RANK() OVER (ORDER BY revenue DESC)              AS revenue_rank,
       ROUND(revenue * 100.0 / SUM(revenue) OVER (), 1) AS pct_of_total
FROM route_rev
ORDER BY revenue_rank;

-- 1D. Vehicle type
--     Matatu 38.6% of revenue, Bus 37.1%, Minibus 24.3%;
--     Minibus has the best average rating (3.71)
SELECT vehicle_type,
       COUNT(*)                                          AS trips,
       SUM(total_fare)                                   AS revenue,
       ROUND(SUM(total_fare) * 100.0 / SUM(SUM(total_fare)) OVER (), 1) AS pct_of_revenue,
       ROUND(AVG(trip_rating), 2)                        AS avg_rating
FROM v_clean_trips
GROUP BY vehicle_type
ORDER BY revenue DESC;


-- ============================================================
-- Q2. DRIVERS: who should be promoted, and does the platform's
--     driver rating predict passenger satisfaction?
-- ============================================================

-- 2A. Driver summary
--     Isaac Korir top on revenue (33,045 from 33 trips) with the
--     lowest driver rating (3.8); Moses Kipchoge has the highest
--     driver rating (4.8) and the lowest passenger rating (3.19)
SELECT driver_name,
       COUNT(*)                    AS trips,
       SUM(seats_booked)           AS seats,
       SUM(total_fare)             AS revenue,
       ROUND(AVG(trip_rating), 2)  AS avg_trip_rating,
       MAX(driver_rating)          AS driver_rating
FROM v_clean_trips
GROUP BY driver_name
ORDER BY revenue DESC;

-- 2B. Rank overall and within vehicle type (CTE + PARTITION BY)
--     Isaac Korir 1st overall and 1st among Matatu drivers;
--     Kelvin Omondi 2nd overall but 1st among Bus drivers
WITH driver_totals AS (
    SELECT driver_name, vehicle_type,
           COUNT(*)                   AS trips,
           SUM(total_fare)            AS revenue,
           ROUND(AVG(trip_rating), 2) AS avg_trip_rating
    FROM v_clean_trips
    GROUP BY driver_name, vehicle_type
)
SELECT driver_name, vehicle_type, trips, revenue, avg_trip_rating,
       RANK() OVER (ORDER BY revenue DESC)                              AS overall_rank,
       RANK() OVER (PARTITION BY vehicle_type ORDER BY revenue DESC)    AS rank_in_vehicle_type
FROM driver_totals
ORDER BY overall_rank;

-- 2C. Does driver rating predict passenger satisfaction?
--     High-rated drivers: 95 trips, avg passenger rating 3.38
--     Standard drivers:  158 trips, avg passenger rating 3.62
SELECT CASE WHEN driver_rating >= 4.5 THEN 'High-rated (4.5+)'
            ELSE 'Standard (<4.5)' END      AS driver_group,
       COUNT(*)                              AS trips,
       ROUND(AVG(trip_rating), 2)            AS avg_passenger_rating
FROM v_clean_trips
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- Q3. REVENUE TRENDS: month by month
-- ============================================================

-- 3A. Monthly revenue, change on the previous month, running total
--     August 2024 worst (13,400, down 41.4%); October best (24,190);
--     running total 226,125 by December; January 2025 is a partial month
WITH monthly AS (
    SELECT TO_CHAR(departure_date, 'YYYY-MM') AS month,
           COUNT(*)        AS bookings,
           SUM(total_fare) AS revenue
    FROM v_clean_trips
    GROUP BY 1
)
SELECT month, bookings, revenue,
       LAG(revenue) OVER (ORDER BY month)                        AS prev_month,
       revenue - LAG(revenue) OVER (ORDER BY month)              AS change,
       ROUND((revenue - LAG(revenue) OVER (ORDER BY month))
             / NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100, 1) AS change_pct,
       SUM(revenue) OVER (ORDER BY month)                        AS running_total
FROM monthly
ORDER BY month;

-- 3B. Best and worst three months
WITH monthly AS (
    SELECT TO_CHAR(departure_date, 'YYYY-MM') AS month, SUM(total_fare) AS revenue
    FROM v_clean_trips
    GROUP BY 1
),
ranked AS (
    SELECT month, revenue,
           RANK() OVER (ORDER BY revenue DESC) AS best_rank,
           RANK() OVER (ORDER BY revenue ASC)  AS worst_rank
    FROM monthly
)
SELECT month, revenue,
       CASE WHEN best_rank <= 3 THEN 'Top 3' ELSE 'Bottom 3' END AS position
FROM ranked
WHERE best_rank <= 3 OR worst_rank <= 3
ORDER BY revenue DESC;


-- ============================================================
-- Q4. PASSENGERS: where they come from, what they book,
--     whether they are satisfied
-- ============================================================

-- 4A. Top cities (3+ bookings)
--     Nairobi 113 trips, KES 112,000, just under half of all revenue
SELECT passenger_city,
       COUNT(*)                     AS bookings,
       SUM(seats_booked)            AS seats,
       SUM(total_fare)              AS revenue,
       ROUND(AVG(fare_per_seat), 0) AS avg_fare
FROM v_clean_trips
GROUP BY passenger_city
HAVING COUNT(*) >= 3
ORDER BY bookings DESC;

-- 4B. Gender and seat class (CASE WHEN pivot)
--     Women 137 trips / 120,885; men 116 / 106,925; Economy about 80% for both
SELECT passenger_gender,
       COUNT(*)                                                    AS bookings,
       SUM(total_fare)                                             AS revenue,
       SUM(CASE WHEN seat_class = 'Economy'  THEN 1 ELSE 0 END)     AS economy_bookings,
       SUM(CASE WHEN seat_class = 'Business' THEN 1 ELSE 0 END)     AS business_bookings,
       ROUND(SUM(CASE WHEN seat_class = 'Economy' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS economy_pct
FROM v_clean_trips
GROUP BY passenger_gender
ORDER BY bookings DESC;

-- 4C. Satisfaction breakdown (CTE + percentage of total)
--     Satisfied 46.2%, Neutral 28.9%, Unsatisfied 19.4%, No Rating 5.5%
WITH sat_counts AS (
    SELECT satisfaction, COUNT(*) AS trips
    FROM v_clean_trips
    GROUP BY satisfaction
)
SELECT satisfaction, trips,
       ROUND(trips * 100.0 / SUM(trips) OVER (), 1) AS pct
FROM sat_counts
ORDER BY trips DESC;

-- 4D. Passenger spend quartiles (NTILE)
WITH spend AS (
    SELECT passenger_name, SUM(total_fare) AS total_spent
    FROM v_clean_trips
    GROUP BY passenger_name
)
SELECT passenger_name, total_spent,
       NTILE(4) OVER (ORDER BY total_spent) AS quartile,
       CASE WHEN NTILE(4) OVER (ORDER BY total_spent) = 4 THEN 'Top Spender' END AS label
FROM spend
ORDER BY total_spent DESC;


-- ============================================================
-- Q5. CANCELLATIONS: rate and cost (uses bookings, not the view)
-- ============================================================

-- 5A. Status breakdown
--     Completed 253 (87.8%), Cancelled 21 (7.3%), No Show 14 (4.9%)
SELECT booking_status,
       COUNT(*)        AS bookings,
       SUM(total_fare) AS fare_value,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM bookings
GROUP BY booking_status
ORDER BY bookings DESC;

-- 5B. Cancellation rate by route
--     RT006 Mombasa -> Malindi worst (18.5%); RT004 best (3.6%)
SELECT route_code,
       route_from || ' -> ' || route_to AS route,
       COUNT(*)                                                          AS total,
       SUM(CASE WHEN booking_status = 'Completed' THEN 1 ELSE 0 END)     AS completed,
       SUM(CASE WHEN booking_status = 'Cancelled' THEN 1 ELSE 0 END)     AS cancelled,
       SUM(CASE WHEN booking_status = 'No Show'   THEN 1 ELSE 0 END)     AS no_show,
       ROUND(SUM(CASE WHEN booking_status IN ('Cancelled', 'No Show') THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 1)                                      AS cancel_rate_pct
FROM bookings
GROUP BY route_code, route_from, route_to
ORDER BY cancel_rate_pct DESC;

-- 5C. Revenue lost to cancellations and no-shows
--     KES 32,150 = 12.4% of the revenue actually earned
SELECT SUM(CASE WHEN booking_status IN ('Cancelled', 'No Show') THEN total_fare ELSE 0 END) AS lost_revenue,
       SUM(CASE WHEN booking_status = 'Completed'               THEN total_fare ELSE 0 END) AS earned_revenue,
       ROUND(SUM(CASE WHEN booking_status IN ('Cancelled', 'No Show') THEN total_fare ELSE 0 END) * 100.0
             / SUM(CASE WHEN booking_status = 'Completed' THEN total_fare ELSE 0 END), 1)     AS lost_as_pct_of_earned
FROM bookings;


-- ============================================================
-- Q6. OPERATIONS: busiest days and times
-- ============================================================

-- 6A. Day of week
--     Monday to Thursday carry the business (44-49 trips each); Sunday 10
SELECT EXTRACT(DOW FROM departure_date) AS day_num,
       TO_CHAR(departure_date, 'Day')   AS day_name,
       COUNT(*)                         AS bookings,
       SUM(total_fare)                  AS revenue,
       ROUND(AVG(total_fare), 0)        AS avg_booking_value
FROM v_clean_trips
GROUP BY 1, 2
ORDER BY 1;

-- 6B. Departure time
--     09:00 and 06:00 carry the most seats; 19:00 earns the most (22,240)
SELECT departure_time,
       COUNT(*)           AS bookings,
       SUM(seats_booked)  AS seats,
       SUM(total_fare)    AS revenue
FROM v_clean_trips
GROUP BY departure_time
ORDER BY revenue DESC;

-- 6C. Seat load by vehicle type
--     Average seats per booking under 2 for every type
SELECT vehicle_type,
       ROUND(AVG(seats_booked), 2) AS avg_seats_booked,
       CASE WHEN AVG(seats_booked) > 3 THEN 'High Load'
            WHEN AVG(seats_booked) >= 2 THEN 'Medium Load'
            ELSE 'Low Load' END    AS load_label
FROM v_clean_trips
GROUP BY vehicle_type
ORDER BY avg_seats_booked DESC;
