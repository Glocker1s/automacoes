CREATE OR REPLACE FUNCTION "public"."fc_core_scramble_database" () RETURNS void
VOLATILE
AS $body$
BEGIN

 /*
        
   
      ******************************
      ** Nunca rodar em produção  **
      ** Nerver run in Production **
      ******************************
      
   
       Embaralha campos da base de dados das tabelas:   
              
                        tb_core_process_customer_data;
                        tb_core_process_customer_addresses;
                        tb_core_process_customer_emails;
                        tb_core_process_customer_bank_accounts;
                        tb_core_customer_data;
                        tb_core_customer_addresses;
                        tb_core_customer_emails;
                        tb_core_customer_bank_accounts;
      EX:
          select * from fc_core_scramble_database();
                        
                        
        Core Process data tables
        */
        
-- tb_core_process_customer_data
UPDATE
    tb_core_process_customer_data
SET
    name = scramble.name--,
    --cpf_cnpj = scramble.cpf_cnpj
FROM
    (
     SELECT
            id_process  ,
            id_contract ,
            seq_customer,
            name        ,
            cpf_cnpj
       FROM
            (
             SELECT
                    id_process  ,
                    id_contract ,
                    seq_customer,
                    UPPER( COALESCE(lead(SPLIT_PART(name, ' ', 1) ) over w , lag(SPLIT_PART(name,
                    ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
                    (SPLIT_PART(name, ' ', 3)) over w , lag(SPLIT_PART(name, ' ', 1), 3)over w) ||
                    ' ' || COALESCE(lead(SPLIT_PART(name, ' ', 1), (floor(random()*(7-2+1))+1)::INT
                    ) over w , lag(SPLIT_PART(name, ' ', 3), (floor(random()*(7-2+1))+1)::INT)over
                    w) ) AS name,
                    COALESCE(lag(cpf_cnpj, (floor(random()*(7-2+1))+1)::INT) over w, lead(cpf_cnpj,
                    (floor(random()*(7-2+1))+1)::INT) over w) AS cpf_cnpj
               FROM
                    tb_core_process_customer_data
                    --  where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_process_customer_data.id_process = scramble.id_process
AND tb_core_process_customer_data.id_contract = scramble.id_contract
AND tb_core_process_customer_data.seq_customer = scramble.seq_customer;


-- tb_core_process_customer_addresses
/*
nm_address
nm_complement
nm_neighborhood
nm_zip_code
*/
UPDATE
    tb_core_process_customer_addresses
SET
    nm_address = scramble.nm_address          ,
    nm_complement = scramble.nm_complement    ,
    nm_neighborhood = scramble.nm_neighborhood,
    nm_zip_code = scramble.nm_zip_code
FROM
    (
     SELECT
            seq_address    ,
            id_process     ,
            id_contract    ,
            seq_customer   ,
            nm_address     ,
            nm_complement  ,
            nm_neighborhood,
            nm_zip_code
       FROM
            (
             SELECT
                    seq_address ,
                    id_process  ,
                    id_contract ,
                    seq_customer,
                    UPPER( COALESCE(lead(SPLIT_PART(nm_address, ' ', 1) ) over w , lag(SPLIT_PART
                    (nm_address, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' ||
                    COALESCE(lead(SPLIT_PART(nm_address, ' ', 3)) over w , lag(SPLIT_PART
                    (nm_address, ' ', 1), 3)over w) || ' ' || COALESCE(lead(SPLIT_PART(nm_address,
                    ' ', 1), (floor(random()*(7-2+1))+1)::INT) over w , lag(SPLIT_PART(nm_address,
                    ' ', 3), (floor(random()*(7-2+1))+1)::INT)over w) ) AS nm_address,
                    COALESCE(lag(nm_complement, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (nm_complement, (floor(random()*(7-2+1))+1)::INT) over w) AS nm_complement ,
                    COALESCE(lag(nm_neighborhood, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (nm_neighborhood, (floor(random()*(7-2+1))+1)::INT) over w) AS nm_neighborhood
                    ,
                    COALESCE(lag(nm_zip_code, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (nm_zip_code, (floor(random()*(7-2+1))+1)::INT) over w) AS nm_zip_code
               FROM
                    tb_core_process_customer_addresses
                    --  where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_process_customer_addresses.seq_address = scramble.seq_address
AND tb_core_process_customer_addresses.id_process = scramble.id_process
AND tb_core_process_customer_addresses.id_contract = scramble.id_contract
AND tb_core_process_customer_addresses.seq_customer = scramble.seq_customer;

-- tb_core_process_customer_emails
UPDATE
    tb_core_process_customer_emails
SET
    email = scramble.email
FROM
    (
     SELECT
            seq_email   ,
            id_process  ,
            id_contract ,
            seq_customer,
            email
       FROM
            (
             SELECT
                    seq_email   ,
                    id_process  ,
                    id_contract ,
                    seq_customer,
                    LOWER( COALESCE(lead(SPLIT_PART(email, '@', 1) ) over w , lag(SPLIT_PART(email,
                    '@', 1), (floor(random()*(7-2+1))+1)::INT)over w) || '@' || COALESCE(lead
                    (SPLIT_PART(email, '@', 2), (floor(random()*(5-2+1))+1)::INT) over w , lag
                    (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+1)::INT)over w) ) AS email
               FROM
                    tb_core_process_customer_emails
                    --where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_process_customer_emails.seq_email = scramble.seq_email
AND tb_core_process_customer_emails.id_process = scramble.id_process
AND tb_core_process_customer_emails.id_contract = scramble.id_contract
AND tb_core_process_customer_emails.seq_customer = scramble.seq_customer ;

-- tb_core_process_customer_bank_accounts
/*
cpf_joint_holder
nm_joint_holder
cd_agency_number
cd_account_number
cd_account_digit
cd_agency_digit
*/
UPDATE
    tb_core_process_customer_bank_accounts
SET
    cpf_joint_holder = scramble.cpf_joint_holder  ,
    nm_joint_holder = scramble.nm_joint_holder    ,
    cd_agency_number = scramble.cd_agency_number  ,
    cd_account_number = scramble.cd_account_number,
    cd_account_digit = scramble.cd_account_digit  ,
    cd_agency_digit = scramble.cd_agency_digit
FROM
    (
     SELECT
            id_process       ,
            id_contract      ,
            seq_customer     ,
            seq_account      ,
            cpf_joint_holder ,
            nm_joint_holder  ,
            cd_agency_number ,
            cd_account_number,
            cd_account_digit ,
            cd_agency_digit
       FROM
            (
             SELECT
                    id_process  ,
                    id_contract ,
                    seq_customer,
                    seq_account ,
                    UPPER( COALESCE(lead(SPLIT_PART(nm_joint_holder, ' ', 1) ) over w , lag
                    (SPLIT_PART(nm_joint_holder, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w)
                    || ' ' || COALESCE(lead(SPLIT_PART(nm_joint_holder, ' ', 3)) over w , lag
                    (SPLIT_PART(nm_joint_holder, ' ', 1), 3)over w) || ' ' || COALESCE(lead
                    (SPLIT_PART(nm_joint_holder, ' ', 1), (floor(random()*(7-2+1))+1)::INT) over w
                    , lag(SPLIT_PART(nm_joint_holder, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
                    over w) ) AS nm_joint_holder,
                    COALESCE(lag(cpf_joint_holder, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cpf_joint_holder, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cpf_joint_holder ,
                    COALESCE(lag(cd_agency_number, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_agency_number, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cd_agency_number ,
                    COALESCE(lag(cd_account_number, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_account_number, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cd_account_number ,
                    COALESCE(lag(cd_account_digit, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_account_digit, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cd_account_digit ,
                    COALESCE(lag(cd_agency_digit, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_agency_digit, (floor(random()*(7-2+1))+1)::INT) over w) AS cd_agency_digit
               FROM
                    tb_core_process_customer_bank_accounts
                    --  where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_process_customer_bank_accounts.id_process = scramble.id_process
AND tb_core_process_customer_bank_accounts.id_contract = scramble.id_contract
AND tb_core_process_customer_bank_accounts.seq_customer = scramble.seq_customer
AND tb_core_process_customer_bank_accounts.seq_account = scramble.seq_account;

/*
Core data tables
*/
-- tb_core_customer_data


  
alter table tb_core_customer_data drop constraint if exists tb_core_customer_data_cli_uk;



UPDATE
    tb_core_customer_data
SET
    name = scramble.name--,
  --  cpf_cnpj = scramble.cpf_cnpj
FROM
    (
     SELECT
            id_contract,
            id_customer,
            name       ,
            cpf_cnpj
       FROM
            (
             SELECT
                    id_contract,
                    id_customer,
                    UPPER( COALESCE(lead(SPLIT_PART(name, ' ', 1) ) over w , lag(SPLIT_PART(name,
                    ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
                    (SPLIT_PART(name, ' ', 3)) over w , lag(SPLIT_PART(name, ' ', 1), 3)over w) ||
                    ' ' || COALESCE(lead(SPLIT_PART(name, ' ', 1), (floor(random()*(7-2+1))+1)::INT
                    ) over w , lag(SPLIT_PART(name, ' ', 3), (floor(random()*(7-2+1))+1)::INT)over
                    w) ) AS name,
                    /*
                    COALESCE(lag(cpf_cnpj, (floor(random()*(7-2+1))+1)::INT) over w, lead(cpf_cnpj,
                    (floor(random()*(7-2+1))+1)::INT) over w) AS cpf_cnpj
                    */
                    NULLIF(trim(TRANSLATE( COALESCE(lag(cpf_cnpj, (floor(random()*(7-2+1))+2)::INT)
                    over w, lead (cpf_cnpj, (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR,
                    '12345', '94' || (floor (random()*(10-2+1))+1)::VARCHAR || '74')),'')::NUMERIC
                    AS cpf_cnpj
               FROM
                    tb_core_customer_data
                    --  where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_customer_data.id_contract = scramble.id_contract
AND tb_core_customer_data.id_customer = scramble.id_customer ;


-- tb_core_customer_addresses
/*
nm_address
nm_complement
nm_neighborhood
nm_zip_code
*/
UPDATE
    tb_core_customer_addresses
SET
    nm_address = scramble.nm_address          ,
    nm_complement = scramble.nm_complement    ,
    nm_neighborhood = scramble.nm_neighborhood,
    nm_zip_code = scramble.nm_zip_code
FROM
    (
     SELECT
            id_contract    ,
            id_customer    ,
            seq_address    ,
            nm_address     ,
            nm_complement  ,
            nm_neighborhood,
            nm_zip_code
       FROM
            (
             SELECT
                    id_contract,
                    id_customer,
                    seq_address,
                    UPPER( COALESCE(lead(SPLIT_PART(nm_address, ' ', 1) ) over w , lag(SPLIT_PART
                    (nm_address, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' ||
                    COALESCE(lead(SPLIT_PART(nm_address, ' ', 3)) over w , lag(SPLIT_PART
                    (nm_address, ' ', 2), 3)over w) || ' ' || COALESCE(lead(SPLIT_PART(nm_address,
                    ' ', 2), (floor(random()*(7-2+1))+1)::INT) over w , lag(SPLIT_PART(nm_address,
                    ' ', 3), (floor(random()*(7-2+1))+1)::INT)over w) ) AS nm_address,
                    COALESCE(lag(nm_complement, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (nm_complement, (floor(random()*(7-2+1))+1)::INT) over w) AS nm_complement ,
                    COALESCE(lag(nm_neighborhood, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (nm_neighborhood, (floor(random()*(7-2+1))+1)::INT) over w) AS nm_neighborhood
                    ,
                    COALESCE(lag(nm_zip_code, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (nm_zip_code, (floor(random()*(7-2+1))+1)::INT) over w) AS nm_zip_code
               FROM
                    tb_core_customer_addresses
                    --  where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_customer_addresses.id_contract = scramble.id_contract
AND tb_core_customer_addresses.id_customer = scramble.id_customer
AND tb_core_customer_addresses.seq_address = scramble.seq_address ;


-- tb_core_process_customer_emails
UPDATE
    tb_core_customer_emails
SET
    email = scramble.email
FROM
    (
     SELECT
            id_contract,
            id_customer,
            seq_email  ,
            email
       FROM
            (
             SELECT
                    id_contract,
                    id_customer,
                    seq_email  ,
                    LOWER( COALESCE(lead(SPLIT_PART(email, '@', 1) ) over w , lag(SPLIT_PART(email,
                    '@', 1), (floor(random()*(7-2+1))+1)::INT)over w) || '@' || COALESCE(lead
                    (SPLIT_PART(email, '@', 2), (floor(random()*(5-2+1))+1)::INT) over w , lag
                    (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+1)::INT)over w) ) AS email
               FROM
                    tb_core_customer_emails
                    --where id_process between 60930 and 60950
                    window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_customer_emails.id_contract = scramble.id_contract
AND tb_core_customer_emails.id_customer = scramble.id_customer
AND tb_core_customer_emails.seq_email = scramble.seq_email ;


-- tb_core_process_customer_bank_accounts
/*
cpf_joint_holder
nm_joint_holder
cd_agency_number
cd_account_number
cd_account_digit
cd_agency_digit
*/
UPDATE
    tb_core_customer_bank_accounts
SET
    cpf_joint_holder = scramble.cpf_joint_holder  ,
    nm_joint_holder = scramble.nm_joint_holder    ,
    cd_agency_number = scramble.cd_agency_number  ,
    cd_account_number = scramble.cd_account_number,
    cd_account_digit = scramble.cd_account_digit  ,
    cd_agency_digit = scramble.cd_agency_digit
FROM
    (
     SELECT
            id_contract      ,
            id_customer      ,
            seq_bank_account ,
            cpf_joint_holder ,
            nm_joint_holder  ,
            cd_agency_number ,
            cd_account_number,
            cd_account_digit ,
            cd_agency_digit
       FROM
            (
             SELECT
                    id_contract     ,
                    id_customer     ,
                    seq_bank_account,
                    UPPER( COALESCE(lead(SPLIT_PART(nm_joint_holder, ' ', 1) ) over w , lag
                    (SPLIT_PART(nm_joint_holder, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w)
                    || ' ' || COALESCE(lead(SPLIT_PART(nm_joint_holder, ' ', 3)) over w , lag
                    (SPLIT_PART(nm_joint_holder, ' ', 1), 3)over w) || ' ' || COALESCE(lead
                    (SPLIT_PART(nm_joint_holder, ' ', 1), (floor(random()*(7-2+1))+1)::INT) over w
                    , lag(SPLIT_PART(nm_joint_holder, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
                    over w) ) AS nm_joint_holder,
                    COALESCE(lag(cpf_joint_holder, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cpf_joint_holder, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cpf_joint_holder ,
                    COALESCE(lag(cd_agency_number, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_agency_number, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cd_agency_number ,
                    COALESCE(lag(cd_account_number, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_account_number, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cd_account_number ,
                    COALESCE(lag(cd_account_digit, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_account_digit, (floor(random()*(7-2+1))+1)::INT) over w) AS
                    cd_account_digit ,
                    COALESCE(lag(cd_agency_digit, (floor(random()*(7-2+1))+1)::INT) over w, lead
                    (cd_agency_digit, (floor(random()*(7-2+1))+1)::INT) over w) AS cd_agency_digit
               FROM
                    tb_core_customer_bank_accounts window w AS (ORDER BY random()) ) x ) scramble
WHERE
    tb_core_customer_bank_accounts.id_contract = scramble.id_contract
AND tb_core_customer_bank_accounts.id_customer = scramble.id_customer
AND tb_core_customer_bank_accounts.seq_bank_account = scramble.seq_bank_account ;
END;
$body$ LANGUAGE plpgsql;
