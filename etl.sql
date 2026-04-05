-- # 1. -- Generate ETL SQL
DROP DATABASE IF EXISTS POS;
CREATE DATABASE POS;
USE POS;

-- Final Schema Tables

CREATE TABLE City ( zip DECIMAL (5,0) ZEROFILL PRIMARY KEY, city VARCHAR (32), state VARCHAR(4) ) ENGINE=InnoDB;
CREATE TABLE Customer ( id SERIAL PRIMARY KEY, firstName VARCHAR(32), lastName VARCHAR(30), email VARCHAR(128), address1 VARCHAR(100), address2 VARCHAR(50), phone VARCHAR(32), birthdate DATE, zip DECIMAL(5) ZEROFILL, CONSTRAINT fk_cust_city FOREIGN KEY (zip) REFERENCES City(zip) )ENGINE=InnoDB;
CREATE TABLE Product ( id SERIAL PRIMARY KEY, name VARCHAR(128) NOT NULL, currentPrice DECIMAL(6,2) NOT NULL, availableQuantity INT NOT NULL )ENGINE=InnoDB;
CREATE TABLE `Order` ( id SERIAL PRIMARY KEY, datePlaced DATE NOT NULL, dateShipped DATE, customer_id BIGINT UNSIGNED NOT NULL, CONSTRAINT fk_order_cust FOREIGN KEY (customer_id) REFERENCES Customer(id) )ENGINE=InnoDB;
CREATE TABLE Orderline ( order_id BIGINT UNSIGNED NOT NULL, product_id BIGINT UNSIGNED NOT NULL, quantity INT NOT NULL, PRIMARY KEY (order_id, product_id), CONSTRAINT fk_ol_order FOREIGN KEY (order_id) REFERENCES `Order`(id), CONSTRAINT fk_ol_prod FOREIGN KEY (product_id) REFERENCES Product(id) )ENGINE=InnoDB;
CREATE TABLE PriceHistory ( id SERIAL PRIMARY KEY, oldPrice DECIMAL(6,2), newPrice DECIMAL(6,2), ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, product_id BIGINT UNSIGNED NOT NULL, CONSTRAINT fk_pricehist_product FOREIGN KEY (product_id) REFERENCES Product(id) )ENGINE=InnoDB;

-- Staging tables for raw CSV import (all strings)

CREATE TABLE staging_customer ( id TEXT, first TEXT, last TEXT, city TEXT, state TEXT, zip_raw TEXT, add1 TEXT, add2 TEXT, email TEXT, bday TEXT);
CREATE TABLE staging_product ( id TEXT, name TEXT, price TEXT, qty TEXT);
CREATE TABLE staging_order ( id TEXT, cust_id TEXT, placed TEXT, shipped TEXT);
CREATE TABLE staging_orderline ( oid TEXT, pid TEXT);

-- Load Raw Data using LOCAL INFILE

LOAD DATA LOCAL INFILE '/home/twright/products.csv' INTO TABLE staging_product FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/home/twright/customers.csv' INTO TABLE staging_customer FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/home/twright/orders.csv' INTO TABLE staging_order FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/home/twright/orderlines.csv' INTO TABLE staging_orderline FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES;

-- Transform and Insert into Final Tables

-- Extract City/Zip info first
INSERT IGNORE INTO City (zip, city, state) SELECT DISTINCT LPAD(TRIM(zip_raw), 5, '0'), NULLIF(TRIM(city), ''), NULLIF(TRIM(state), '')
FROM staging_customer
WHERE zip_raw IS NOT NULL AND zip_raw != '';

-- Populate Customer using COALESCE for date formatting
INSERT IGNORE INTO Customer (id, firstName, lastName, email, address1, address2, phone, birthdate, zip)
SELECT id, NULLIF(TRIM(first), ''), NULLIF(TRIM(last), ''), NULLIF(TRIM(email), ''), NULLIF(TRIM(add1), ''), NULLIF(TRIM(add2), ''), NULL,
COALESCE( STR_TO_DATE(NULLIF(TRIM(bday), ''), '%Y-%m-%d'), STR_TO_DATE(NULLIF(TRIM(bday), ''), '%m/%d/%Y')), LPAD(NULLIF(TRIM(zip_raw), ''), 5, '0')
FROM staging_customer;

-- Populate Product
INSERT INTO Product (id, name, currentPrice, availableQuantity)
SELECT id, NULLIF(TRIM(name), ''), CAST(REPLACE(REPLACE(price, '$', ''), ',', '') AS DECIMAL(6,2)), CAST(qty AS INT) 
FROM staging_product;

-- Populate Order
INSERT IGNORE INTO `Order` (id, datePlaced, dateShipped, customer_id)
SELECT id, COALESCE(STR_TO_DATE(NULLIF(TRIM(placed), ''), '%Y-%m-%d %H:%i:%s'), STR_TO_DATE(NULLIF(TRIM(placed), ''), '%m/%d/%Y %H:%i:%s')),
CASE WHEN TRIM(shipped) = 'Canceled' THEN NULL ELSE COALESCE(STR_TO_DATE(NULLIF(TRIM(shipped), ''), '%Y-%m-%d %H:%i:%s'), STR_TO_DATE(NULLIF(TRIM(shipped), ''), '%m/%d/%Y %H:%i:%s')) END, cust_id 
FROM staging_order;

-- Populate Orderline (Aggregation)
INSERT INTO Orderline (order_id, product_id, quantity)
SELECT CAST(TRIM(oid) AS UNSIGNED), CAST(TRIM(pid) AS UNSIGNED), COUNT(*) 
FROM staging_orderline 
WHERE NULLIF(TRIM(oid), '') IS NOT NULL AND NULLIF(TRIM(pid), '') IS NOT NULL
GROUP BY TRIM(oid), TRIM(pid);

-- 5. Cleanup Staging Tables
DROP TABLE staging_product;
DROP TABLE staging_customer;
DROP TABLE staging_order;
DROP TABLE staging_orderline;