-- ICT371 Advanced Database: Q7 - Water Meter Readings and Billing
-- PostgreSQL + pg_cron
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE SCHEMA q7;
SET search_path TO q7;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_cust_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
);

-- (b) First 10 units cost K5 each; additional units cost K8 each.
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;
    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    ELSE
        RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- (c)
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev NUMERIC(10,2);
    v_curr NUMERIC(10,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- (d) Reject a meter reading that moves backwards.
CREATE OR REPLACE FUNCTION trg_fn_reading_check() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_reading_check();

-- (a) Seed data.
INSERT INTO customers (full_name) VALUES ('Mary Chisha'), ('John Simbeye'), ('Agnes Kapota');
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-10-01', 100, 100),
    (2, DATE '2026-10-01', 200, 210),
    (3, DATE '2026-10-01', 50, 75),
    (1, DATE '2026-11-01', 100, 112),
    (2, DATE '2026-11-01', 210, 215),
    (3, DATE '2026-11-01', 75, 100);
-- Should fail: INSERT INTO readings VALUES (DEFAULT, 1, DATE '2026-12-01', 120, 110);

CALL pr_generate_bill(1, CURRENT_DATE - 15);
CALL pr_generate_bill(2, CURRENT_DATE - 15);
CALL pr_generate_bill(3, CURRENT_DATE - 15);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);
UPDATE bills SET amount_paid = 20 WHERE bill_id = 2;

-- (e) Show overdue bills with an outstanding balance.
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Partial index for unpaid bills, searched by due date.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
SET enable_seqscan = off;
EXPLAIN SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Refresh the daily total receivables snapshot.
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule('q7_receivables', '30 0 * * *',
    $$SET search_path TO q7; CALL pr_refresh_receivables()$$);
