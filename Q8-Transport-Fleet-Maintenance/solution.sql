-- ICT371 Advanced Database: Q8 - Transport Fleet Maintenance
-- PostgreSQL + pg_cron
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE SCHEMA q8;
SET search_path TO q8;

CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(15) NOT NULL UNIQUE,
    current_odometer INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer INTEGER NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on DATE NOT NULL
);

-- (b)
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_cur INTEGER;
    v_last INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_cur, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN (v_cur - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (c) The trigger updates the odometer.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Verify and update the odometer once.
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER AS $$
DECLARE
    v_cur INTEGER;
BEGIN
    SELECT current_odometer INTO v_cur
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_cur THEN
        RAISE EXCEPTION 'Start odometer % does not match current odometer %', NEW.start_odometer, v_cur;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % <= start %', NEW.end_odometer, NEW.start_odometer;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- (a) Seed trips through the procedure.
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ZM 1001', 12000, 6000),
    ('ZM 2002', 8000, 5000),
    ('ZM 3003', 20000, 15500);

CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12300);
CALL pr_record_trip(1, CURRENT_DATE - 3, 12300, 12500);
CALL pr_record_trip(2, CURRENT_DATE - 5, 8000, 8400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 8400, 8700);
CALL pr_record_trip(3, CURRENT_DATE - 4, 20000, 20400);
CALL pr_record_trip(3, CURRENT_DATE - 1, 20400, 20600);
-- Should fail: CALL pr_record_trip(1, CURRENT_DATE, 99, 150);

-- (e)
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;

-- (f)
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Upsert due vehicles and remove alerts for vehicles no longer due.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE sa.vehicle_id = v.vehicle_id
      AND v.current_odometer - v.last_service_odometer < 5000;
END;
$$;

SELECT cron.schedule('q8_alerts', '0 6 * * 1',
    $$SET search_path TO q8; CALL pr_refresh_service_alerts()$$);
