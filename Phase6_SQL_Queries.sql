-- PHASE 6: FROM QUERIES TO CLARITY — SQL ANALYSIS
-- Project: Analyze Food Delivery Demand Across Regions
-- Tables : customers, delivery_partners, orders, restaurant_cleaned

USE food_deliveries;

-- FIX BOM-PREFIXED PRIMARY KEY COLUMNS 
-- Each table was exported with a UTF-8 BOM character glued onto the
-- first column name (e.g. Customer_Id shows up as `ï»¿Customer_Id`).
-- That makes every join painful/impossible to type. Rename them once.
-- =====================================================================
ALTER TABLE customers
  CHANGE COLUMN `ï»¿Customer_Id` `Customer_ID` TEXT;

ALTER TABLE restaurant_cleaned
  CHANGE COLUMN `ï»¿Restaurant_ID` `Restaurant_ID` TEXT;

ALTER TABLE delivery_partners
  CHANGE COLUMN `ï»¿Delivery_Partner_ID` `Delivery_Partner_ID` TEXT;

ALTER TABLE orders
  CHANGE COLUMN `ï»¿Row_ID` `Row_ID` TEXT;

-- Sanity check the columns look right now
DESCRIBE customers;
DESCRIBE delivery_partners;
DESCRIBE orders;
DESCRIBE restaurant_cleaned;

-- =====================================================================
-- RELATIONSHIPS (4 tables connect)
-- orders.Customer_ID          -> customers.Customer_ID
-- orders.Restaurant_ID        -> restaurant_cleaned.Restaurant_ID
-- orders.Delivery_Partner_ID  -> delivery_partners.Delivery_Partner_ID
-- orders.Region               -> also present on delivery_partners.Region
--   (restaurant_cleaned has City instead of Region — join via
--    Restaurant_ID, not Region, when you need restaurant-level detail)
-- =====================================================================


-- =====================================================================
-- STEP 1: SQL FOUNDATIONS & FILTERING
-- =====================================================================

-- 1a. Basic filter: all delivered orders in Urban region, highest value first
SELECT Order_ID, Order_Date, Region, Final_Amount, Order_Status
FROM orders
WHERE Region = 'Urban' AND Order_Status = 'Delivered'
ORDER BY Final_Amount DESC
LIMIT 20;

-- 1b. Filter + sort: cancelled/returned orders (the "at risk" orders)
SELECT Order_ID, Order_Date, Region, Order_Status, Final_Amount
FROM orders
WHERE Order_Status IN ('Cancelled', 'Returned')
ORDER BY Order_Date;

-- 1c. Grouping check: row counts per table (data readiness validation)
SELECT 'orders' AS table_name, COUNT(*) AS row_count FROM orders
UNION ALL
SELECT 'customers', COUNT(*) FROM customers
UNION ALL
SELECT 'delivery_partners', COUNT(*) FROM delivery_partners
UNION ALL
SELECT 'restaurant_cleaned', COUNT(*) FROM restaurant_cleaned;

-- 1d. Null / orphan check before joining (validate dataset readiness)
SELECT COUNT(*) AS orders_missing_customer
FROM orders o
LEFT JOIN customers c ON o.Customer_ID = c.Customer_ID
WHERE c.Customer_ID IS NULL;

SELECT COUNT(*) AS orders_missing_restaurant
FROM orders o
LEFT JOIN restaurant_cleaned r ON o.Restaurant_ID = r.Restaurant_ID
WHERE r.Restaurant_ID IS NULL;

SELECT COUNT(*) AS orders_missing_partner
FROM orders o
LEFT JOIN delivery_partners dp ON o.Delivery_Partner_ID = dp.Delivery_Partner_ID
WHERE dp.Delivery_Partner_ID IS NULL;


-- =====================================================================
-- STEP 2: JOINS FOR INTEGRATED INSIGHTS
-- =====================================================================

-- 2a. INNER JOIN: fully-matched order records across all 4 tables
SELECT
    o.Order_ID, o.Order_Date, o.Region, o.Final_Amount, o.Net_Revenue,
    o.Order_Status, o.Delivery_Time_Minutes, o.Order_Rating,
    c.Gender, c.Age_Group, c.Customer_Type, c.Preferred_Cuisine,
    r.Restaurant_Name, r.Cuisine_Type, r.Avg_Rating AS Restaurant_Rating,
    dp.Partner_Name, dp.Vehicle_Type, dp.Avg_Delivery_Speed_KMPH
