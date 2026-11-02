-- =============================================================================
-- HUSORA · Test Phase 11: Bewertungen, Kostenvergleich, Notdienst
-- =============================================================================
\set QUIET on
begin;
create schema rq_test;
grant usage on schema rq_test to authenticated;
create table rq_test.vars (k text primary key, v text);
grant all on rq_test.vars to authenticated;
create function rq_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function rq_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'PHASE11-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function rq_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'PHASE11-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function rq_test.set(k text, v text) returns void language sql as $$ insert into rq_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function rq_test.get(k text) returns text language sql as $$ select v from rq_test.vars where vars.k = get.k $$;
grant execute on all functions in schema rq_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@rq.test', 'Nora'), ('fremd@rq.test', 'Fynn')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: verbundener Partner mit Auftrag ==='
select rq_test.login('chef@rq.test');
select rq_test.set('org', public.create_partner_organization('{"name":"Review Service AB","email":"info@rq.test","services":["inspection"]}')::text);
reset role;
select rq_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Review Service AB', 'info@rq.test');
select rq_test.set('sp', (select id::text from service_partners where company_name = 'Review Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select rq_test.set('code', public.create_service_partner_invite(rq_test.get('sp')::uuid, 'info@rq.test'));
reset role;
select rq_test.login('chef@rq.test');
select public.accept_service_partner_invite(rq_test.get('code'));
reset role;
select rq_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'RQ Hausservice');
select rq_test.set('order', public.offer_service_order((select id from service_tasks where title = 'RQ Hausservice'), rq_test.get('sp')::uuid, 100)::text);
reset role;

\echo '=== Bewertung nur nach Abschluss, nur durch den Auftraggeber ==='
select rq_test.login('admin@husora.test');
select rq_test.denied('Vor Abschluss nicht bewertbar', format($$ insert into service_partner_reviews (service_order_id, rating, organization_id, service_partner_id) values (%L, 5, 'cccccccc-0000-4000-8000-000000000001', %L) $$, rq_test.get('order'), rq_test.get('sp')));
reset role;
update service_orders set status = 'accepted' where id = rq_test.get('order')::uuid;
update service_orders set status = 'completed' where id = rq_test.get('order')::uuid;
select rq_test.login('chef@rq.test');
select rq_test.denied('Partner kann sich nicht selbst bewerten', format($$ insert into service_partner_reviews (service_order_id, rating, organization_id, service_partner_id) values (%L, 5, 'cccccccc-0000-4000-8000-000000000001', %L) $$, rq_test.get('order'), rq_test.get('sp')));
reset role;
select rq_test.login('admin@husora.test');
insert into service_partner_reviews (service_order_id, rating, comment, organization_id, service_partner_id) values (rq_test.get('order')::uuid, 4, 'Pünktlich und sauber', 'cccccccc-0000-4000-8000-000000000001', rq_test.get('sp')::uuid);
select rq_test.denied('Nur eine Bewertung je Auftrag', format($$ insert into service_partner_reviews (service_order_id, rating, organization_id, service_partner_id) values (%L, 1, 'cccccccc-0000-4000-8000-000000000001', %L) $$, rq_test.get('order'), rq_test.get('sp')));
select rq_test.ok('Durchschnitt an der Verbindung', (select rating from service_partners where id = rq_test.get('sp')::uuid) = 4);
select rq_test.denied('Hausbesitzer kann keine Partner-Antwort schreiben', $$ update service_partner_reviews set partner_reply = 'gefälscht' $$);
reset role;
select rq_test.ok('Durchschnitt am Partnerbetrieb', (select rating_avg = 4 and rating_count = 1 from organizations where id = rq_test.get('org')::uuid));
select rq_test.login('chef@rq.test');
select rq_test.ok('Partner sieht die Bewertung und wird benachrichtigt', exists (select 1 from service_partner_reviews where comment = 'Pünktlich und sauber') and exists (select 1 from notifications where title like 'Neue Bewertung:%'));
select public.reply_review((select id from service_partner_reviews where comment = 'Pünktlich und sauber'), 'Danke!');
select rq_test.ok('Partner antwortet', (select partner_reply = 'Danke!' and replied_at is not null from service_partner_reviews where comment = 'Pünktlich und sauber'));
reset role;
select rq_test.login('fremd@rq.test');
select rq_test.ok('Fremde sehen die Bewertung nicht', (select count(*) from service_partner_reviews where comment = 'Pünktlich und sauber') = 0);
select rq_test.denied('Fremde können nicht antworten', $$ select public.reply_review((select id from service_partner_reviews limit 1), 'x') $$);
reset role;

\echo '=== Kostenvergleich: zwei Angebote für dieselbe Aufgabe ==='
select rq_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'RQ Zweiter AB', 'zwei@rq.test');
select rq_test.set('sp2', (select id::text from service_partners where company_name = 'RQ Zweiter AB'));
select rq_test.set('code2', public.create_service_partner_invite(rq_test.get('sp2')::uuid, 'zwei@rq.test'));
reset role;
select rq_test.login('fremd@rq.test');
select public.create_partner_organization('{"name":"RQ Zweiter AB","services":["inspection"]}');
select public.accept_service_partner_invite(rq_test.get('code2'));
reset role;
select rq_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'RQ Dach prüfen');
select rq_test.set('o1', public.offer_service_order((select id from service_tasks where title = 'RQ Dach prüfen'), rq_test.get('sp')::uuid)::text);
select rq_test.set('o2', public.offer_service_order((select id from service_tasks where title = 'RQ Dach prüfen'), rq_test.get('sp2')::uuid)::text);
reset role;
select rq_test.login('chef@rq.test');
insert into quotes (organization_id, property_id, service_order_id, service_partner_id, quote_number, amount_net, tax_amount, amount_gross, currency, status)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', rq_test.get('o1')::uuid, rq_test.get('sp')::uuid, 'RQ-A1', 800, 200, 1000, 'SEK', 'received');
reset role;
select rq_test.login('fremd@rq.test');
insert into quotes (organization_id, property_id, service_order_id, service_partner_id, quote_number, amount_net, tax_amount, amount_gross, currency, status)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', rq_test.get('o2')::uuid, rq_test.get('sp2')::uuid, 'RQ-B1', 640, 160, 800, 'SEK', 'received');
select rq_test.denied('Partner kann eigenes Angebot nicht annehmen', $$ select public.respond_quote((select id from quotes where quote_number = 'RQ-B1'), true) $$);
reset role;
select rq_test.login('admin@husora.test');
select rq_test.ok('Hausbesitzer sieht beide Angebote', (select count(*) from quotes where quote_number in ('RQ-A1', 'RQ-B1')) = 2);
select rq_test.ok('Günstigeres Angebot annehmen', (public.respond_quote((select id from quotes where quote_number = 'RQ-B1'), true) ->> 'others_rejected')::int = 1);
select rq_test.ok('Anderes Angebot abgelehnt, Anfrage dort zurückgezogen', (select q.status || '/' || o.status from quotes q join service_orders o on o.id = q.service_order_id where q.quote_number = 'RQ-A1') = 'rejected/cancelled');
select rq_test.ok('Betrag übernommen', (select estimated_cost from service_orders where id = rq_test.get('o2')::uuid) = 800);
select rq_test.denied('Zweite Entscheidung nicht möglich', $$ select public.respond_quote((select id from quotes where quote_number = 'RQ-B1'), false) $$);
reset role;

