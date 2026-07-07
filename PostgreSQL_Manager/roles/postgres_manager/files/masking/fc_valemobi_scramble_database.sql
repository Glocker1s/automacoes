CREATE
OR REPLACE FUNCTION "public"."fc_valemobi_scramble_database" () RETURNS void VOLATILE AS $body$
BEGIN
	/*
	Embaralha campos da base de dados das tabelas:
	Sramble database fields

	      ******************************
	      ** Nunca rodar em produção  **
	      ** Nerver run in Production **
	      ******************************
	      
	    Ex.:
	       select * from fc_valemobi_scramble_database();
		

	nm_database            nm_table    nm_column      tp_scramble
	---------------------- ----------- -------------- ------------
	tb_investor name           name
	tb_investor email          random_email
	tb_investor cnpj_cpf       cpf_cnpj
	tb_investor phone_home     phone
	tb_investor phone_mobile   phone
	tb_investor phone_business phone
	tb_investor document_number
	*/

-- tb_investor
UPDATE
    tb_investor
SET
    name = scramble.name                                                 ,
    email = scramble.email                                               ,
  --  cnpj_cpf = scramble.cnpj_cpf                                         ,
    phone_home = scramble.phone_home                                     ,
    phone_mobile = scramble.phone_mobile                                 ,
    phone_business = scramble.phone_business                             ,
    document_number = scramble.document_number                           ,
    address2 = scramble.address2                                         ,
    city = scramble.city                                                 ,
    zip = scramble.zip
