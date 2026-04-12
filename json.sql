USE POS;

-- ============================================================
-- CASE 1: Product Details View (prod.json)
-- Goal: Product Info + Array of Customers who bought it
-- ============================================================

WITH Buyers AS (
    SELECT
        p.id AS product_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID',   c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        ) AS buyers_json
    FROM Product p
    LEFT JOIN Orderline ol ON ol.product_id = p.id
    LEFT JOIN `Order`   o  ON o.id          = ol.order_id
    LEFT JOIN Customer  c  ON c.id          = o.customer_id
    GROUP BY p.id
)
SELECT
    JSON_OBJECT(
        'productID',    p.id,
        'productName',  p.name,
        'currentPrice', p.currentPrice,
        'buyers',       JSON_EXTRACT(COALESCE(b.buyers_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/prod.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Product p
LEFT JOIN Buyers b ON b.product_id = p.id;


-- ============================================================
-- CASE 2: Deep Customer Dashboard (cust.json)
-- Goal: Customer Info + Formatted Address + Nested Orders + Nested Items
--
-- FIX: order_total is now pre-computed in ItemsAgg alongside the
-- items array — one GROUP BY pass instead of a correlated subquery
-- firing once per order.
-- ============================================================

WITH ItemsAgg AS (
    SELECT
        ol.order_id,
        SUM(p.currentPrice * ol.quantity)   AS order_total,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',   p.id,
                'ProductName', p.name,
                'Quantity',    ol.quantity
            )
        )                                   AS items_json
    FROM Orderline ol
    JOIN Product   p ON p.id = ol.product_id
    GROUP BY ol.order_id
),

Orders AS (
    SELECT
        o.customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'order_date',   o.datePlaced,
                'shipping_date', o.dateShipped,
                'order_total',  ROUND(ia.order_total, 2),
                'items',        JSON_EXTRACT(COALESCE(ia.items_json, '[]'), '$')
            )
        ) AS orders_json
    FROM `Order`  o
    LEFT JOIN ItemsAgg ia ON ia.order_id = o.id
    GROUP BY o.customer_id
)

SELECT
    JSON_OBJECT(
        'customer_name',     CONCAT(c.firstName, ' ', c.lastName),
        'printed_address_1', IF(
                                 c.address2 IS NULL OR c.address2 = '',
                                 c.address1,
                                 CONCAT(c.address1, ' #', c.address2)
                             ),
        'printed_address_2', CONCAT(ci.city, ', ', ci.state, '   ', LPAD(ci.zip, 5, '0')),
        'orders',            JSON_EXTRACT(COALESCE(o.orders_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/cust.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Customer c
LEFT JOIN City   ci ON ci.zip        = c.zip
LEFT JOIN Orders o  ON o.customer_id = c.id;


-- ============================================================
-- CASE 3: Regional Demographics & Sales (custom1.json)
-- Goal: Map locations to customers living there and their lifetime value
--
-- FIX: lifetime_value is now pre-computed in LifetimeValue CTE —
-- one aggregation pass instead of a correlated subquery per customer.
-- ============================================================

WITH LifetimeValue AS (
    SELECT
        o.customer_id,
        COALESCE(SUM(ol.quantity * p.currentPrice), 0) AS lifetime_value
    FROM `Order`   o
    JOIN Orderline ol ON ol.order_id = o.id
    JOIN Product   p  ON p.id        = ol.product_id
    GROUP BY o.customer_id
),

CustAgg AS (
    SELECT
        c.zip,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'customer_id',  c.id,
                'name',         CONCAT(c.firstName, ' ', c.lastName),
                'lifetime_value', COALESCE(lv.lifetime_value, 0)
            )
        ) AS cust_json
    FROM Customer    c
    LEFT JOIN LifetimeValue lv ON lv.customer_id = c.id
    GROUP BY c.zip
)

SELECT
    JSON_OBJECT(
        'zip_code',  LPAD(ci.zip, 5, '0'),
        'city',      ci.city,
        'state',     ci.state,
        'customers', JSON_EXTRACT(COALESCE(ca.cust_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/custom1.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM City    ci
JOIN CustAgg ca ON ca.zip = ci.zip;


-- ============================================================
-- CASE 4: Product Revenue & Sales History Dashboard (custom2.json)
-- Goal: Total lifetime revenue per product with nested order history
--
-- FIX: total_units_sold and total_revenue are now pre-computed in
-- the Sales CTE alongside the sales_history array — two correlated
-- subqueries eliminated, replaced by a single GROUP BY pass.
-- ============================================================

WITH Sales AS (
    SELECT
        p.id                                        AS product_id,
        SUM(ol.quantity)                            AS total_units_sold,
        SUM(ol.quantity * p.currentPrice)           AS total_revenue,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'order_id',          o.id,
                'order_date',        o.datePlaced,
                'quantity_sold',     ol.quantity,
                'revenue_generated', ol.quantity * p.currentPrice
            )
        )                                           AS sales_json
    FROM Product   p
    JOIN Orderline ol ON ol.product_id = p.id
    JOIN `Order`   o  ON o.id          = ol.order_id
    GROUP BY p.id
)

SELECT
    JSON_OBJECT(
        'product_id',      p.id,
        'product_name',    p.name,
        'total_units_sold', s.total_units_sold,
        'total_revenue',   ROUND(s.total_revenue, 2),
        'sales_history',   JSON_EXTRACT(COALESCE(s.sales_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/custom2.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Product p
JOIN Sales   s ON s.product_id = p.id;

