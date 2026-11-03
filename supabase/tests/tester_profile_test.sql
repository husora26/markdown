-- HUSORA · Beta-Tester-Steckbrief (Migration 4600)
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tester_profile_test.sql
\set QUIET on
begin;
create schema tp_test;
grant usage on schema tp_test to authenticated, service_role;
create function tp_test.login(p_email text, p_aal text default 'aal1') returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email, 'aal', p_aal)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function tp_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'STECKBRIEF-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'PASS – %', p_label;
end $$;
create function tp_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'PASS – % (blockiert: %)', p_label, left(sqlerrm, 80); return; end;
  raise exception 'STECKBRIEF-TEST FEHLGESCHLAGEN – % (wurde NICHT blockiert)', p_label;
end $$;
grant execute on all functions in schema tp_test to authenticated, service_role;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(), '{"provider":"email"}', now(), now()
from (values ('tp_a@tp.test'), ('tp_b@tp.test'), ('tp_c@tp.test'), ('tp_d@tp.test'), ('tp_admin@tp.test')) v(e);
update users set is_super_admin = true where email = 'tp_admin@tp.test';
\set QUIET off

select tp_test.login('tp_a@tp.test');
select tp_test.ok('Vorher: profile_done = false', not (public.my_beta_status() ->> 'profile_done')::boolean);
select tp_test.ok('Steckbrief speichern', (public.save_tester_profile('{"role":"owner","house_count":"2-3","region":" värmland ","current_tool":"excel","source":"friend","interview_ok":true}') ->> 'ok')::boolean);
select tp_test.ok('Danach: profile_done = true', (public.my_beta_status() ->> 'profile_done')::boolean);
select tp_test.ok('Ungültige Werte werden verworfen', (public.save_tester_profile('{"role":"owner","house_count":"999","current_tool":"<script>","region":"Värmland","source":"search"}') ->> 'ok')::boolean);
select tp_test.ok('… gespeichert ohne ungültige Werte', (select house_count is null and current_tool is null and source = 'search' from tester_profiles));
select tp_test.ok('Nutzer sieht nur die eigene Zeile', (select count(*) from tester_profiles) = 1);
select tp_test.denied('Direktes Schreiben gesperrt (nur RPC)', $$ insert into public.tester_profiles (user_id) values ((select id from users limit 1)) $$);
reset role;
select tp_test.login('tp_b@tp.test');
select tp_test.ok('B sieht A nicht', (select count(*) from tester_profiles) = 0);
select tp_test.ok('Überspringen wird gespeichert', (public.save_tester_profile(null, true) ->> 'skipped')::boolean);
select tp_test.ok('… und zählt als erledigt', (public.my_beta_status() ->> 'profile_done')::boolean);
reset role;
select tp_test.login('tp_c@tp.test');
select public.save_tester_profile('{"role":"partner","team_size":"2-5","region":"Värmland","current_tool":"paper"}');
reset role;
select tp_test.login('tp_d@tp.test');
select public.save_tester_profile('{"role":"both","house_count":"1","region":"VÄRMLAND","current_tool":"excel"}');
select tp_test.denied('Normaler Nutzer: keine Auswertung', $$ select public.beta_tester_profiles_summary() $$);
reset role;
select tp_test.login('tp_admin@tp.test', 'aal1');
select tp_test.denied('Admin ohne MFA: keine Auswertung', $$ select public.beta_tester_profiles_summary() $$);
reset role;
select tp_test.login('tp_admin@tp.test', 'aal2');
select tp_test.ok('Auswertung zusammengefasst (beantwortet, übersprungen, Werkzeug, Region ab 3 Nennungen)',
  (select (s ->> 'answered')::int = 3 and (s ->> 'skipped')::int = 1 and (s -> 'current_tool' ->> 'excel')::int = 1 and (s -> 'region' ->> 'Värmland')::int = 3
   from (select public.beta_tester_profiles_summary() s) x));
select tp_test.ok('Auswertung enthält keine E-Mail-Adressen', public.beta_tester_profiles_summary()::text !~ '@tp\.test');
reset role;
select tp_test.login('tp_a@tp.test');
select tp_test.ok('Datenexport enthält den Steckbrief', (public.export_my_data() -> 'tester_profile' ->> 'role') = 'owner');
reset role;
delete from public.users where email = 'tp_a@tp.test';
select tp_test.ok('Kontolöschung entfernt den Steckbrief', (select count(*) from tester_profiles t left join users u on u.id = t.user_id where u.id is null) = 0);

\echo 'Steckbrief-Tests: alle Prüfungen bestanden.'
rollback;
