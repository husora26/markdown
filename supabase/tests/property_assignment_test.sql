-- =============================================================================
-- HUSORA · Test Objektfreigabe und Rolle Subunternehmer (Phase 3)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/property_assignment_test.sql

\set QUIET on
begin;
create schema pa_test;
grant usage on schema pa_test to authenticated;
create table pa_test.vars (k text primary key, v text);
grant all on pa_test.vars to authenticated;
create function pa_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pa_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'FREIGABE-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function pa_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'FREIGABE-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function pa_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function pa_test.set(k text, v text) returns void language sql as $$ insert into pa_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function pa_test.get(k text) returns text language sql as $$ select v from pa_test.vars where vars.k = get.k $$;
-- Sicht des angemeldeten Nutzers auf Haus 1 des Testkunden: Häuser|Fotos|Dokumente|Kontrollen
create function pa_test.view() returns text language sql as $$
  select concat_ws('|',
    (select count(*) from public.properties where organization_id = 'cccccccc-0000-4000-8000-000000000001'),
    (select count(*) from public.photos where property_id = 'dddddddd-0000-4000-8000-000000000001' and caption = 'PA-Test'),
    coalesce((select string_agg(document_type, ',' order by document_type) from public.documents where property_id = 'dddddddd-0000-4000-8000-000000000001' and description = 'PA-Test'), ''),
    (select count(*) from public.inspections where property_id = 'dddddddd-0000-4000-8000-000000000001' and notes = 'PA-Test'))
$$;
grant execute on all functions in schema pa_test to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@pa.test', 'Paula'), ('sub@pa.test', 'Sven'), ('fremd@pa.test', 'Fred')) v(e, f);

-- Testdaten am Haus 1 (als Systemnutzer)
insert into public.photos (organization_id, property_id, storage_bucket, storage_path, caption)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'husora-property-photos',
        'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/photos/pa.jpg', 'PA-Test');
insert into public.documents (organization_id, property_id, file_name, file_type, file_size, storage_bucket, storage_path, document_type, description)
select 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'pa-' || t || '.pdf', 'application/pdf', 100, 'husora-documents',
       'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/documents/pa-' || t || '.pdf', t, 'PA-Test'
from unnest(array['manual', 'insurance', 'invoice']) t;
insert into public.inspections (organization_id, property_id, status, scheduled_at, notes)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'scheduled', now() + interval '5 days', 'PA-Test');
\set QUIET off

