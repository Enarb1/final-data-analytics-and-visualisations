-- Check if the import of the data is successful
SELECT COUNT(*) FROM orders; -- should be 830

SELECT COUNT(*) FROM order_details; -- should be 2155

-- Data Exploration
SELECT * FROM products LIMIT 10;
SELECT * FROM orders LIMIT 10;
SELECT * FROM order_details LIMIT 10;

-- Date Range

SELECT
    MIN(order_date),
    MAX(order_date)
FROM orders;

-- Min: 1996-07-04; Max: 1998-05-06

SELECT
    COUNT(*) AS orders_without_customers_count
FROM orders o
LEFT JOIN customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;


