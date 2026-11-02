-- =============================================================================
-- HUSORA · Test Mangel vom Partner → Anfrage → Reparaturauftrag
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/repair_offer_test.sql

\set QUIET on
begin;
create schema rp_test;
grant usage on schema rp_test to authenticated;
create table rp_test.vars (k text primary key, v text);
grant all on rp_test.vars to authenticated;

create function rp_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function rp_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'MANGEL-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function rp_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'MANGEL-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function rp_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function rp_test.set(k text, v text) returns void language sql as $$ insert into rp_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function rp_test.get(k text) returns text language sql as $$ select v from rp_test.vars where vars.k = get.k $$;
grant execute on all functions in schema rp_test to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@rp.test', 'Rita'), ('fremd@rp.test', 'Fynn')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: verbundener Partner mit Auftrag ==='
select rp_test.login('chef@rp.test');
select rp_test.set('org', public.create_partner_organization('{"name":"Mangel Service AB","email":"info@rp.test","services":["inspection"]}')::text);
reset role;
select rp_test.login('fremd@rp.test');
select public.create_partner_organization('{"name":"Fremd Mangel AB","services":["cleaning"]}');
reset role;
select rp_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Mangel Service AB', 'info@rp.test');
select rp_test.set('sp', (select id::text from service_partners where company_name = 'Mangel Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select rp_test.set('code', public.create_service_partner_invite(rp_test.get('sp')::uuid, 'info@rp.test'));
reset role;
select rp_test.login('chef@rp.test');
select public.accept_service_partner_invite(rp_test.get('code'));
reset role;
select rp_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'RP Hausservice');
select rp_test.set('order', public.offer_service_order((select id from service_tasks where title = 'RP Hausservice'), rp_test.get('sp')::uuid, 300)::text);
reset role;

\echo '=== Partner meldet Mangel und fragt die Beseitigung an ==='
select rp_test.login('fremd@rp.test');
select rp_test.denied('Fremde Firma kann keinen Mangel melden', $$ select public.partner_offer_repair('dddddddd-0000-4000-8000-000000000001', 'Test') $$);
reset role;
select rp_test.login('chef@rp.test');
select rp_test.denied('Ohne Beschreibung abgelehnt', $$ select public.partner_offer_repair('dddddddd-0000-4000-8000-000000000001', '  ') $$);
select rp_test.set('rep', public.partner_offer_repair('dddddddd-0000-4000-8000-000000000001', 'Dachrinne undicht', 'Rinne an der Nordseite tropft', 1200, null, rp_test.get('order')::uuid, 'high')::text);
select rp_test.ok('Partner sieht seine Meldung (gemeldet)', (select status from repairs where id = rp_test.get('rep')::uuid) = 'reported');
select rp_test.denied('Partner kann die Anfrage nicht selbst annehmen', format($$ select public.respond_repair_offer(%L, true) $$, rp_test.get('rep')));
reset role;
select rp_test.login('fremd@rp.test');
select rp_test.ok('Fremde Firma sieht die Meldung nicht', (select count(*) from repairs where id = rp_test.get('rep')::uuid) = 0);
reset role;

\echo '=== Hausbesitzer nimmt an → Auftrag beim Partner ==='
select rp_test.login('admin@husora.test');
select rp_test.ok('Hausbesitzer sieht die Anfrage mit Kosten', (select estimated_cost from repairs where id = rp_test.get('rep')::uuid) = 1200);
select rp_test.ok('Benachrichtigung an den Hausbesitzer', exists (select 1 from notifications where entity_id = rp_test.get('rep')::uuid and title like '%meldet einen Mangel%'));
select rp_test.set('rorder', (public.respond_repair_offer(rp_test.get('rep')::uuid, true, 'Bitte bis Freitag') ->> 'service_order_id'));
select rp_test.ok('Mangel in Bearbeitung (approved) mit Auftrag', (select status = 'approved' and service_order_id = rp_test.get('rorder')::uuid from repairs where id = rp_test.get('rep')::uuid));
select rp_test.ok('Auftrag: angenommen, Art Reparatur, Priorität übernommen', (select status || '/' || order_type || '/' || priority from service_orders where id = rp_test.get('rorder')::uuid) = 'accepted/repair/high');
select rp_test.denied('Zweite Antwort nicht möglich', format($$ select public.respond_repair_offer(%L, false) $$, rp_test.get('rep')));
reset role;

\echo '=== Partner beseitigt den Mangel über den Auftrag ==='
select rp_test.login('chef@rp.test');
select rp_test.ok('Partner sieht den neuen Auftrag', exists (select 1 from service_orders where id = rp_test.get('rorder')::uuid and title like 'Mangelbeseitigung:%'));
select rp_test.ok('Benachrichtigung an den Partner', exists (select 1 from notifications where entity_id = rp_test.get('rorder')::uuid and title like 'Mangelbeseitigung beauftragt%'));
update service_orders set scheduled_at = now() + interval '2 days', status = 'scheduled' where id = rp_test.get('rorder')::uuid;
select public.transition_service_order(rp_test.get('rorder')::uuid, 'in_progress');
select rp_test.ok('Mangel folgt: in Arbeit', (select status from repairs where id = rp_test.get('rep')::uuid) = 'in_progress');
update service_orders set status = 'completed', actual_cost = 1150 where id = rp_test.get('rorder')::uuid;
select rp_test.ok('Mangel behoben mit Ist-Kosten', (select status = 'completed' and actual_cost = 1150 and completed_at is not null from repairs where id = rp_test.get('rep')::uuid));
reset role;

\echo '=== Ablehnung ==='
select rp_test.login('chef@rp.test');
select rp_test.set('rep2', public.partner_offer_repair('dddddddd-0000-4000-8000-000000000001', 'Zaun schief', null, 300, null, rp_test.get('order')::uuid)::text);
reset role;
select rp_test.login('admin@husora.test');
select rp_test.ok('Ablehnen', (public.respond_repair_offer(rp_test.get('rep2')::uuid, false, 'Mache ich selbst') ->> 'status') = 'cancelled');
reset role;
select rp_test.login('chef@rp.test');
select rp_test.ok('Partner sieht Ablehnung mit Grund', (select status || '/' || response_note from repairs where id = rp_test.get('rep2')::uuid) = 'cancelled/Mache ich selbst');
reset role;

\echo '=== Alle Mangel-Tests bestanden ==='
rollback;