\echo '=== Vorbereitung: Partnerbetrieb, Subunternehmer, Verbindung ==='
select pa_test.login('chef@pa.test');
select pa_test.set('org', public.create_partner_organization('{"name":"Freigabe Service AB","email":"info@pa.test","services":["inspection"]}')::text);
select pa_test.set('team', public.create_member_invite(pa_test.get('org')::uuid, 'sub@pa.test', 'contractor'));
reset role;
select pa_test.login('sub@pa.test');
select pa_test.ok('Subunternehmer tritt bei (Rolle contractor)', (public.accept_member_invite(pa_test.get('team')) ->> 'role') = 'contractor');
reset role;
select pa_test.login('fremd@pa.test');
select public.create_partner_organization('{"name":"Fremd Freigabe AB","services":["cleaning"]}');
reset role;
select pa_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Freigabe Service AB', 'info@pa.test');
select pa_test.set('sp', (select id::text from service_partners where company_name = 'Freigabe Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select pa_test.set('code', public.create_service_partner_invite(pa_test.get('sp')::uuid, 'info@pa.test'));
reset role;
select pa_test.login('chef@pa.test');
select public.accept_service_partner_invite(pa_test.get('code'));
select pa_test.ok('Ohne Freigabe und Auftrag: kein Haus sichtbar', pa_test.view() = '0|0||0');
select pa_test.denied('Partner kann sich nicht selbst Häuser freigeben', format($$ insert into property_service_assignments (property_id, service_partner_id, access_level) values ('dddddddd-0000-4000-8000-000000000001', %L, 'full') $$, pa_test.get('sp')));
reset role;

\echo '=== Stufe basic: nur Stammdaten ==='
select pa_test.set('foreign_sp', (select id::text from service_partners where organization_id = pa_test.get('org')::uuid limit 1));
select pa_test.login('admin@husora.test');
insert into property_service_assignments (property_id, service_partner_id, access_level) values ('dddddddd-0000-4000-8000-000000000001', pa_test.get('sp')::uuid, 'basic');
select pa_test.ok('organization_id kommt vom Haus', (select organization_id from property_service_assignments where service_partner_id = pa_test.get('sp')::uuid) = 'cccccccc-0000-4000-8000-000000000001');
select pa_test.denied('Haus nur für Partner der eigenen Organisation', format($$ insert into property_service_assignments (property_id, service_partner_id) values ('dddddddd-0000-4000-8000-000000000001', %L) $$, pa_test.get('foreign_sp')));
reset role;
select pa_test.login('chef@pa.test');
select pa_test.ok('basic: genau 1 Haus, keine Fotos/Dokumente/Kontrollen (' || pa_test.view() || ')', pa_test.view() = '1|0||0');
select pa_test.ok('Partner sieht seine Freigabe', (select access_level from property_service_assignments) = 'basic');
select pa_test.ok('Partner kann die Stufe nicht ändern', pa_test.affected($$ update property_service_assignments set access_level = 'full' $$) = 0);
reset role;

\echo '=== Stufe service: Fotos und technische Unterlagen ==='
select pa_test.login('admin@husora.test');
update property_service_assignments set access_level = 'service' where service_partner_id = pa_test.get('sp')::uuid;
reset role;
select pa_test.login('chef@pa.test');
select pa_test.ok('service: Foto + Anleitung, keine Versicherung/Rechnung (' || pa_test.view() || ')', pa_test.view() = '1|1|manual|0');
reset role;

\echo '=== Stufe full: alle Unterlagen außer Rechnungen, Kontrollen ==='
select pa_test.login('admin@husora.test');
update property_service_assignments set access_level = 'full' where service_partner_id = pa_test.get('sp')::uuid;
reset role;
select pa_test.login('chef@pa.test');
select pa_test.ok('full: Versicherung + Anleitung + Kontrolle, keine Rechnung (' || pa_test.view() || ')', pa_test.view() = '1|1|insurance,manual|1');
reset role;

\echo '=== Subunternehmer und fremde Firma ==='
select pa_test.login('sub@pa.test');
select pa_test.ok('Subunternehmer sieht freigegebene Häuser nicht (nur eigene Aufträge)', pa_test.view() = '0|0||0');
reset role;
select pa_test.login('fremd@pa.test');
select pa_test.ok('Fremde Firma sieht nichts', pa_test.view() = '0|0||0' and (select count(*) from property_service_assignments) = 0);
reset role;

\echo '=== Zeitraum und Trennen ==='
select pa_test.login('admin@husora.test');
update property_service_assignments set start_date = current_date - 30, end_date = current_date - 1 where service_partner_id = pa_test.get('sp')::uuid;
reset role;
select pa_test.login('chef@pa.test');
select pa_test.ok('Abgelaufene Freigabe gibt nichts mehr frei', pa_test.view() = '0|0||0');
reset role;
select pa_test.login('admin@husora.test');
update property_service_assignments set end_date = null where service_partner_id = pa_test.get('sp')::uuid;
select public.disconnect_service_partner(pa_test.get('sp')::uuid, 'Test');
select pa_test.ok('Trennen beendet die Freigabe', (select status from property_service_assignments where service_partner_id = pa_test.get('sp')::uuid) = 'ended');
reset role;
select pa_test.login('chef@pa.test');
select pa_test.ok('Nach dem Trennen: nichts sichtbar', pa_test.view() = '0|0||0');
reset role;

\echo '=== Alle Freigabe-Tests bestanden ==='
rollback;
