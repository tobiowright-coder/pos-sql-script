-- # 2. -- Generate Denormailization / Views SQL
-- Include the ETL script first to ensure database is populated
SOURCE /home/twright/etl.sql;

USE POS;

-- 1. CREATE VIEW: v_ProductBuyers
-- Lists all customers who bought each product
-- Includes products with zero sales (LEFT JOIN)

CREATE OR REPLACE VIEW v_ProductBuyers AS
SELECT 
    p.id AS productID,
    p.name AS productName,
    IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName) ORDER BY c.id ASC SEPARATOR ','),
        ''
    ) AS customers
FROM Product p
LEFT JOIN Orderline ol ON p.id = ol.product_id
LEFT JOIN `Order` o ON ol.order_id = o.id
LEFT JOIN Customer c ON o.customer_id = c.id
GROUP BY p.id, p.name
ORDER BY p.id ASC;

-- 2. CREATE MATERIALIZED VIEW: mv_ProductBuyers
-- Physical table snapshot for instant access

-- Drop if exists to ensure clean state
DROP TABLE IF EXISTS mv_ProductBuyers;

-- Create physical table from view
CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

-- Add standard INDEX on productID for fast lookups (not PRIMARY KEY)
CREATE INDEX idx_mv_productid ON mv_ProductBuyers(productID);

-- 3. TRIGGERS: Eager Updates for Materialized View
-- Keep mv_ProductBuyers synchronized with Orderline changes
-- Only updates the affected product row for efficiency

DELIMITER //

-- Trigger for INSERT on Orderline
CREATE TRIGGER trg_orderline_insert
AFTER INSERT ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers mv
    SET customers = IFNULL((
        SELECT GROUP_CONCAT(DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName) ORDER BY c.id ASC SEPARATOR ', ')
        FROM Orderline ol
        JOIN `Order` o ON ol.order_id = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = NEW.product_id
    ), '')
    WHERE mv.productID = NEW.product_id;
END //

-- Trigger for DELETE on Orderline
CREATE TRIGGER trg_Orderline_Delete
AFTER DELETE ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers mv
    SET customers = IFNULL((
        SELECT GROUP_CONCAT(DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName) ORDER BY c.id ASC SEPARATOR ', ')
        FROM Orderline ol
        JOIN `Order` o ON ol.order_id = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = OLD.product_id
    ), '')
    WHERE mv.productID = OLD.product_id;
END //

DELIMITER ;

-- 4. TRIGGER: Price History Logging
-- Track price changes in Product table
-- Only inserts if price actually changed

DELIMITER //

CREATE TRIGGER trg_Product_PriceHistory
AFTER UPDATE ON Product
FOR EACH ROW
BEGIN
    -- Only insert if currentPrice has actually changed
    IF OLD.currentPrice != NEW.currentPrice THEN
        INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
        VALUES (OLD.currentPrice, NEW.currentPrice, NEW.id);
    END IF;
END//

DELIMITER ;