FROM orders o
INNER JOIN customers c          ON o.Customer_ID = c.Customer_ID
INNER JOIN restaurant_cleaned r ON o.Restaurant_ID = r.Restaurant_ID
INNER JOIN delivery_partners dp ON o.Delivery_Partner_ID = dp.Delivery_Partner_ID
LIMIT 50;

-- 2b. LEFT JOIN: keep every order even if a linked record is missing
-- ( for reporting so no order silently disappears)
SELECT
    o.Order_ID, o.Region, o.Final_Amount, o.Order_Status,
    c.Customer_Type, r.Restaurant_Name, dp.Partner_Name
FROM orders o
LEFT JOIN customers c          ON o.Customer_ID = c.Customer_ID
LEFT JOIN restaurant_cleaned r ON o.Restaurant_ID = r.Restaurant_ID
LEFT JOIN delivery_partners dp ON o.Delivery_Partner_ID = dp.Delivery_Partner_ID
LIMIT 50;

-- 2c. Sub-query example: orders placed by "Loyal" customers only
SELECT Order_ID, Region, Final_Amount, Order_Status
FROM orders
WHERE Customer_ID IN (
    SELECT Customer_ID FROM customers WHERE Customer_Type = 'Loyal'
)
ORDER BY Final_Amount DESC
LIMIT 20;

-- 2d. Sub-query + aggregation: restaurants that beat the platform's
-- average rating (comparing an aggregate against another aggregate)
SELECT Restaurant_ID, Restaurant_Name, Cuisine_Type, Avg_Rating
FROM restaurant_cleaned
WHERE Avg_Rating > (SELECT AVG(Avg_Rating) FROM restaurant_cleaned)
ORDER BY Avg_Rating DESC;


-- =====================================================================
-- STEP 3: AGGREGATIONS & GROUPING —  20 BUSINESS QUESTIONS
-- =====================================================================

-- --------- OBJECTIVE 1: REGIONAL DEMAND & MARKET EXPANSION ----------

-- Q1. Which regions generate the highest order volume and Net_Revenue?
SELECT Region,
       COUNT(*)            AS Total_Orders,
       SUM(Net_Revenue)    AS Total_Net_Revenue
FROM orders
GROUP BY Region
ORDER BY Total_Net_Revenue DESC;

-- Q2. Average Final_Amount per order, by region
SELECT Region,
       ROUND(AVG(Final_Amount), 2) AS Avg_Final_Amount,
       COUNT(*)                    AS Order_Count
FROM orders
GROUP BY Region
ORDER BY Avg_Final_Amount DESC;

-- 
WITH customer_region AS (
    SELECT Customer_ID, Region,
           ROW_NUMBER() OVER (PARTITION BY Customer_ID ORDER BY COUNT(*) DESC) AS rn
    FROM orders
    GROUP BY Customer_ID, Region
)
SELECT cr.Region,
       ROUND(AVG(c.Total_Orders), 2) AS Avg_Customer_Total_Orders,
       COUNT(DISTINCT cr.Customer_ID) AS Customers
FROM customer_region cr
JOIN customers c ON cr.Customer_ID = c.Customer_ID
WHERE cr.rn = 1
GROUP BY cr.Region
ORDER BY Avg_Customer_Total_Orders DESC;

-- Q4. Order volume during Festival_Flag periods, by region
SELECT Region, Festival_Flag, COUNT(*) AS Order_Count
FROM orders
GROUP BY Region, Festival_Flag
ORDER BY Region, Festival_Flag;

-- --------- OBJECTIVE 2: CUSTOMER BEHAVIOR & LOYALTY ----------

-- Q5. Average_Spend across Customer_Type
SELECT Customer_Type,
       ROUND(AVG(Average_Spend), 2) AS Avg_Spend,
       COUNT(*) AS Customers
FROM customers
GROUP BY Customer_Type
ORDER BY Avg_Spend DESC;

-- Q6. Top Preferred_Cuisine per Customer_Type
WITH cuisine_counts AS (
    SELECT Customer_Type, Preferred_Cuisine, COUNT(*) AS Cnt,
           ROW_NUMBER() OVER (PARTITION BY Customer_Type ORDER BY COUNT(*) DESC) AS rn
    FROM customers
    GROUP BY Customer_Type, Preferred_Cuisine
)
SELECT Customer_Type, Preferred_Cuisine, Cnt
FROM cuisine_counts
WHERE rn = 1;

