-- ICT371 Q2: University Fee Payments
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q2;
SET search_path TO q2;

CREATE TABLE students (
 student_id SERIAL PRIMARY KEY,
 student_number VARCHAR(20) NOT NULL UNIQUE,
 full_name VARCHAR(100) NOT NULL,
 fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
 payment_id SERIAL PRIMARY KEY,
 student_id INTEGER NOT NULL REFERENCES students(student_id),
 amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
 paid_on DATE NOT NULL
);
CREATE TABLE payment_audit (
 audit_id SERIAL PRIMARY KEY,
 payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
 student_id INTEGER NOT NULL REFERENCES students(student_id),
 amount NUMERIC(12,2) NOT NULL,
 logged_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
 collection_date DATE PRIMARY KEY,
 payment_count INTEGER NOT NULL,
 total_amount NUMERIC(12,2) NOT NULL
);

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_due NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
 SELECT fee_due INTO v_due FROM students WHERE student_id=p_student_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id: %',p_student_id; END IF;
 SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments WHERE student_id=p_student_id;
 RETURN v_due-v_paid;
END; $$;

CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT,p_amount NUMERIC,p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
 IF p_amount IS NULL OR p_amount<=0 THEN RAISE EXCEPTION 'Payment amount must be positive'; END IF;
 IF p_paid_on IS NULL THEN RAISE EXCEPTION 'Payment date is required'; END IF;
 PERFORM 1 FROM students WHERE student_id=p_student_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id: %',p_student_id; END IF;
 v_balance:=fn_fee_balance(p_student_id);
 IF p_amount>v_balance THEN RAISE EXCEPTION 'Payment exceeds outstanding balance %',v_balance; END IF;
 INSERT INTO payments(student_id,amount,paid_on) VALUES(p_student_id,p_amount,p_paid_on);
END; $$;

CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO payment_audit(payment_id,student_id,amount,logged_at)
 VALUES(NEW.payment_id,NEW.student_id,NEW.amount,now());
 RETURN NULL;
END; $$;
CREATE TRIGGER trg_payments_audit AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

INSERT INTO students(student_number,full_name,fee_due) VALUES
('S001','Chanda Mwila',5000),('S002','Mutale Banda',2000),('S003','Tembo Phiri',4000);
CALL pr_receive_payment(1,1500,CURRENT_DATE-5);
CALL pr_receive_payment(1,1000,CURRENT_DATE-3);
CALL pr_receive_payment(1,500,CURRENT_DATE-1);
CALL pr_receive_payment(2,1000,CURRENT_DATE-4);
CALL pr_receive_payment(2,800,CURRENT_DATE-1);
CALL pr_receive_payment(2,200,CURRENT_DATE-1);

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,s.full_name,s.fee_due-COALESCE(SUM(p.amount),0) AS outstanding_balance
FROM students s LEFT JOIN payments p ON p.student_id=s.student_id
GROUP BY s.student_id,s.student_number,s.full_name,s.fee_due
HAVING s.fee_due-COALESCE(SUM(p.amount),0)>0;
CREATE INDEX idx_payments_student_paidon ON payments(student_id,paid_on);
EXPLAIN SELECT * FROM payments WHERE student_id=1
AND paid_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO daily_collections(collection_date,payment_count,total_amount)
 SELECT p_day,COUNT(*),COALESCE(SUM(amount),0) FROM payments WHERE paid_on=p_day
 ON CONFLICT(collection_date) DO UPDATE SET
 payment_count=EXCLUDED.payment_count,total_amount=EXCLUDED.total_amount;
END; $$;
SELECT cron.schedule('q2_collections','0 1 * * *',
 $$SET search_path TO q2; CALL pr_refresh_collections(CURRENT_DATE-1)$$);
