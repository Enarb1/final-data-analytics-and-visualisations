# Northwind Sales Analysis & Dashboard — Documentation

**Course:** Data Analytics and Visualizations, SoftUni
**Stack:** PostgreSQL 18 → Power BI Desktop
**Dataset:** Northwind (830 orders, 2,155 order lines, 77 products, 91 customers, 9 employees)
**Total revenue (ground truth):** $1,265,793.29

---

## 1. Data preparation in SQL

All shaping is done in PostgreSQL views rather than in Power Query. Power Query is limited to data type assignment and a small number of cosmetic renames. This keeps the transformation logic version-controlled in a single `.sql` file, reusable outside this report, and readable as declarative code rather than a GUI step list.

### Views created

| View | Role | Purpose |
|---|---|---|
| `vw_fct_order_sales` | Fact | Order headers joined to line items; one row per order line. Calculates `TotalLineAmount`. |
| `vw_dim_product_enriched` | Dimension | Products denormalized with category and supplier. |
| `vw_dim_customer_geo` | Dimension | Active customers with geography. |
| `vw_dim_employee` | Dimension | Employees with a concatenated full name. |
| `vw_dim_shipper` | Dimension | Shippers, trimmed to the columns in use. |

The brief required the first three. The employee and shipper views were added so that *all* shaping happens in SQL — the alternative was importing those two tables raw and cleaning them in Power Query, which would have split the approach across two layers. Building them as views also means the employee `photo` column (binary image data) never crosses the wire, keeping the `.pbix` small.

### Naming convention

Views are prefixed `vw_dim_` and `vw_fct_` to encode their role in the dimensional model. Columns use friendly PascalCase or spaced names (`"Product Name"`, `"Total Line Amount"`) via quoted identifiers, so that clean names arrive in Power BI without renaming.

Foreign keys in the fact table are deliberately left in compact form (`OrderID`, `ProductID`, `CustomerID`) rather than spaced, because they are hidden from report view — users slice by `Product Name`, never by `ProductID`.

### Floating-point precision

In the PostgreSQL port of Northwind, `unit_price`, `discount` and `freight` are stored as `real` (4-byte float). Multiplying them directly produces values such as `440.00000762939453`.

Operands are therefore cast to `numeric` **before** multiplication, not after:

```sql
ROUND(
    CAST(od.unit_price AS numeric)
    * od.quantity
    * (1 - CAST(od.discount AS numeric))
, 2) AS "TotalLineAmount"
```

Casting the result instead of the operands would still perform the arithmetic in floating point and merely round an already-imprecise answer.

### Join strategy

Dimension views use `LEFT JOIN` so that no row is lost if a lookup is missing — an inner join would silently drop products with no category or supplier, producing `(Blank)` entries in the report. The fact view uses `INNER JOIN`, since an order with no line items contributes nothing to a sales fact table.

---

## 2. Decisions and interpretations

Three points in the brief were ambiguous and required a judgement. Each is recorded here so the choice is visible rather than implicit.

### "Active customers"

The Northwind `customers` table contains **no activity flag**. The term had to be defined.

**Definition used:** a customer who has placed at least one order.

```sql
WHERE EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id
)
```

This keeps the dimension consistent with the fact table, so no blank rows appear in relationships. `EXISTS` is preferred over `IN` or a `DISTINCT` join because it stops at the first match and cannot duplicate rows. Two of the 91 customers have never ordered and are excluded, leaving 89.

### Freight is excluded from the fact table

`orders.freight` is stored at **order grain**, while the fact table is at **line-item grain**. Joining the two repeats the freight value across every line of an order:

| OrderID | ProductID | TotalLineAmount | Freight |
|---|---|---|---|
| 10248 | 11 | 168.00 | 32.38 |
| 10248 | 42 | 98.00 | 32.38 |
| 10248 | 72 | 174.00 | 32.38 |

A naive `SUM(Freight)` on that order returns 97.14 against an actual freight of 32.38 — and the error scales with the number of lines per order, so it is not a consistent multiple that would be noticed by inspection. `TotalLineAmount` is additive along the product dimension; `Freight` is not.

Freight is also a **shipping cost**, not sales revenue. Including it would inflate the headline figure and break reconciliation against the SQL ground truth.

It is therefore excluded from `TotalLineAmount` and from the fact view. Had it been required, the correct handling would be either a `SUMX` over distinct orders, or allocation across lines in SQL using a window function to make the value genuinely additive.

### "% Discounted"

The brief defines this as "percentage of revenue generated with a discount," which admits two readings:

1. **Share of revenue arising from discounted lines** — a $1,000 line with a 5% discount contributes the full $1,000 to the numerator.
2. **Monetary value of discount given** as a share of gross revenue.

**Interpretation used: reading 1**, which is the literal wording. The measure returns approximately 40.7% across the full dataset. Reading 2 would return roughly 5–6% and answers a materially different question.

---

## 3. Data model