-- Q7. Correlation between Total_Orders and Average_Spend (customer level)
-- MySQL has no built-in CORR(); Pearson's r computed manually.
SELECT
    ( SUM(Total_Orders * Average_Spend)
      - COUNT(*) * AVG(Total_Orders) * AVG(Average_Spend) )
    / ( COUNT(*) * STDDEV_POP(Total_Orders) * STDDEV_POP(Average_Spend) )
    AS Pearson_Correlation_Orders_Spend
FROM customers;

-- Q8. Order_Rating across customer segments
SELECT c.Customer_Type,
       ROUND(AVG(o.Order_Rating), 2) AS Avg_Order_Rating,
       COUNT(*) AS Rated_Orders
FROM orders o
JOIN customers c ON o.Customer_ID = c.Customer_ID
WHERE o.Rating_Valid_Flag = 'TRUE'
GROUP BY c.Customer_Type
ORDER BY Avg_Order_Rating DESC;

-- Q9. Preferred Payment_Mode per Customer_Type
WITH payment_counts AS (
    SELECT c.Customer_Type, o.Payment_Mode, COUNT(*) AS Cnt,
           ROW_NUMBER() OVER (PARTITION BY c.Customer_Type ORDER BY COUNT(*) DESC) AS rn
    FROM orders o
    JOIN customers c ON o.Customer_ID = c.Customer_ID
    GROUP BY c.Customer_Type, o.Payment_Mode
)
SELECT Customer_Type, Payment_Mode, Cnt
FROM payment_counts
WHERE rn = 1;

-- Q10. Does Age_Group influence Preferred_Cuisine choice?
WITH age_cuisine AS (
    SELECT Age_Group, Preferred_Cuisine, COUNT(*) AS Cnt,
           ROW_NUMBER() OVER (PARTITION BY Age_Group ORDER BY COUNT(*) DESC) AS rn
    FROM customers
    GROUP BY Age_Group, Preferred_Cuisine
)
SELECT Age_Group, Preferred_Cuisine AS Top_Cuisine, Cnt
FROM age_cuisine
WHERE rn = 1
ORDER BY Age_Group;

-- --------- OBJECTIVE 3: DELIVERY PARTNER & LOGISTICS EFFICIENCY ----------

-- Q11. Avg_Delivery_Speed_KMPH by Vehicle_Type
SELECT Vehicle_Type,
       ROUND(AVG(Avg_Delivery_Speed_KMPH), 2) AS Avg_Speed_KMPH,
       COUNT(*) AS Partners
FROM delivery_partners
GROUP BY Vehicle_Type
ORDER BY Avg_Speed_KMPH DESC;

-- Q12. Relationship between Delivery_Efficiency_Score and Avg_Customer_Rating
SELECT
    ( SUM(Delivery_Efficiency_Score * Avg_Customer_Rating)
      - COUNT(*) * AVG(Delivery_Efficiency_Score) * AVG(Avg_Customer_Rating) )
    / ( COUNT(*) * STDDEV_POP(Delivery_Efficiency_Score) * STDDEV_POP(Avg_Customer_Rating) )
    AS Pearson_Correlation_Efficiency_Rating
FROM delivery_partners;

-- Q13. Delayed_Deliveries by Region
SELECT Region,
       SUM(Delayed_Deliveries)            AS Total_Delayed,
       ROUND(AVG(Delayed_Deliveries), 2)  AS Avg_Delayed_Per_Partner,
       COUNT(*)                           AS Partners
FROM delivery_partners
GROUP BY Region
ORDER BY Total_Delayed DESC;

-- Q14. Does Delivery_Time_Minutes impact Order_Rating?
-- 14a. Bucketed view
SELECT
    CASE
        WHEN Delivery_Time_Minutes < 25 THEN '<25 min'
        WHEN Delivery_Time_Minutes BETWEEN 25 AND 34 THEN '25-34 min'
        WHEN Delivery_Time_Minutes BETWEEN 35 AND 44 THEN '35-44 min'
        ELSE '45+ min'
    END AS Delivery_Time_Bucket,
    ROUND(AVG(Order_Rating), 2) AS Avg_Order_Rating,
    COUNT(*) AS Orders
FROM orders
WHERE Rating_Valid_Flag = 'TRUE'
GROUP BY Delivery_Time_Bucket
ORDER BY Delivery_Time_Bucket;

-- 14b. Direct correlation
SELECT
    ( SUM(Delivery_Time_Minutes * Order_Rating)
      - COUNT(*) * AVG(Delivery_Time_Minutes) * AVG(Order_Rating) )
    / ( COUNT(*) * STDDEV_POP(Delivery_Time_Minutes) * STDDEV_POP(Order_Rating) )
    AS Pearson_Correlation_DeliveryTime_Rating
