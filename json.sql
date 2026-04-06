USE POS;

-- ============================================================
-- CASE 1 — prod.json (ALL PRODUCTS, buyers nested)
-- ============================================================

SELECT
    JSON_OBJECT(
        'productID', p.id,
        'productName', p.name,
        'currentPrice', p.currentPrice,
        'buyers',
            JSON_EXTRACT(
                COALESCE(
                    (
                        SELECT JSON_ARRAYAGG(
                            JSON_OBJECT(
                                'CustomerID', c.id,
                                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
                            )
                        )
                        FROM Orderline ol
                        JOIN `Order` o ON o.id = ol.order_id
                        JOIN Customer c ON c.id = o.customer_id
                        WHERE ol.product_id = p.id
                    ),
                    '[]'
                ),
            '$')
    )
INTO OUTFILE '/var/lib/mysql-files/prod.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Product p;


-- ============================================================
-- CASE 2 — cust.json (ALL CUSTOMERS, deep nesting)
-- ============================================================

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
            JSON_EXTRACT(
                COALESCE(
                    (
                        SELECT JSON_ARRAYAGG(
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
                                    JSON_EXTRACT(
                                        COALESCE(
                                            (
                                                SELECT JSON_ARRAYAGG(
                                                    JSON_OBJECT(
                                                        'ProductID', p.id,
                                                        'ProductName', p.name,
                                                        'Quantity', ol.quantity
                                                    )
                                                )
                                                FROM Orderline ol
                                                JOIN Product p ON p.id = ol.product_id
                                                WHERE ol.order_id = o.id
                                            ),
                                            '[]'
                                        ),
                                    '$')
                            )
                        )
                        FROM `Order` o
                        WHERE o.customer_id = c.id
                    ),
                    '[]'
                ),
            '$')
    )
INTO OUTFILE '/var/lib/mysql-files/cust.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Customer c
LEFT JOIN City ci ON ci.zip = c.zip;


-- ============================================================
-- CASE 3 — custom1.json (ONLY ZIP CODES WITH CUSTOMERS)
-- Example Business Case: "Regional Customer Lifetime Value"
-- ============================================================

SELECT
    JSON_OBJECT(
        'zip_code', ci.zip,
        'city', ci.city,
        'state', ci.state,
        'customers',
            JSON_EXTRACT(
                COALESCE(
                    (
                        SELECT JSON_ARRAYAGG(
                            JSON_OBJECT(
                                'customer_id', c.id,
                                'name', CONCAT(c.firstName, ' ', c.lastName),
                                'lifetime_value',
                                    (
                                        SELECT COALESCE(
                                            SUM(ol.quantity * p.currentPrice),
                                            0
                                        )
                                        FROM `Order` o
                                        JOIN Orderline ol ON ol.order_id = o.id
                                        JOIN Product p ON p.id = ol.product_id
                                        WHERE o.customer_id = c.id
                                    )
                            )
                        )
                        FROM Customer c
                        WHERE c.zip = ci.zip
                    ),
                    '[]'
                ),
            '$')
    )
INTO OUTFILE '/var/lib/mysql-files/custom1.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM City ci
WHERE EXISTS (SELECT 1 FROM Customer c WHERE c.zip = ci.zip);


-- ============================================================
-- CASE 4 — custom2.json (ONLY PRODUCTS WITH SALES)
-- Example Business Case: "Product Sales History & Revenue"
-- ============================================================

SELECT
    JSON_OBJECT(
        'product_id', p.id,
        'product_name', p.name,

        'total_units_sold',
            (
                SELECT COALESCE(SUM(ol.quantity), 0)
                FROM Orderline ol
                WHERE ol.product_id = p.id
            ),

        'total_revenue',
            (
                SELECT COALESCE(SUM(ol.quantity * p.currentPrice), 0)
                FROM Orderline ol
                WHERE ol.product_id = p.id
            ),

        'sales_history',
            JSON_EXTRACT(
                COALESCE(
                    (
                        SELECT JSON_ARRAYAGG(
                            JSON_OBJECT(
                                'order_id', o.id,
                                'order_date', o.datePlaced,
                                'quantity_sold', ol.quantity,
                                'revenue_generated', (ol.quantity * p.currentPrice)
                            )
                        )
                        FROM Orderline ol
                        JOIN `Order` o ON o.id = ol.order_id
                        WHERE ol.product_id = p.id
                    ),
                    '[]'
                ),
            '$')
    )
INTO OUTFILE '/var/lib/mysql-files/custom2.json'
FIELDS TERMINATED BY ''
LINES TERMINATED BY '\n'
FROM Product p
WHERE EXISTS (SELECT 1 FROM Orderline ol WHERE ol.product_id = p.id);