\echo '=== Notdienst ==='
update organizations set emergency_service = false where emergency_service;  -- sauberer Ausgangszustand (wird zurückgerollt)
select rq_test.login('admin@husora.test');
select rq_test.denied('Ohne Partner mit Notdienst: klare Meldung', $$ select public.request_emergency('dddddddd-0000-4000-8000-000000000001', 'Wasserrohrbruch') $$);
reset role;
update organizations set emergency_service = true where id = rq_test.get('org')::uuid;
select rq_test.login('admin@husora.test');
select rq_test.set('em', (public.request_emergency('dddddddd-0000-4000-8000-000000000001', 'Wasserrohrbruch', 'Küche steht unter Wasser') ->> 'service_order_id'));
select rq_test.ok('Notfall an den Partner mit Notdienst', (select priority || '/' || order_type || '/' || status || '/' || (service_partner_id = rq_test.get('sp')::uuid) from service_orders where id = rq_test.get('em')::uuid) = 'emergency/emergency/offered/true');
select rq_test.ok('Partnerangaben für die Auswahl (Notdienst, Bewertung)', (select emergency_service and rating_avg = 4 from public.partner_directory_facts() where service_partner_id = rq_test.get('sp')::uuid));
select rq_test.denied('Ausgeschlossener Partner → kein weiterer Notdienst', format($$ select public.request_emergency('dddddddd-0000-4000-8000-000000000001', 'x', null, array[%L]::uuid[]) $$, rq_test.get('sp')));
reset role;
select rq_test.login('chef@rq.test');
select rq_test.ok('Partner sofort benachrichtigt', exists (select 1 from notifications where title = 'NOTFALL: Wasserrohrbruch'));
reset role;
select rq_test.login('fremd@rq.test');
select rq_test.denied('Fremde können keinen Notfall für das Haus auslösen', $$ select public.request_emergency('dddddddd-0000-4000-8000-000000000001', 'x') $$);
reset role;

\echo '=== Alle Phase-11-Tests bestanden ==='
rollback;