FROM orders
WHERE Rating_Valid_Flag = 'TRUE';

-- --------- OBJECTIVE 4: RESTAURANT PERFORMANCE & CAPACITY ----------

-- Q15. Avg_Preparation_Time_Minutes vs Avg_Rating (restaurant level)
SELECT
    ( SUM(Avg_Preparation_Time_Minutes * Avg_Rating)
      - COUNT(*) * AVG(Avg_Preparation_Time_Minutes) * AVG(Avg_Rating) )
    / ( COUNT(*) * STDDEV_POP(Avg_Preparation_Time_Minutes) * STDDEV_POP(Avg_Rating) )
    AS Pearson_Correlation_PrepTime_Rating
FROM restaurant_cleaned;

-- Q16. Cuisine_Type with the highest average restaurant rating
SELECT Cuisine_Type,
       ROUND(AVG(Avg_Rating), 2) AS Avg_Restaurant_Rating,
       COUNT(*) AS Restaurants
FROM restaurant_cleaned
GROUP BY Cuisine_Type
ORDER BY Avg_Restaurant_Rating DESC;

-- Q17. Low_Capacity_Flag restaurants vs others — rating comparison
SELECT Low_Capacity_Flag,
       ROUND(AVG(Avg_Rating), 2) AS Avg_Rating,
       COUNT(*) AS Restaurants
FROM restaurant_cleaned
GROUP BY Low_Capacity_Flag;

-- Q18. Order_Capacity_Per_Day by City
SELECT City,
       ROUND(AVG(Order_Capacity_Per_Day), 2) AS Avg_Capacity_Per_Day,
       COUNT(*) AS Restaurants
FROM restaurant_cleaned
GROUP BY City
ORDER BY Avg_Capacity_Per_Day DESC;

-- --------- OBJECTIVE 5: ORDER ECONOMICS, DISCOUNTS & RISK ----------

-- Q19. Does Discount_Applied significantly affect Final_Amount / Net_Revenue?
SELECT
    CASE WHEN Discount_Applied > 0 THEN 'Discounted' ELSE 'No Discount' END AS Discount_Group,
    COUNT(*)                          AS Order_Count,
    ROUND(AVG(Final_Amount), 2)       AS Avg_Final_Amount,
    ROUND(AVG(Net_Revenue), 2)        AS Avg_Net_Revenue,
    ROUND(AVG(Discount_Applied), 2)   AS Avg_Discount_Value
FROM orders
GROUP BY Discount_Group;

-- Q20. Order_Status association with Region and Delivery_Time_Minutes
-- 20a. Region breakdown
SELECT Region, Order_Status, COUNT(*) AS Order_Count
FROM orders
GROUP BY Region, Order_Status
ORDER BY Region, Order_Count DESC;

-- 20b. Delivery time breakdown
SELECT Order_Status,
       ROUND(AVG(Delivery_Time_Minutes), 2) AS Avg_Delivery_Time,
       COUNT(*) AS Order_Count
FROM orders
GROUP BY Order_Status
ORDER BY Avg_Delivery_Time DESC;


-- =====================================================================
-- STEP 4: SUMMARY & DERIVED TABLES / VIEWS / STORED PROCEDURES
-- =====================================================================

-- 4a. Reusable master view — one row per order, fully enriched
CREATE OR REPLACE VIEW vw_orders_full AS
SELECT
    o.Order_ID, o.Order_Date, o.Region, o.Order_Status,
    o.Final_Amount, o.Net_Revenue, o.Discount_Applied,
    o.Payment_Mode, o.Delivery_Time_Minutes, o.Order_Rating,
    o.Rating_Valid_Flag, o.Festival_Flag,
    c.Gender, c.Age_Group, c.City AS Customer_City,
    c.Customer_Type, c.Preferred_Cuisine,
    c.Total_Orders AS Customer_Lifetime_Orders, c.Average_Spend,
    r.Restaurant_Name, r.City AS Restaurant_City, r.Cuisine_Type,
    r.Avg_Preparation_Time_Minutes, r.Avg_Rating AS Restaurant_Avg_Rating,
    r.Low_Capacity_Flag,
    dp.Partner_Name, dp.Vehicle_Type, dp.Avg_Delivery_Speed_KMPH,
    dp.Avg_Customer_Rating AS Partner_Avg_Rating,
    dp.Delivery_Efficiency_Score, dp.Status AS Partner_Status
