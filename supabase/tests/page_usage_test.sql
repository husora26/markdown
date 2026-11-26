-- =============================================================================
-- HUSORA · Test Seiten-Nutzung (page_opened, page_usage)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/page_usage_test.sql

\set QUIET on
begin;
create schema pu_test;
grant usage on schema pu_test to authenticated, anon;
create function pu_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email, 'aal', 'aal2')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pu_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'SEITEN-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function pu_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'SEITEN-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
grant execute on all functions in schema pu_test to authenticated, anon;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('a@pu.test', 'Anna'), ('admin@pu.test', 'Ada')) v(e, f);
update users set is_super_admin = true where email = 'admin@pu.test';
\set QUIET off

\echo '=== Seitenaufrufe werden mit Einwilligung gezählt ==='
select pu_test.login('a@pu.test');
insert into consent_log (purpose, version, accepted, source) values ('analytics', '2026-11-02', true, 'test');
select pu_test.ok('page_opened mit Seite wird gespeichert', public.track_events($$[
  {"event_name":"page_opened","entity_type":"page","entity_ref":"tasks:2026-11-26","metadata":{"page":"tasks"}},
  {"event_name":"page_opened","entity_type":"page","entity_ref":"costs:2026-11-26","metadata":{"page":"costs"}}]$$::jsonb) = 2);
select pu_test.ok('Gleiche Seite am gleichen Tag zählt nur einmal', public.track_events('[{"event_name":"page_opened","entity_type":"page","entity_ref":"tasks:2026-11-26","metadata":{"page":"tasks"}}]') = 0);
select pu_test.denied('Normale Nutzer sehen die Auswertung nicht', 'select public.page_usage(30)');
reset role;

\echo '=== Auswertung für das Husora-Team ==='
select pu_test.login('admin@pu.test');
select pu_test.ok('Aufgaben-Seite mit 1 Nutzer', (select (x ->> 'users')::int = 1 from jsonb_array_elements(public.page_usage(30)) x where x ->> 'page' = 'tasks'));
reset role;

\echo '=== Alle Seiten-Tests bestanden ==='
rollback;
