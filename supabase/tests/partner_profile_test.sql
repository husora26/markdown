-- =============================================================================
-- HUSORA · Test Profil, Abwesenheiten, automatische Annahme (Phase 4)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_profile_test.sql

\set QUIET on
begin;
create schema pf_test;
grant usage on schema pf_test to authenticated;
create table pf_test.vars (k text primary key, v text);
grant all on pf_test.vars to authenticated;

create function pf_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pf_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'PROFIL-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function pf_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'PROFIL-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function pf_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function pf_test.set(k text, v text) returns void language sql as $$ insert into pf_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function pf_test.get(k text) returns text language sql as $$ select v from pf_test.vars where vars.k = get.k $$;
grant execute on all functions in schema pf_test to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@pf.test', 'Petra'), ('tech@pf.test', 'Tim'), ('fremd@pf.test', 'Frida')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung ==='
select pf_test.login('chef@pf.test');
select pf_test.set('org', public.create_partner_organization('{"name":"Profil Service AB","email":"info@pf.test","services":["inspection"]}')::text);
select pf_test.set('team', public.create_member_invite(pf_test.get('org')::uuid, 'tech@pf.test', 'technician'));
reset role;
select pf_test.login('tech@pf.test');
select public.accept_member_invite(pf_test.get('team'));
reset role;
select pf_test.login('fremd@pf.test');
select public.create_partner_organization('{"name":"Fremd Profil AB","services":["cleaning"]}');
reset role;
select pf_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Profil Service AB', 'info@pf.test');
select pf_test.set('sp', (select id::text from service_partners where company_name = 'Profil Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select pf_test.set('code', public.create_service_partner_invite(pf_test.get('sp')::uuid, 'info@pf.test'));
reset role;
select pf_test.login('chef@pf.test');
select public.accept_service_partner_invite(pf_test.get('code'));

\echo '=== Profil und Preisart ==='
select pf_test.ok('Profilfelder speichern', pf_test.affected(format($$ update organizations set emergency_service = true, hourly_rate = 650, travel_fee = 150, minimum_order_value = 300 where id = %L $$, pf_test.get('org'))) = 1);
select pf_test.denied('Negativer Stundensatz abgelehnt', format($$ update organizations set hourly_rate = -1 where id = %L $$, pf_test.get('org')));
select pf_test.ok('Preisart Standard vorbelegt', (select bool_and(price_type in ('fixed', 'quote', 'hourly')) from service_partner_services where service_partner_id = (public.partner_context() ->> 'self_partner_id')::uuid));
select pf_test.denied('Unbekannte Preisart abgelehnt', $$ update service_partner_services set price_type = 'gratis' $$);
select pf_test.ok('Servicegebiet mit PLZ-Bereich', pf_test.affected(format($$ insert into service_partner_areas (service_partner_id, name, postal_code_prefix, country) values (%L, 'Värmland Nord', '686', 'SE') $$, public.partner_context() ->> 'self_partner_id')) = 1);
reset role;

\echo '=== Abwesenheiten ==='
select pf_test.login('tech@pf.test');
select pf_test.ok('Mitarbeiter trägt eigene Abwesenheit ein', pf_test.affected(format($$ insert into service_partner_absences (organization_id, user_id, start_at, end_at, reason) values (%L, (select id from users where email = 'tech@pf.test'), now(), now() + interval '2 days', 'Urlaub') $$, pf_test.get('org'))) = 1);
select pf_test.denied('Mitarbeiter kann keine Betriebsabwesenheit eintragen', format($$ insert into service_partner_absences (organization_id, start_at, end_at) values (%L, now(), now() + interval '1 day') $$, pf_test.get('org')));
reset role;
select pf_test.set('admin_uid', (select id::text from users where email = 'admin@husora.test'));
select pf_test.login('chef@pf.test');
select pf_test.denied('Nur Personen des Betriebs', format($$ insert into service_partner_absences (organization_id, user_id, start_at, end_at) values (%L, %L, now(), now() + interval '1 day') $$, pf_test.get('org'), pf_test.get('admin_uid')));
select pf_test.denied('Ende vor Beginn abgelehnt', format($$ insert into service_partner_absences (organization_id, start_at, end_at) values (%L, now(), now() - interval '1 day') $$, pf_test.get('org')));
select pf_test.ok('Leitung sieht alle Abwesenheiten', (select count(*) from service_partner_absences) = 1);
reset role;
select pf_test.login('fremd@pf.test');
select pf_test.ok('Fremde Firma sieht keine Abwesenheiten', (select count(*) from service_partner_absences) = 0);
reset role;
select pf_test.login('admin@husora.test');
select pf_test.ok('Hausbesitzer sieht keine Abwesenheiten des Partners', (select count(*) from service_partner_absences) = 0);
reset role;

\echo '=== Automatische Annahme ==='
select pf_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'PF Auftrag 1');
select pf_test.set('o1', public.offer_service_order((select id from service_tasks where title = 'PF Auftrag 1'), pf_test.get('sp')::uuid, 500)::text);
select pf_test.ok('Ohne Einstellung bleibt die Anfrage offen', (select status from service_orders where id = pf_test.get('o1')::uuid) = 'offered');
reset role;
select pf_test.login('chef@pf.test');
update organizations set auto_accept_orders = true where id = pf_test.get('org')::uuid;
reset role;
select pf_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'PF Auftrag 2'), ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'PF Auftrag 3');
select pf_test.set('o2', public.offer_service_order((select id from service_tasks where title = 'PF Auftrag 2'), pf_test.get('sp')::uuid, 500)::text);
select pf_test.ok('Automatisch angenommen', (select status = 'accepted' and response_note = 'Automatisch angenommen' from service_orders where id = pf_test.get('o2')::uuid));
select pf_test.ok('Protokoll: erst angelegt, dann angenommen', (select string_agg(event_type || ':' || coalesce(new_status, ''), ',' order by created_at, case event_type when 'created' then 0 else 1 end) from service_order_events where service_order_id = pf_test.get('o2')::uuid) = 'created:offered,status_changed:accepted');
select pf_test.set('o3', public.offer_service_order((select id from service_tasks where title = 'PF Auftrag 3'), pf_test.get('sp')::uuid, 100)::text);
select pf_test.ok('Unter Mindestauftragswert bleibt offen', (select status from service_orders where id = pf_test.get('o3')::uuid) = 'offered');
reset role;
select pf_test.login('chef@pf.test');
insert into service_partner_absences (organization_id, start_at, end_at, reason) values (pf_test.get('org')::uuid, now() - interval '1 hour', now() + interval '3 days', 'Betriebsferien');
reset role;
select pf_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'PF Auftrag 4');
select pf_test.set('o4', public.offer_service_order((select id from service_tasks where title = 'PF Auftrag 4'), pf_test.get('sp')::uuid, 900)::text);
select pf_test.ok('Bei Betriebsabwesenheit keine automatische Annahme', (select status from service_orders where id = pf_test.get('o4')::uuid) = 'offered');
reset role;

\echo '=== Alle Profil-Tests bestanden ==='
rollback;
