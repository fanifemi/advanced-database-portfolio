-- =====================================================================
-- Portfolio 3 — 00_setup_lab.sql
-- Fictional "lab" customers used by the experiments, plus a helper that
-- opens a freshly funded account, so every experiment starts from a
-- known state without touching other customers' data.
-- =====================================================================
SET search_path TO payhaven;

INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier, status)
VALUES ('24000000001', 'Lab',  'Alpha',   'lab.alpha@payhaven.example',   '+2348090000001', '1990-01-01', 3, 'ACTIVE'),
       ('24000000002', 'Lab',  'Bravo',   'lab.bravo@payhaven.example',   '+2348090000002', '1990-01-01', 3, 'ACTIVE'),
       ('24000000003', 'Lab',  'Charlie', 'lab.charlie@payhaven.example', '+2348090000003', '1990-01-01', 2, 'ACTIVE')
ON CONFLICT (bvn) DO NOTHING;

INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name)
SELECT customer_id, '058', '0999999999', 'LAB EXTERNAL PAYEE' FROM customers WHERE bvn = '24000000001'
ON CONFLICT DO NOTHING;

CREATE SEQUENCE IF NOT EXISTS lab_account_seq;

-- lab_new_account('24000000001', 'PH_TIER3', 150000) -> '4000000007'
CREATE OR REPLACE FUNCTION lab_new_account(p_bvn TEXT, p_product TEXT, p_opening NUMERIC)
RETURNS CHAR(10) LANGUAGE plpgsql AS $$
DECLARE v_no CHAR(10) := '4' || lpad(nextval('lab_account_seq')::text, 9, '0');
BEGIN
    INSERT INTO accounts (account_number, customer_id, product_code, account_name)
    SELECT v_no, customer_id, p_product, 'LAB ' || v_no FROM customers WHERE bvn = p_bvn;
    IF p_opening > 0 THEN
        PERFORM deposit('LAB-OPEN-' || v_no, v_no, p_opening);
    END IF;
    RETURN v_no;
END $$;
