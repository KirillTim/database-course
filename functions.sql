CREATE OR REPLACE FUNCTION add_support_contract(INT, INT [])
  RETURNS VOID AS
$$
DECLARE
  vendor ALIAS FOR $1;
  machines_list ALIAS FOR $2;
  rec RECORD;
BEGIN
  FOR rec IN SELECT id
             FROM machines
             WHERE id = ANY (machines_list)
  LOOP
    INSERT INTO machineservicevendor (service_vendor, machine) VALUES (vendor, rec.id);
  END LOOP;
  RETURN;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION is_enough_staff_for_machine(INT)
  RETURNS BOOLEAN AS
$$
DECLARE
  machine ALIAS FOR $1;
  have   INT;
  needed INT;
BEGIN
  SELECT count(*)
  INTO have
  FROM staff
    JOIN staffcanworkon ON staff.id = staffcanworkon.staff_id
  WHERE staffcanworkon.machine_id = machine;
  SELECT work_stations
  INTO needed
  FROM machines
  WHERE machines.id = machine;
  RETURN (have >= needed);
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION add_build_step(INT, INT, FLOAT, INT, INT [])
  RETURNS VOID AS
$$
DECLARE
  result ALIAS FOR $1;
  machine_id ALIAS FOR $2;
  hours_ ALIAS FOR $3;
  plan_id ALIAS FOR $4;
  dependencies ALIAS FOR $5;
  d       INT;
  step_id INT;
BEGIN
  FOREACH d IN ARRAY dependencies LOOP
    IF NOT exists(SELECT 1
                  FROM components
                  WHERE id = d)
    THEN
      RAISE EXCEPTION 'unknown component id: %', d;
    END IF;
    IF d = result
    THEN
      RAISE EXCEPTION 'cycle dependency';
    END IF;
  END LOOP;
  IF NOT is_enough_staff_for_machine(machine_id)
  THEN
    RAISE EXCEPTION 'not enough workers for for `%`, id: %', (SELECT name
                                                              FROM machines
                                                              WHERE id = machine_id), machine_id;
  END IF;
  INSERT INTO buildsteps (result_component, machine, hours, plan) VALUES (result, machine_id, hours_, plan_id)
  RETURNING id
    INTO step_id;
  FOREACH d IN ARRAY dependencies LOOP
    INSERT INTO buildstepdependencies (step, component) VALUES (step_id, d);
  END LOOP;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION machine_hour_price(INT)
  RETURNS MONEY AS
$$
DECLARE
  machine_id ALIAS FOR $1;
  i      INT;
  needed INT;
  rec    RECORD;
  total  MONEY;
BEGIN
  i := 0;
  total := 0;
  SELECT work_stations
  INTO needed
  FROM machines
  WHERE id = machine_id;
  FOR rec IN (SELECT
                staff.id,
                first_name,
                hourly_wage
              FROM staff
                JOIN staffcanworkon ON staff.id = staffcanworkon.staff_id
              WHERE staffcanworkon.machine_id = 2
              ORDER BY hourly_wage) LOOP
    IF i < needed
    THEN
      i := i + 1;
      total := total + rec.hourly_wage;
    END IF;
  END LOOP;
  RETURN total;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION can_use_component(INT)
  RETURNS BOOLEAN AS
$$
DECLARE
  comp_id ALIAS FOR $1;
  prod INT := 0;
  buy  INT := 0;
BEGIN
  SELECT count(*)
  INTO prod
  FROM buildsteps
  WHERE result_component = comp_id;
  SELECT count(*)
  INTO buy
  FROM vendorssell
  WHERE component_id = comp_id;
  RETURN prod + buy > 0;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calc_production_cost(INT)
  RETURNS MONEY AS
$$
DECLARE
  step_id ALIAS FOR $1;
  total      MONEY;
  machine_id INT;
BEGIN
  SELECT sum(calc_cost(buildstepdependencies.component) * buildstepdependencies.count)
  INTO total
  FROM buildstepdependencies
    JOIN buildsteps ON buildstepdependencies.step = buildsteps.id
  WHERE buildsteps.id = step_id;
  IF total IS NULL
  THEN
    total := 0;
  END IF;
  SELECT machine
  INTO machine_id
  FROM buildsteps
  WHERE id = step_id;
  total := total + machine_hour_price(machine_id);
  RETURN total;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calc_cost(INT)
  RETURNS MONEY AS
$$
DECLARE
  component ALIAS FOR $1;
  buy_price MONEY = NULL;
  prod_cost MONEY = 0 :: MONEY;
  buildstep INT = NULL;
BEGIN
  SELECT id
  INTO buildstep
  FROM buildsteps
  WHERE result_component = component;

  SELECT min(price)
  INTO buy_price
  FROM vendorssell
  WHERE component_id = component;


  IF NOT buildstep ISNULL
  THEN
    prod_cost = calc_production_cost(buildstep);
  ELSE
    RETURN buy_price;
  END IF;
  IF buy_price < prod_cost
  THEN
    RETURN buy_price;
  ELSE
    RETURN prod_cost;
  END IF;
END;
$$ LANGUAGE plpgsql;

