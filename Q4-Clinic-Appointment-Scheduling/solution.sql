-- ICT371 Q4: Clinic Appointment Scheduling
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q4;
SET search_path TO q4;

CREATE TABLE patients(patient_id SERIAL PRIMARY KEY,full_name VARCHAR(100) NOT NULL);
CREATE TABLE doctors(doctor_id SERIAL PRIMARY KEY,full_name VARCHAR(100) NOT NULL);
CREATE TABLE appointments(
 appointment_id SERIAL PRIMARY KEY,patient_id INTEGER NOT NULL REFERENCES patients(patient_id),
 doctor_id INTEGER NOT NULL REFERENCES doctors(doctor_id),appointment_day DATE NOT NULL,
 slot_time TIME NOT NULL,status VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
 CHECK(status IN('BOOKED','ATTENDED','CANCELLED')),
 CHECK(slot_time IN(TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00'))
);
CREATE TABLE clinic_summary(
 summary_date DATE PRIMARY KEY,booked_count INTEGER NOT NULL,
 attended_count INTEGER NOT NULL,cancelled_count INTEGER NOT NULL
);

CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT,p_day DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_count INTEGER;
BEGIN
 PERFORM 1 FROM doctors WHERE doctor_id=p_doctor_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor_id: %',p_doctor_id; END IF;
 SELECT COUNT(*) INTO v_count FROM appointments
 WHERE doctor_id=p_doctor_id AND appointment_day=p_day AND status<>'CANCELLED';
 RETURN v_count;
END; $$;

CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT,p_doctor_id INT,p_day DATE,p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
 PERFORM 1 FROM patients WHERE patient_id=p_patient_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient_id: %',p_patient_id; END IF;
 PERFORM 1 FROM doctors WHERE doctor_id=p_doctor_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor_id: %',p_doctor_id; END IF;
 IF p_day IS NULL OR p_day<CURRENT_DATE THEN RAISE EXCEPTION 'Appointment date is in the past'; END IF;
 IF p_slot IS NULL OR p_slot NOT IN(TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00')
 THEN RAISE EXCEPTION 'Unsupported appointment slot: %',p_slot; END IF;
 INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status)
 VALUES(p_patient_id,p_doctor_id,p_day,p_slot,'BOOKED');
END; $$;

CREATE OR REPLACE FUNCTION trg_fn_slot_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.status<>'CANCELLED' AND EXISTS(
  SELECT 1 FROM appointments a WHERE a.doctor_id=NEW.doctor_id
  AND a.appointment_day=NEW.appointment_day AND a.slot_time=NEW.slot_time
  AND a.status<>'CANCELLED' AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
 ) THEN RAISE EXCEPTION 'Appointment slot is already taken'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_appointments_clash BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_slot_clash();

INSERT INTO patients(full_name) VALUES('Grace Zulu'),('Peter Nkandu'),('Ruth Lungu');
INSERT INTO doctors(full_name) VALUES('Dr. Mumba'),('Dr. Sakala'),('Dr. Tembo');
CALL pr_book_appointment(1,1,CURRENT_DATE,TIME '09:00');
CALL pr_book_appointment(2,1,CURRENT_DATE,TIME '10:00');
CALL pr_book_appointment(3,2,CURRENT_DATE,TIME '09:00');
CALL pr_book_appointment(1,2,CURRENT_DATE+1,TIME '11:00');
CALL pr_book_appointment(2,3,CURRENT_DATE+1,TIME '12:00');
CALL pr_book_appointment(3,3,CURRENT_DATE+1,TIME '09:00');
UPDATE appointments SET status='ATTENDED' WHERE appointment_id=2;
UPDATE appointments SET status='CANCELLED' WHERE appointment_id=6;

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,d.full_name AS doctor_name,a.slot_time
FROM appointments a JOIN patients p ON p.patient_id=a.patient_id
JOIN doctors d ON d.doctor_id=a.doctor_id
WHERE a.appointment_day=CURRENT_DATE AND a.status='BOOKED'
ORDER BY a.slot_time;
CREATE INDEX idx_appt_day_doctor ON appointments(appointment_day,doctor_id);
EXPLAIN SELECT * FROM appointments WHERE appointment_day=CURRENT_DATE AND doctor_id=1;

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO clinic_summary(summary_date,booked_count,attended_count,cancelled_count)
 SELECT p_day,COUNT(*) FILTER(WHERE status='BOOKED'),
 COUNT(*) FILTER(WHERE status='ATTENDED'),COUNT(*) FILTER(WHERE status='CANCELLED')
 FROM appointments WHERE appointment_day=p_day
 ON CONFLICT(summary_date) DO UPDATE SET booked_count=EXCLUDED.booked_count,
 attended_count=EXCLUDED.attended_count,cancelled_count=EXCLUDED.cancelled_count;
END; $$;
SELECT cron.schedule('q4_clinic','0 1 * * *',
 $$SET search_path TO q4; CALL pr_refresh_clinic_summary(CURRENT_DATE-1)$$);
