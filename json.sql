USE POS;

-- ============================================================
-- CASE 1 — prod.json
-- ============================================================

WITH Buyers AS (
    SELECT 
        p.id AS product_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID', c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        ) AS buyers_json
    FROM Product p
    LEFT JOIN Orderline ol ON ol.product_id = p.id
    LEFT JOIN `Order` o ON o.id = ol.order_id
    LEFT JOIN Customer c ON c.id = o.customer_id
    GROUP BY p.id
)
SELECT
    JSON_OBJECT(
        'productID', p.id,
        'productName', p.name,
        'currentPrice', p.currentPrice,
        'buyers',
            JSON_EXTRACT(COALESCE(b.buyers_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/prod.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Product p
LEFT JOIN Buyers b ON b.product_id = p.id;

-- ============================================================
-- CASE 2 — cust.json
-- ============================================================

WITH ItemAgg AS (
    SELECT 
        ol.order_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID', p.id,
                'ProductName', p.name,
                'Quantity', ol.quantity
            )
        ) AS items_json
    FROM Orderline ol
    JOIN Product p ON p.id = ol.product_id
    GROUP BY ol.order_id
),
OrderAgg AS (
    SELECT
        o.customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'order_date', o.datePlaced,
                'shipping_date', o.dateShipped,
                'order_total',
                    (
                        SELECT SUM(ol.quantity * p.currentPrice)
                        FROM Orderline ol
                        JOIN Product p ON p.id = ol.product_id
                        WHERE ol.order_id = o.id
                    ),
                'items',
                    JSON_EXTRACT(COALESCE(i.items_json, '[]'), '$')
            )
        ) AS orders_json
    FROM `Order` o
    LEFT JOIN ItemAgg i ON i.order_id = o.id
    GROUP BY o.customer_id
)
SELECT
    JSON_OBJECT(
        'customer_name', CONCAT(c.firstName, ' ', c.lastName),

        'printed_address_1',
            IF(
                c.address2 IS NULL OR c.address2 = '',
                c.address1,
                CONCAT(c.address1, ' #', c.address2)
            ),

        'printed_address_2',
            CONCAT(ci.city, ', ', ci.state, '   ', LPAD(ci.zip, 5, '0')),

        'orders',
            JSON_EXTRACT(COALESCE(o.orders_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/cust.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Customer c
LEFT JOIN City ci ON ci.zip = c.zip
LEFT JOIN OrderAgg o ON o.customer_id = c.id;


-- ============================================================
-- CASE 3 — custom1.json
-- ============================================================

WITH CustAgg AS (
    SELECT
        c.zip,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'customer_id', c.id,
                'name', CONCAT(c.firstName, ' ', c.lastName),
                'lifetime_value',
                    (
                        SELECT COALESCE(SUM(ol.quantity * p.currentPrice), 0)
                        FROM `Order` o
                        JOIN Orderline ol ON ol.order_id = o.id
                        JOIN Product p ON p.id = ol.product_id
                        WHERE o.customer_id = c.id
                    )
            )
        ) AS cust_json
    FROM Customer c
    GROUP BY c.zip
)
SELECT
    JSON_OBJECT(
        'zip_code', LPAD(ci.zip, 5, '0'),
        'city', ci.city,
        'state', ci.state,
        'customers',
            JSON_EXTRACT(COALESCE(ca.cust_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/custom1.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM City ci
JOIN CustAgg ca ON ca.zip = ci.zip;

-- ============================================================
-- CASE 4 — custom2.json
-- ============================================================

WITH Sales AS (
    SELECT
        p.id AS product_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'order_id', o.id,
                'order_date', o.datePlaced,
                'quantity_sold', ol.quantity,
                'revenue_generated', (ol.quantity * p.currentPrice)
            )
        ) AS sales_json
    FROM Product p
    JOIN Orderline ol ON ol.product_id = p.id
    JOIN `Order` o ON o.id = ol.order_id
    GROUP BY p.id
)
SELECT
    JSON_OBJECT(
        'product_id', p.id,
        'product_name', p.name,

        'total_units_sold',
            (SELECT SUM(ol.quantity) FROM Orderline ol WHERE ol.product_id = p.id),

        'total_revenue',
            (SELECT SUM(ol.quantity * p.currentPrice) FROM Orderline ol WHERE ol.product_id = p.id),

        'sales_history',
            JSON_EXTRACT(COALESCE(s.sales_json, '[]'), '$')
    )
INTO OUTFILE '/var/lib/mysql-files/custom2.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Product p
JOIN Sales s ON s.product_id = p.id;
