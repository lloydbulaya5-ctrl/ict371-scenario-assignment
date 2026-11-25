-- ICT371 Q1: Pharmacy Stock and Daily Sales (PostgreSQL)
-- Run order matters: tables -> function -> procedure -> trigger -> seed -> view -> index -> job

-- (a) TABLES ---------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)   NOT NULL,
    unit_price    NUMERIC(10,2)  NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER        NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),  -- price at time of sale
    sold_on     DATE          NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) FUNCTION -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql;

-- (c) PROCEDURE ------------------------------------------------------------
-- Any RAISE EXCEPTION aborts the whole call, so both tables stay unchanged.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    -- FOR UPDATE locks the row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- deduct exactly once, here only
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) TRIGGER --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;  -- return value ignored for AFTER row triggers
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only when stock really changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) SEED DATA (after trigger, sales loaded THROUGH the procedure) ----------
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  50),
    ('Ibuprofen 400mg',   4.00,  30),
    ('Cough Syrup',      15.00,  12);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3,  8, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(4,  5, CURRENT_DATE - 1);   -- stock 12 -> 7 (now low)
CALL pr_record_sale(2,  3, CURRENT_DATE);

-- Test an invalid sale: must fail and change nothing
-- CALL pr_record_sale(4, 999, CURRENT_DATE);   -- ERROR: Insufficient stock
-- SELECT * FROM medicines;  SELECT * FROM sales;  SELECT * FROM stock_audit;

-- (e) VIEW -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;   -- shows Cough Syrup (7) after the sale

-- (f) INDEX ----------------------------------------------------------------
-- Equality column (medicine_id) first, range column (sold_on) second:
-- the B-tree jumps to one medicine, then scans only the date range in order.
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);

-- On tiny tables the planner prefers a seq scan; force index use to demonstrate:
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) SCHEDULED JOB --------------------------------------------------------
-- UPSERT (ON CONFLICT) REPLACES the day's row, so reruns never double count.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- pg_cron (needs shared_preload_libraries = 'pg_cron' on the server)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_sales_daily',
    '15 0 * * *',                                   -- every day at 00:15
    $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$     -- previous day
);

-- Prove rerun safety:
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;   -- still ONE row, same totals

-- Inspect job: SELECT * FROM cron.job;  SELECT * FROM cron.job_run_details;
