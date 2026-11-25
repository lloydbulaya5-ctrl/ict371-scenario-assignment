-- ICT371 Advanced Database: Q6 - Monthly Payroll Processing
-- PostgreSQL + pg_cron
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE SCHEMA q6;
SET search_path TO q6;

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay NUMERIC(12,2) NOT NULL,
    net_pay NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT now()
);

-- (b)
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (c) FOR loop; ON CONFLICT DO NOTHING prevents duplicate monthly payroll.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active = TRUE
    LOOP
        v_net := fn_net_pay(r.employee_id);
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Audit changes to basic salary.
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) Seed data.
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mumba', 8000, 1000, 1500, TRUE),
    ('Brian Katongo', 6000, 500, 900, TRUE),
    ('Cynthia Ngoma', 10000, 2000, 2500, TRUE),
    ('Daniel Zimba', 5000, 400, 700, TRUE),
    ('Evelyn Musonda', 7000, 600, 1000, FALSE);

CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-10-01');

UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;

-- (e) Include payroll history for inactive employees.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index month-only searches.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Run at 02:00 on day 1, processing the previous month.
SELECT cron.schedule('q6_payroll', '0 2 1 * *',
    $$SET search_path TO q6;
      CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect job and run history.
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_payroll';
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