FROM orders o
LEFT JOIN customers c          ON o.Customer_ID = c.Customer_ID
LEFT JOIN restaurant_cleaned r ON o.Restaurant_ID = r.Restaurant_ID
LEFT JOIN delivery_partners dp ON o.Delivery_Partner_ID = dp.Delivery_Partner_ID;

-- Quick check
SELECT * FROM vw_orders_full LIMIT 10;

-- 4b. Derived/summary table — region performance snapshot
DROP TABLE IF EXISTS summary_region_performance;
CREATE TABLE summary_region_performance AS
SELECT
    Region,
    COUNT(*)                                                     AS Total_Orders,
    SUM(Net_Revenue)                                             AS Total_Net_Revenue,
    ROUND(AVG(Final_Amount), 2)                                  AS Avg_Final_Amount,
    ROUND(AVG(Delivery_Time_Minutes), 2)                         AS Avg_Delivery_Time,
    SUM(CASE WHEN Order_Status = 'Cancelled' THEN 1 ELSE 0 END)  AS Cancelled_Orders,
    SUM(CASE WHEN Order_Status = 'Returned'  THEN 1 ELSE 0 END)  AS Returned_Orders,
    SUM(CASE WHEN Order_Status = 'Delivered' THEN 1 ELSE 0 END)  AS Delivered_Orders
FROM orders
GROUP BY Region;

SELECT * FROM summary_region_performance ORDER BY Total_Net_Revenue DESC;

-- 4c. Derived/summary table — customer segment snapshot
DROP TABLE IF EXISTS summary_customer_segment;
CREATE TABLE summary_customer_segment AS
SELECT
    c.Customer_Type,
    COUNT(DISTINCT c.Customer_ID)        AS Customers,
    ROUND(AVG(c.Average_Spend), 2)       AS Avg_Spend,
    ROUND(AVG(o.Final_Amount), 2)        AS Avg_Order_Value,
    ROUND(AVG(o.Order_Rating), 2)        AS Avg_Order_Rating
FROM customers c
LEFT JOIN orders o ON c.Customer_ID = o.Customer_ID AND o.Rating_Valid_Flag = 'TRUE'
GROUP BY c.Customer_Type;

SELECT * FROM summary_customer_segment ORDER BY Avg_Spend DESC;

-- 4d. Stored procedure — region performance for any date range
-- Note: Order_Date is stored as TEXT ('YYYY-MM-DD'), hence STR_TO_DATE.
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_region_performance$$
CREATE PROCEDURE sp_region_performance(IN p_start_date DATE, IN p_end_date DATE)
BEGIN
    -- Basic exception handling: catch any SQL error and return a message
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SELECT 'An error occurred while computing region performance.' AS Error_Message;
    END;

    SELECT
        Region,
        COUNT(*)                     AS Total_Orders,
        SUM(Net_Revenue)             AS Total_Net_Revenue,
        ROUND(AVG(Final_Amount), 2)  AS Avg_Final_Amount
    FROM orders
    WHERE STR_TO_DATE(Order_Date, '%Y-%m-%d') BETWEEN p_start_date AND p_end_date
    GROUP BY Region
    ORDER BY Total_Net_Revenue DESC;
END$$

DELIMITER ;

-- Example call:
-- CALL sp_region_performance('2024-04-01', '2024-04-30');

-- 4e. Stored procedure — top N restaurants by rating within a cuisine
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_top_restaurants_by_cuisine$$
CREATE PROCEDURE sp_top_restaurants_by_cuisine(IN p_cuisine VARCHAR(100), IN p_limit INT)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SELECT 'An error occurred while fetching top restaurants.' AS Error_Message;
    END;

    SELECT Restaurant_Name, City, Cuisine_Type, Avg_Rating, Order_Capacity_Per_Day
    FROM restaurant_cleaned
    WHERE Cuisine_Type = p_cuisine
    ORDER BY Avg_Rating DESC
    LIMIT p_limit;
END$$

DELIMITER ;

-- Example call:
-- CALL sp_top_restaurants_by_cuisine('North Indian', 10);


-- =====================================================================
-- For each business question (Q1–Q20)
--   - The query result / key numbers
--   - The one-line insight
--   - Which hypothesis (H0 / H1) it supports or rejects
--   - How it connects back to the five objectives
-- This becomes the basis of the SQL Insights Document deliverable.
-- =====================================================================