FROM
    (
     SELECT
            id_investor,
            UPPER( COALESCE(lead(SPLIT_PART(name, ' ', 1),3 ) over w , lag(SPLIT_PART(name, ' ', 2)
            , (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead (SPLIT_PART(name,
            ' ', 3),2) over w , lag(SPLIT_PART(name, ' ', 1), 3)over w) || ' ' || COALESCE(lead
            (SPLIT_PART (name, ' ', 1), (floor(random()*(7-2+1))+1)::INT ) over w , lag(SPLIT_PART
            (name, ' ', 3 ), (floor(random()*(7-2+1))+1)::INT)over w) ) AS name,
            NULLIF(trim(TRANSLATE( COALESCE(lag(cnpj_cpf, (floor(random()*(7-2+1))+2)::INT) over w,
            lead (cnpj_cpf, (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR, '12345', '94' ||
            (floor (random()*(10-2+1))+1)::VARCHAR || '74')),'')::NUMERIC AS cnpj_cpf,
            TRANSLATE(TRANSLATE(TRANSLATE(TRANSLATE(LOWER( COALESCE(lag(SPLIT_PART(email, '@', 1) )
            over w , lead(SPLIT_PART(email, '@', 1), (floor(random()*(7-2+1))+1)::INT)over w) ||
            '@' || COALESCE(lead (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+2)::INT) over
            w , lag (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+2)::INT)over w) ) , '_',
            '.'), 'a', 'e'), 'u','o'), 'i','a') AS email ,
            TRANSLATE( COALESCE(lag(phone_home, (floor(random()*(7-2+1))+2)::INT) over w, lead
            (phone_home, (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR, '1234567', '941' ||
            (floor(random()*(10-2+1))+1)::VARCHAR ||'423') AS phone_home,
            TRANSLATE( COALESCE(lag(phone_mobile, (floor(random()*(7-2+1))+2)::INT) over w, lead
            (phone_mobile, (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR, '1234567', '861' ||
            (floor(random()*(10-2+1))+1)::VARCHAR ||'254') AS phone_mobile,
            TRANSLATE( COALESCE(lag(phone_business, (floor(random()*(7-2+1))+2)::INT) over w, lead
            (phone_business, (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR, '1234567', '715'
            || (floor(random()*(10-2+1))+1)::VARCHAR ||'348') AS phone_business,
            TRANSLATE( COALESCE(lag(document_number, (floor(random()*(7-2+1))+2)::INT) over w, lead
            (document_number, (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR, '12345', '94' ||
            (floor (random()*(10-2+1))+1)::VARCHAR || '74') AS document_number,
            UPPER( COALESCE(lead(SPLIT_PART(address, ' ', 1), 2 ) over w , lag(SPLIT_PART (address,
            ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead (SPLIT_PART
            (address, ' ', 3)) over w , lag(SPLIT_PART(address, ' ', 1), 3)over w) || ' ' ||
            COALESCE(lead(SPLIT_PART(address, ' ', 1), (floor(random()*(7-2+1))+1) ::INT ) over w ,
            lag(SPLIT_PART(address, ' ', 3), (floor(random()*(7-2+1))+1)::INT) over w) ) AS address
            ,
            UPPER( COALESCE(lead(SPLIT_PART(address2, ' ', 1), 2 ) over w , lag(SPLIT_PART
            (address2, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(address2, ' ', 3)) over w , lag(SPLIT_PART(address2, ' ', 1), 3)over w) ||
            ' ' || COALESCE(lead(SPLIT_PART(address2, ' ', 1), (floor(random()*(7-2+1))+1) ::INT )
            over w , lag(SPLIT_PART(address2, ' ', 3), (floor(random()*(7-2+1))+1)::INT) over w) )
            AS address2 ,
            UPPER( COALESCE(lead(SPLIT_PART(city, ' ', 1), 2 ) over w , lag(SPLIT_PART (city, ' ',
            2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead (SPLIT_PART(city,
            ' ', 3)) over w , lag(SPLIT_PART(city, ' ', 1), 3)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(city, ' ', 1), (floor(random()*(7-2+1))+1) ::INT ) over w , lag(SPLIT_PART
            (city, ' ', 3), (floor(random()*(7-2+1))+1)::INT) over w) ) AS city ,
            TRANSLATE( COALESCE(lag(zip, (floor(random()*(7-2+1))+2)::INT) over w, lead (zip,
            (floor(random()*(7-2+1))+1)::INT) over w)::VARCHAR, '12345', '94' || (floor (random()*
            (10-2+1))+1)::VARCHAR || '74') AS zip
       FROM
            tb_investor window w AS (ORDER BY random())) scramble
WHERE
    tb_investor.id_investor = scramble.id_investor;

/*
nm_table              nm_column   tp_scramble
--------------------- ----------- ------------
tb_btc_customer_event nm_customer name
tb_btc_customer_event nm_nickname name
tb_btc_customer_event email       random_email
*/
UPDATE
    tb_btc_customer_event
SET
    nm_customer = scramble.nm_customer,
    nm_nickname = scramble.nm_nickname,
    email = scramble.email
FROM
    (
     SELECT
            id_contract    ,
            id_btc_customer,
            seq_event      ,
            UPPER( COALESCE(lead(SPLIT_PART(nm_customer, ' ', 1) , 3) over w , lag(SPLIT_PART
            (nm_customer, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(nm_customer, ' ', 3)) over w , lag(SPLIT_PART(nm_customer, ' ', 1), 3)over
            w) || ' ' || COALESCE(lead(SPLIT_PART(nm_customer, ' ', 1), (floor(random()*(7-2+1))+1)
            ::INT ) over w , lag(SPLIT_PART(nm_customer, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
            over w) ) AS nm_customer,
            UPPER( COALESCE(lead(SPLIT_PART(nm_nickname, ' ', 1), 2 ) over w , lag(SPLIT_PART
            (nm_nickname, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(nm_nickname, ' ', 3)) over w , lag(SPLIT_PART(nm_nickname, ' ', 1), 3)over
            w) || ' ' || COALESCE(lead(SPLIT_PART(nm_nickname, ' ', 1), (floor(random()*(7-2+1))+1)
            ::INT ) over w , lag(SPLIT_PART(nm_nickname, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
            over w) ) AS nm_nickname,
            TRANSLATE(TRANSLATE(TRANSLATE(TRANSLATE(LOWER( COALESCE(lag(SPLIT_PART(email, '@', 1) )
            over w , lead(SPLIT_PART(email, '@', 1), (floor(random()*(7-2+1))+1)::INT)over w) ||
            '@' || COALESCE(lead (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+2)::INT) over
            w , lag (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+2)::INT)over w) ) , '_',
            '.'), 'a', 'e'), 'u','o'), 'i','a') AS email
       FROM
            tb_btc_customer_event window w AS (ORDER BY random()) ) scramble
WHERE
    tb_btc_customer_event.id_contract = scramble.id_contract
AND tb_btc_customer_event.id_btc_customer = scramble.id_btc_customer
AND tb_btc_customer_event.seq_event = scramble.seq_event;

/*
nm_table        nm_column   tp_scramble
--------------- ----------- ------------
tb_btc_customer nm_customer name
tb_btc_customer nm_nickname name
tb_btc_customer email       random_email
*/
UPDATE
    tb_btc_customer
SET
    nm_customer = scramble.nm_customer,
    nm_nickname = scramble.nm_nickname,
    email = scramble.email
FROM
    (
     SELECT
            id_contract     ,
            id_btc_customer ,
            UPPER( COALESCE(lead(SPLIT_PART(nm_customer, ' ', 1) , 3) over w , lag(SPLIT_PART
            (nm_customer, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(nm_customer, ' ', 3)) over w , lag(SPLIT_PART(nm_customer, ' ', 1), 3)over
            w) || ' ' || COALESCE(lead(SPLIT_PART(nm_customer, ' ', 1), (floor(random()*(7-2+1))+1)
            ::INT ) over w , lag(SPLIT_PART(nm_customer, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
            over w) ) AS nm_customer,
            UPPER( COALESCE(lead(SPLIT_PART(nm_nickname, ' ', 1), 2 ) over w , lag(SPLIT_PART
            (nm_nickname, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(nm_nickname, ' ', 3)) over w , lag(SPLIT_PART(nm_nickname, ' ', 1), 3)over
            w) || ' ' || COALESCE(lead(SPLIT_PART(nm_nickname, ' ', 1), (floor(random()*(7-2+1))+1)
            ::INT ) over w , lag(SPLIT_PART(nm_nickname, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
            over w) ) AS nm_nickname,
            TRANSLATE(TRANSLATE(TRANSLATE(TRANSLATE(LOWER( COALESCE(lag(SPLIT_PART(email, '@', 1) )
            over w , lead(SPLIT_PART(email, '@', 1), (floor(random()*(7-2+1))+1)::INT)over w) ||
            '@' || COALESCE(lead (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+2)::INT) over
            w , lag (SPLIT_PART(email, '@', 2), (floor(random()*(7-2+1))+2)::INT)over w) ) , '_',
            '.'), 'a', 'e'), 'u','o'), 'i','a') AS email
       FROM
            tb_btc_customer window w AS (ORDER BY random()) ) scramble
WHERE
    tb_btc_customer.id_contract = scramble.id_contract
AND tb_btc_customer.id_btc_customer = scramble.id_btc_customer;


/*
tb_btc_advisor nm_advisor name
*/
UPDATE
    tb_btc_customer
SET
    nm_advisor = scramble.nm_advisor
FROM
    (
     SELECT
            id_contract,
            nu_advisor ,
            UPPER( COALESCE(lead(SPLIT_PART(nm_advisor, ' ', 1) , 3) over w , lag(SPLIT_PART
            (nm_advisor, ' ', 2), (floor(random()*(7-2+1))+1)::INT)over w) || ' ' || COALESCE(lead
            (SPLIT_PART(nm_customer, ' ', 3)) over w , lag(SPLIT_PART(nm_customer, ' ', 1), 3)over
            w) || ' ' || COALESCE(lead(SPLIT_PART(nm_advisor, ' ', 1), (floor(random()*(7-2+1))+1)
            ::INT ) over w , lag(SPLIT_PART(nm_advisor, ' ', 3), (floor(random()*(7-2+1))+1)::INT)
            over w) ) AS nm_advisor
       FROM
            tb_btc_customer window w AS (ORDER BY random()) ) scramble
WHERE
    tb_btc_customer.id_contract = scramble.id_contract
AND tb_btc_customer.nu_advisor = scramble.nu_advisor;

/*
hide cei investors
*/

update 
    tb_cei_investors set username = '21490811800', password = 'S9fhb2g38xrc0bCO8moigA==';

/*
Script finalize asset data
*/
UPDATE
    tb_as_customer
SET
    nm_customer= 'CLIENTE ' || id_customer                ,
   -- cpf_cnpj=id_customer                                  ,
    email= 'cliente' || id_customer || '@valemobi.com.br' ,
    phone_business=id_customer*1000                       ,
    phone_home=id_customer*100                            ,
    phone_mobile=id_customer*10000;


END;
$body$ LANGUAGE plpgsql;
