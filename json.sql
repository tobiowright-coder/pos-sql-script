--CREATE JSON EXPORT SCRIPT (json.sql)

USE POS;

-- CASE 1: Product Details View (prod.json)
-- Goal: Product Info + Array of Customers who bought it
WITH UniqueProductOrders AS (
    SELECT DISTINCT product_id, order_id
    FROM Orderline
),
ProductBuyers AS (
    SELECT 
        upo.product_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID', c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        ) AS buyers_array
    FROM UniqueProductOrders upo
    JOIN `Order` o ON upo.order_id = o.id
    JOIN Customer c ON o.customer_id = c.id
    GROUP BY upo.product_id
)
SELECT CONCAT(
    '[',
    GROUP_CONCAT(
        JSON_OBJECT(
            'productID', p.id,
            'productName', p.name,
            'currentPrice', p.currentPrice,
            'buyers', IFNULL(pb.buyers_array, JSON_ARRAY())
        )
        SEPARATOR ','
    ),
    ']'
)
INTO OUTFILE '/var/lib/mysql-files/prod.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY ''
FROM Product p
LEFT JOIN ProductBuyers pb ON p.id = pb.product_id;

-- CASE 2: Deep Customer Dashboard (cust.json)
-- Goal: Customer Info + Formatted Address + Nested Orders + Nested Items

-- Step 1: Precompute OrderItems into a temp table
DROP TEMPORARY TABLE IF EXISTS OrderItemsTemp;
CREATE TEMPORARY TABLE OrderItemsTemp AS
SELECT 
    ol.order_id,
    JSON_ARRAYAGG(
        JSON_OBJECT(
            'ProductID', p.id,
            'ProductName', p.name,
            'Quantity', ol.quantity
        )
    ) AS items_array,
    SUM(ol.quantity * p.currentPrice) AS order_total
FROM Orderline ol
JOIN Product p ON p.id = ol.product_id
GROUP BY ol.order_id;

-- Step 2: Precompute CustomerOrders into a temp table
DROP TEMPORARY TABLE IF EXISTS CustomerOrdersTemp;
CREATE TEMPORARY TABLE CustomerOrdersTemp AS
SELECT 
    o.customer_id,
    JSON_ARRAYAGG(
        JSON_OBJECT(
            'order_date', o.datePlaced,
            'shipping_date', o.dateShipped,
            'order_total', IFNULL(oi.order_total, 0),
            'items', IFNULL(oi.items_array, JSON_ARRAY())
        )
    ) AS orders_array
FROM `Order` o
LEFT JOIN OrderItemsTemp oi ON oi.order_id = o.id
GROUP BY o.customer_id;

-- Step 3: Final SELECT into cust.json
SELECT JSON_OBJECT(
    'customer_name', CONCAT(c.firstName, ' ', c.lastName),
    'printed_address_1', CONCAT(
        c.address1,
        IF(c.address2 IS NOT NULL AND c.address2 != '', CONCAT(' #', c.address2), '')
    ),
    'printed_address_2', CONCAT(ci.city, ', ', ci.state, '   ', ci.zip),
    'orders', IFNULL(co.orders_array, JSON_ARRAY())
)
INTO OUTFILE '/var/lib/mysql-files/cust.json'
FIELDS TERMINATED BY ''
OPTIONALLY ENCLOSED BY ''
LINES TERMINATED BY '\n'
FROM Customer c
LEFT JOIN City ci ON ci.zip = c.zip
LEFT JOIN CustomerOrdersTemp co ON co.customer_id = c.id;

-- CASE 3: Regional Demographics & Sales (custom1.json)
-- Goal: Map locations to the customers living there and their total lifetime value.

-- Step 1: Precompute customer lifetime spend
DROP TEMPORARY TABLE IF EXISTS CustomerSpendTemp;
CREATE TEMPORARY TABLE CustomerSpendTemp AS
SELECT 
    o.customer_id,
    SUM(ol.quantity * p.currentPrice) AS total_spend
FROM `Order` o
JOIN Orderline ol ON ol.order_id = o.id
JOIN Product p ON p.id = ol.product_id
GROUP BY o.customer_id;

-- Step 2: Precompute customers grouped by ZIP
DROP TEMPORARY TABLE IF EXISTS ZipCustomersTemp;
CREATE TEMPORARY TABLE ZipCustomersTemp AS
SELECT 
    c.zip,
    JSON_ARRAYAGG(
        JSON_OBJECT(
            'customer_id', c.id,
            'name', CONCAT(c.firstName, ' ', c.lastName),
            'lifetime_value', IFNULL(cs.total_spend, 0)
        )
    ) AS cust_array
FROM Customer c
LEFT JOIN CustomerSpendTemp cs ON cs.customer_id = c.id
GROUP BY c.zip;

-- Step 3: Final SELECT into custom1.json
SELECT JSON_OBJECT(
    'zip_code', ci.zip,
    'city', ci.city,
    'state', ci.state,
    'resident_customers', IFNULL(zc.cust_array, JSON_ARRAY())
)
INTO OUTFILE '/var/lib/mysql-files/custom1.json'
FIELDS TERMINATED BY ''
OPTIONALLY ENCLOSED BY ''
LINES TERMINATED BY '\n'
FROM City ci
LEFT JOIN ZipCustomersTemp zc ON zc.zip = ci.zip;

-- CASE 4: Product Revenue & Sales History Dashboard (custom2.json)
-- Goal: Show total lifetime revenue per product, nesting the specific orders that contributed to it.

-- Step 1: Precompute all product sales
DROP TEMPORARY TABLE IF EXISTS ProductSalesTemp;
CREATE TEMPORARY TABLE ProductSalesTemp AS
SELECT 
    ol.product_id,
    o.id AS order_id,
    o.datePlaced,
    ol.quantity,
    (ol.quantity * p.currentPrice) AS order_revenue
FROM Orderline ol
JOIN `Order` o ON o.id = ol.order_id
JOIN Product p ON p.id = ol.product_id;

-- Step 2: Precompute totals per product
DROP TEMPORARY TABLE IF EXISTS ProductTotalsTemp;
CREATE TEMPORARY TABLE ProductTotalsTemp AS
SELECT 
    product_id,
    SUM(quantity) AS total_units_sold,
    SUM(order_revenue) AS total_revenue
FROM ProductSalesTemp
GROUP BY product_id;

-- Step 3: Precompute sales history per product
DROP TEMPORARY TABLE IF EXISTS ProductHistoryTemp;
CREATE TEMPORARY TABLE ProductHistoryTemp AS
SELECT 
    product_id,
    JSON_ARRAYAGG(
        JSON_OBJECT(
            'order_id', order_id,
            'order_date', datePlaced,
            'quantity_sold', quantity,
            'revenue_generated', order_revenue
        )
    ) AS sales_history
FROM ProductSalesTemp
GROUP BY product_id;

-- Step 4: Final SELECT into custom2.json
SELECT JSON_OBJECT(
    'product_id', p.id,
    'product_name', p.name,
    'total_units_sold', IFNULL(pt.total_units_sold, 0),
    'total_revenue', IFNULL(pt.total_revenue, 0),
    'sales_history', IFNULL(ph.sales_history, JSON_ARRAY())
)
INTO OUTFILE '/var/lib/mysql-files/custom2.json'
FIELDS TERMINATED BY ''
OPTIONALLY ENCLOSED BY ''
LINES TERMINATED BY '\n'
FROM Product p
LEFT JOIN ProductTotalsTemp pt ON pt.product_id = p.id
LEFT JOIN ProductHistoryTemp ph ON ph.product_id = p.id
WHERE pt.product_id IS NOT NULL;