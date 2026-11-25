-- ICT371 Q3: Library Returns and Overdue Fines
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q3;
SET search_path TO q3;

CREATE TABLE books(book_id SERIAL PRIMARY KEY,title VARCHAR(150) NOT NULL);
CREATE TABLE loans(
 loan_id SERIAL PRIMARY KEY,book_id INTEGER NOT NULL REFERENCES books(book_id),
 borrower_name VARCHAR(100) NOT NULL,borrowed_on DATE NOT NULL,due_on DATE NOT NULL,
 returned_on DATE,fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK(fine_amount>=0),
 CHECK(due_on>=borrowed_on)
);
CREATE TABLE loan_audit(
 audit_id SERIAL PRIMARY KEY,loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
 old_returned_on DATE,new_returned_on DATE,changed_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary(
 snapshot_date DATE PRIMARY KEY,overdue_count INTEGER NOT NULL,total_fine NUMERIC(12,2) NOT NULL
);

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT,p_as_of DATE)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql AS $$
DECLARE v_due DATE;v_returned DATE;v_end DATE;
BEGIN
 SELECT due_on,returned_on INTO v_due,v_returned FROM loans WHERE loan_id=p_loan_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan_id: %',p_loan_id; END IF;
 v_end:=LEAST(p_as_of,COALESCE(v_returned,p_as_of));
 RETURN 2*GREATEST(v_end-v_due,0);
END; $$;

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT,p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE;v_returned DATE;v_fine NUMERIC(10,2);
BEGIN
 SELECT borrowed_on,returned_on INTO v_borrowed,v_returned FROM loans
 WHERE loan_id=p_loan_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan_id: %',p_loan_id; END IF;
 IF v_returned IS NOT NULL THEN RAISE EXCEPTION 'Loan already returned'; END IF;
 IF p_returned_on IS NULL OR p_returned_on<v_borrowed THEN
  RAISE EXCEPTION 'Return date cannot be before borrow date';
 END IF;
 v_fine:=fn_loan_fine(p_loan_id,p_returned_on);
 UPDATE loans SET returned_on=p_returned_on,fine_amount=v_fine WHERE loan_id=p_loan_id;
END; $$;

CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO loan_audit(loan_id,old_returned_on,new_returned_on)
 VALUES(OLD.loan_id,OLD.returned_on,NEW.returned_on);
 RETURN NULL;
END; $$;
CREATE TRIGGER trg_loans_audit AFTER UPDATE ON loans FOR EACH ROW
WHEN(OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

INSERT INTO books(title) VALUES('Database Systems'),('Operating Systems'),('Computer Networks');
INSERT INTO loans(book_id,borrower_name,borrowed_on,due_on) VALUES
(1,'Alice',CURRENT_DATE-20,CURRENT_DATE-6),
(2,'Bob',CURRENT_DATE-5,CURRENT_DATE+9),
(3,'Chanda',CURRENT_DATE-30,CURRENT_DATE-16),
(1,'Dennis',CURRENT_DATE-12,CURRENT_DATE-2),
(2,'Eve',CURRENT_DATE-40,CURRENT_DATE-26),
(3,'Faith',CURRENT_DATE-3,CURRENT_DATE+11);
CALL pr_return_loan(3,CURRENT_DATE-10);
CALL pr_return_loan(4,CURRENT_DATE-2);

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,l.borrower_name,l.due_on,fn_loan_fine(l.loan_id,CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id=l.book_id
WHERE l.returned_on IS NULL AND l.due_on<CURRENT_DATE;
CREATE INDEX idx_loans_book_unreturned ON loans(book_id) WHERE returned_on IS NULL;
EXPLAIN SELECT * FROM loans WHERE book_id=1 AND returned_on IS NULL;

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO overdue_summary(snapshot_date,overdue_count,total_fine)
 SELECT p_as_of,COUNT(*),COALESCE(SUM(fn_loan_fine(loan_id,p_as_of)),0)
 FROM loans WHERE(returned_on IS NULL OR returned_on>p_as_of) AND due_on<p_as_of
 ON CONFLICT(snapshot_date) DO UPDATE SET
 overdue_count=EXCLUDED.overdue_count,total_fine=EXCLUDED.total_fine;
END; $$;
SELECT cron.schedule('q3_overdue','10 0 * * *',
 $$SET search_path TO q3; CALL pr_refresh_overdue(CURRENT_DATE)$$);
