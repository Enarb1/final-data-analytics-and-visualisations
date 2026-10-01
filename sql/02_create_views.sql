-- Products Enriched Data
CREATE OR REPLACE VIEW vw_dim_product_enriched AS
    SELECT
        p.product_id AS "ProductID",
        p.product_name AS "ProductName",
        c.category_name AS "Category",
        s.company_name AS "Supplier",
        CAST(p.unit_price AS NUMERIC(10, 2)) AS "Unit Price",
        CASE
            WHEN  p.discontinued = 1
            THEN 'Yes'
            ELSE 'No'
        END AS "Discontinued"
    FROM products p
    LEFT JOIN suppliers s ON p.supplier_id = s.supplier_id
    LEFT JOIN categories c ON c.category_id = p.category_id;


SELECT COUNT(*) FROM vw_dim_product_enriched; -- Expected 77


-- Order Sales Fact View
CREATE OR REPLACE VIEW vw_fct_order_sales AS
    SELECT
        o.order_id AS "OrderID",
        o.customer_id AS "CustomerID",
        o.employee_id AS "EmployeeID",
        o.ship_via AS "ShipperID",
        o.order_date AS "OrderDate",
        o.required_date AS "RequiredDate",
        o.shipped_date AS "ShippedDate",
        od.product_id AS "ProductID",
        CAST(od.unit_price AS NUMERIC(10, 2))AS "UnitPrice",
        od.quantity AS "Quantity",
        CAST(od.discount AS NUMERIC(4,2)) AS "Discount",
        ROUND(
            CAST(od.unit_price AS NUMERIC(10, 2)) * od.quantity * (1 - CAST(od.discount AS NUMERIC(10,2))),
        2
        ) AS "TotalLineAmount"
    FROM orders o
    JOIN order_details od ON o.order_id = od.order_id;


SELECT COUNT(*) AS rows_, COUNT(DISTINCT "OrderID") AS orders_
FROM vw_fct_order_sales; -- Expected 2155 and 830


-- Customers GEO dimensions View
CREATE OR REPLACE VIEW vw_dim_customer_geo AS
    SELECT
        c.customer_id AS "CustomerID",
        c.company_name AS "Customer",
        c.contact_name AS "ContactName",
        c.city AS "City",
        c.country AS "Country"
    FROM customers c
    WHERE EXISTS(
        SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id
    );

SELECT COUNT(*) FROM vw_dim_customer_geo; -- Expected 89

SELECT ROUND(SUM("TotalLineAmount"), 2) FROM vw_fct_order_sales;

-- Employees dimensions View
CREATE OR REPLACE VIEW vw_dim_employees AS
    SELECT
        e.employee_id AS "EmployeeID",
        e.first_name || ' ' || e.last_name AS "EmployeeName",
        e.title AS "Title",
        e.city AS "City",
        e.country AS "Country",
        e.hire_date AS "HireDate"
    FROM employees e;


SELECT
    (SELECT COUNT(*) FROM vw_dim_employees) AS vw_dim_emp_count, -- Expected 9
    (SELECT COUNT(*) FROM employees) AS employee_count; -- Expected 0

-- Shippers dimensions View
CREATE OR REPLACE VIEW vw_dim_shipper AS
    SELECT
        s.shipper_id AS "ShipperID",
        s.company_name AS "Shipper"
    FROM shippers s;


SELECT
    (SELECT COUNT(*) FROM vw_dim_shipper) AS vw_dim_shipper_count, -- Expected 6
    (SELECT COUNT(*) FROM shippers) AS shippers_count; -- Expected 6