A **star schema** with one fact table and five dimensions, plus a DAX-generated date table.

```
                    ┌──────────────┐
                    │     Date     │
                    └──────┬───────┘
                           │
 ┌───────────────┐         ▼        ┌──────────────────┐
 │ Customer Geo  │──►┌──────────┐◄──│ Product Enriched │
 └───────────────┘   │  FACT:   │   └──────────────────┘
                     │  Order   │
 ┌───────────────┐   │  Sales   │   ┌──────────────────┐
 │   Employee    │──►└──────────┘◄──│     Shipper      │
 └───────────────┘                  └──────────────────┘
```

### Relationship rules applied

- All five relationships are **one-to-many**, propagating from dimension to fact.
- Cross-filter direction is **Single** on every relationship. Bi-directional filtering creates ambiguous filter paths and was avoided entirely.
- Foreign key columns in the fact table are **hidden from report view**.
- No dimension joins to another dimension.
- The source tables underlying each view are **not** imported alongside their views, which would create duplicate filter paths.

### Date table

Generated in DAX rather than SQL, so the model owns its own time dimension:

```dax
Date =
VAR StartDate = DATE( YEAR( MIN( vw_fct_order_sales[Order Date] ) ), 1, 1 )
VAR EndDate   = DATE( YEAR( MAX( vw_fct_order_sales[Order Date] ) ), 12, 31 )
RETURN
ADDCOLUMNS(
    CALENDAR( StartDate, EndDate ),
    "Year",         YEAR( [Date] ),
    "Month Number", MONTH( [Date] ),
    "Month Name",   FORMAT( [Date], "MMM" ),
    "Year-Month",   FORMAT( [Date], "YYYY-MM" ),
    "Quarter",      "Q" & QUARTER( [Date] ),
    "Day Name",     FORMAT( [Date], "ddd" )
)
```

The range is snapped to 1 January and 31 December because time intelligence functions require a **contiguous, complete-year** date table. Starting at the first actual order date (4 July 1996) would break `TOTALYTD` and `SAMEPERIODLASTYEAR`.

Two further steps were applied, both of which fail silently if omitted:

1. `Month Name` is sorted by `Month Number`, otherwise chart axes run alphabetically (Apr, Aug, Dec…).
2. The table is **marked as a date table**. Without this flag, time intelligence functions return blank with no error.

Power BI's **Auto date/time** was disabled before import, to prevent hidden date hierarchies being created behind every date column.

---

## 4. DAX measures

All measures live in a dedicated `_Measures` table rather than being scattered across the tables they reference. The underscore prefix sorts it to the top of the Fields pane.

| Measure | Notes |
|---|---|
| `Total Revenue` | `SUM` of the SQL-calculated `TotalLineAmount`. |
| `Total Orders` | `DISTINCTCOUNT(OrderID)` — returns 830 orders, not 2,155 line items. |
| `Total Quantity Sold` | Simple `SUM`. |
| `Average Order Value` | `DIVIDE([Total Revenue], [Total Orders])`. |
| `Revenue YTD` | `TOTALYTD`. |
| `Revenue Previous Year` | `SAMEPERIODLASTYEAR`. |
| `YoY Growth %` | Uses `VAR`; guards the no-prior-year case. |
| `Discounted Revenue` / `% Discounted` | Uses `KEEPFILTERS`. |
| `Top 3 Product Sales` | Uses `VAR`, `TOPN` and `ALLSELECTED`. |

### DIVIDE over `/`

`DIVIDE` returns blank on a zero denominator. The `/` operator throws an error that propagates into visuals as soon as a slicer selection produces an empty set.

### Use of VAR

`VAR` is used where it does real work, not uniformly. In `YoY Growth %`, `[Revenue Previous Year]` is referenced twice — once in the subtraction, once in the blank check — so storing it in a variable means one engine pass rather than two:

```dax
YoY Growth % =
VAR CurrentRevenue = [Total Revenue]
VAR PriorRevenue   = [Revenue Previous Year]
VAR Growth         = DIVIDE( CurrentRevenue - PriorRevenue, PriorRevenue )
RETURN
    IF( ISBLANK( PriorRevenue ), BLANK(), Growth )
```

By contrast, `% Discounted` is written as a plain `DIVIDE` of two measures, each referenced once. Introducing variables there would add lines without reducing evaluations or improving readability.

### KEEPFILTERS

```dax
Discounted Revenue =
CALCULATE( [Total Revenue], KEEPFILTERS( vw_fct_order_sales[Discount] > 0 ) )
```

`KEEPFILTERS` preserves any filter already applied to `Discount` by a slicer rather than overwriting it. This is the difference between a measure that works in any filter context and one that only works on an unfiltered page.

### ALLSELECTED

```dax
Top 3 Product Sales =
VAR TopProducts =
    TOPN( 3, ALLSELECTED( vw_dim_product_enriched[Product Name] ), [Total Revenue], DESC )
RETURN
    CALCULATE( [Total Revenue], KEEPFILTERS( TopProducts ) )
```

`ALLSELECTED` rather than `ALL` means the top 3 is recalculated within whatever the user has sliced to — the top 3 products *within the selected category*, not the global top 3 displayed under a category filter. This was verified by placing the measure in a matrix against `Category Name` and confirming the ratio varies per row.

### Validation

Each measure was tested in a matrix against `Date[Year]`, `Category Name` and `Employee Name`, and under active slicer selections, to confirm correct behaviour in multiple filter contexts. All dimension breakdowns reconcile to $1,265,793.29.

---

## 5. Report design

### Layout

Page 1 follows a **Z reading pattern**: KPI cards across the top (the primary scan position), the trend chart on the diagonal, supporting geography and shipper detail along the bottom. Filter controls are placed outside the reading path, in the top-right corner, because they are controls rather than content.

Visual sizes were set by explicit pixel coordinates (Format → General → Properties) rather than by eye, so gaps are consistent and panel edges align across rows.

### Page 1 — Executive Overview

Deliberately sparse. An executive page should be readable in roughly ten seconds, so it carries four KPIs and three charts and no more. Density belongs on Page 2.

**Monthly revenue chart — design change from the brief.** The brief specifies a line chart comparing current year against previous year. That construction is only meaningful when exactly one year is selected: with no selection, each month aggregates 1996+1997+1998 and `Revenue Previous Year` compares that against a meaninglessly shifted total.

The chart was instead built with `Date[Year]` in the **legend**, producing one line per year on a shared month axis. This:

- reads correctly under every filter state, including no selection
- shows seasonality and year-on-year gap simultaneously
- makes the partial-year problem self-evident rather than requiring a caption

`Revenue Previous Year` and `YoY Growth %` remain in use on the KPI cards.

**Donut chart — measure change.** The brief asks which shipping provider is used *most often*, which is a volume question. The chart therefore uses `Total Orders` rather than `Total Revenue`; revenue by shipper is close to meaningless, since the carrier did not generate the revenue. Freight cost by shipper would be the most useful version of this visual, but is not available for the grain reason described in section 2.

**Map.** Retained per the brief. A sorted bar chart would convey country ranking more efficiently than bubbles on a map, and it is sized modestly on that basis.

### Page 2 — Detailed Analysis

**Decomposition tree chosen over matrix.** Both are permitted. The tree was selected because this page is for root-cause investigation — following one path down to find where revenue concentrates — and its AI-split feature (high value / high variance) selects the highest-value branch automatically. A matrix would be better for simultaneous comparison across categories, but with 77 products and 89 customers a fully expanded three-level matrix is not scannable. The tree is saved pre-drilled to a representative path so the page is informative on arrival rather than showing a single collapsed root node.

The two bar charts use different orientations — horizontal for products (long names), vertical for employees (short names) — so they read as distinct analyses rather than repetition.

### Page 3 — Drill-through

Drill-through is configured on `Product Name`. The page title is dynamic:

```dax
Drillthrough Title =
"Order details of product - " & SELECTEDVALUE( vw_dim_product_enriched[Product Name], "All Products" )
```

`OrderID` was considered as a second drill-through field but deliberately omitted: no visual on Pages 1 or 2 displays an individual order, so the path would be unreachable. An unreachable drill-through route is worse than not offering one.

---

## 6. Data caveats

**The dataset covers 4 July 1996 to 6 May 1998.** 1996 and 1998 are partial years. This has three visible consequences, all correct behaviour rather than defects:

1. **`Revenue Previous Year` is blank for January–June 1997.** There is no corresponding 1996 data. The measure returns blank rather than zero; plotting zero would falsely imply no sales occurred.
2. **YoY growth for 1997 is strongly positive (+196.6%)** because 1996 contains only six months of trading.
3. **YoY growth for 1998 is strongly negative (−28.6%)**, and May 1998 shows a sharp drop because that month contains six days of data.

These figures reflect data coverage, not business performance, and should not be read as trends.

**Unfiltered time-intelligence totals.** On a totals row with no single year in context, `Revenue YTD` returns the most recent year-to-date period rather than a sum, and `YoY Growth %` compares all years against all shifted years. This is expected behaviour for time intelligence evaluated outside a single-period context, and is the reason a bare YTD measure should not be placed on a card without a year filter.

---

## 7. Files

```
DataViz_Project_<username>/
├── sql/
│   └── 01_create_views.sql      All five views, re-runnable top to bottom
├── pbix/
│   └── NorthwindSales.pbix      Report and model
└── docs/
    ├── documentation.md         This file
    └── screenshots/             Three report pages and model view
```

The SQL file uses `DROP VIEW IF EXISTS ... CASCADE` before each `CREATE VIEW`, so the whole script can be re-run after any edit. `CREATE OR REPLACE VIEW` alone is insufficient, since PostgreSQL will not permit a column rename or type change through it.
