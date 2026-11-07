-- =============================================================================
-- HUSORA · Test Onboarding (Migration 4800): Sitzung, Schritte, Übergänge, Neustart, Präferenzen, RLS
-- =============================================================================
\set QUIET on
begin;
create schema ob_test;
grant usage on schema ob_test to authenticated;
create table ob_test.vars (k text primary key, v text);
grant all on ob_test.vars to authenticated;
create function ob_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function ob_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'ONBOARDING-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function ob_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'ONBOARDING-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function ob_test.set(k text, v text) returns void language sql as $$ insert into ob_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function ob_test.get(k text) returns text language sql as $$ select v from ob_test.vars where vars.k = get.k $$;
grant execute on all functions in schema ob_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('owner@ob.test', 'Olle'), ('firma@ob.test', 'Frida'), ('fremd@ob.test', 'Fred')) v(e, f);
\set QUIET off

\echo '=== Hausbesitzer: Sitzung, Schritte, Übergänge ==='
select ob_test.login('owner@ob.test');
select ob_test.ok('ohne Sitzung: leerer Zustand', (public.onboarding_get('homeowner') -> 'session') = 'null'::jsonb);
select ob_test.set('s', public.onboarding_save('homeowner', 'homeowner_v1', 'welcome', 'completed', 'property', '{"usage":"rental"}')::text);
select ob_test.ok('Sitzung angelegt, aktueller Schritt „property“', (ob_test.get('s')::jsonb #>> '{session,current_step_key}') = 'property'
  and (ob_test.get('s')::jsonb #>> '{steps,welcome,status}') = 'completed');
select public.onboarding_save('homeowner', 'homeowner_v1', 'welcome', 'completed', 'property');
select ob_test.ok('doppelte Speicherung erzeugt keine zweite Sitzung', (select count(*) = 1 from onboarding_sessions));
select public.onboarding_save('homeowner', 'homeowner_v1', 'property', 'skipped', 'profile');
select public.onboarding_save('homeowner', 'homeowner_v1', 'property', 'completed', 'profile', '{"houses":1}', '{"primary_property_ref":"house-1"}');
select ob_test.ok('übersprungen → später erledigt', (select status = 'completed' from onboarding_step_progress where step_key = 'property'));
select public.onboarding_save('homeowner', 'homeowner_v1', 'property', 'skipped');
select ob_test.ok('erledigt bleibt erledigt', (select status = 'completed' from onboarding_step_progress where step_key = 'property'));
select ob_test.ok('Referenz auf das echte Haus gespeichert', (select primary_property_ref = 'house-1' from onboarding_sessions));
select public.onboarding_save('homeowner', 'homeowner_v1', 'task', 'completed', null, '{"title":"Das ist ein sehr langer Freitext, der niemals in den Metadaten landen darf, weil er Inhalte enthält","n":1,"Bad Key":2}');
select ob_test.ok('Metadaten: keine Freitexte / ungültigen Schlüssel', (select metadata = '{"n":1}'::jsonb from onboarding_step_progress where step_key = 'task'));
select ob_test.denied('unbekannter Schritt', $$ select public.onboarding_save('homeowner', 'homeowner_v1', 'hack', 'completed') $$);
select ob_test.denied('unbekannte Flow-Version', $$ select public.onboarding_save('homeowner', 'homeowner_v9', 'welcome', 'completed') $$);
select ob_test.denied('fremde Flow-Version zur Rolle', $$ select public.onboarding_save('homeowner', 'service_partner_v1', 'welcome', 'completed') $$);
select ob_test.denied('unbekannter Status', $$ select public.onboarding_save('homeowner', 'homeowner_v1', 'task', 'done') $$);
select ob_test.denied('Servicepartner-Flow ohne Betrieb', $$ select public.onboarding_get('service_partner') $$);
select ob_test.ok('Pausieren (Später fortsetzen)', (public.onboarding_save('homeowner', 'homeowner_v1', null, null, 'inspection', null, '{"paused":true}') #>> '{session,paused}') = 'true');
select ob_test.set('f', public.onboarding_finish('homeowner', 'homeowner_v1', 'completed')::text);
select ob_test.ok('abgeschlossen', (ob_test.get('f')::jsonb #>> '{session,status}') = 'completed' and (ob_test.get('f')::jsonb #>> '{steps,done,status}') = 'completed');
select public.onboarding_finish('homeowner', 'homeowner_v1', 'skipped');
select ob_test.ok('abgeschlossen bleibt abgeschlossen', (select status = 'completed' from onboarding_sessions));
select ob_test.set('r', public.onboarding_restart('homeowner', 'homeowner_v1')::text);
select ob_test.ok('Neustart: Schritte zurückgesetzt, Sitzung aktiv', (ob_test.get('r')::jsonb #>> '{session,status}') = 'in_progress' and (ob_test.get('r')::jsonb -> 'steps') = '{}'::jsonb);
select ob_test.ok('Feature-Guide ausblenden', (public.onboarding_preferences(null, null, 'tasks', true) -> 'dismissed_guides') ? 'tasks');
select ob_test.ok('Checkliste ausblenden + Hilfe-Tipps aus', (public.onboarding_preferences(true, false) ->> 'help_tips_enabled') = 'false');
select ob_test.ok('Guide wieder einblenden', not ((public.onboarding_preferences(null, null, 'tasks', false) -> 'dismissed_guides') ? 'tasks'));
select ob_test.denied('ungültiger Guide-Schlüssel', $$ select public.onboarding_preferences(null, null, 'Böse Taste', true) $$);
reset role;

\echo '=== Servicepartner ==='
select ob_test.login('firma@ob.test');
select ob_test.set('org', public.create_partner_organization('{"name":"Onboarding Service AB","email":"info@ob.test","services":["inspection"]}')::text);
select ob_test.set('p', public.onboarding_save('service_partner', 'service_partner_v1', 'profile', 'completed', 'area', null, jsonb_build_object('organization_id', ob_test.get('org')))::text);
select ob_test.ok('Partner-Sitzung mit Betrieb verknüpft', (ob_test.get('p')::jsonb #>> '{session,organization_id}') = ob_test.get('org'));
select ob_test.denied('Hausbesitzer-Schritt im Partner-Flow', $$ select public.onboarding_save('service_partner', 'service_partner_v1', 'property', 'completed') $$);
reset role;

\echo '=== Mandantentrennung ==='
select ob_test.login('fremd@ob.test');
select public.onboarding_save('service_partner', 'service_partner_v1', 'profile', 'completed', null, null, jsonb_build_object('organization_id', ob_test.get('org'))) from (select 1) x where false;
select ob_test.ok('Fremde sehen keine Sitzungen/Schritte/Präferenzen', (select count(*) from onboarding_sessions) = 0 and (select count(*) from onboarding_step_progress) = 0 and (select count(*) from user_onboarding_preferences) = 0);
select ob_test.denied('kein direktes Schreiben in Sitzungen', $$ insert into onboarding_sessions (user_id, role_key, flow_version) values ((select id from users limit 1), 'homeowner', 'homeowner_v1') $$);
select ob_test.denied('kein direktes Ändern fremder Schritte', $$ update onboarding_step_progress set status = 'completed' $$);
select ob_test.ok('fremde Organisation wird nicht verknüpft', (public.onboarding_save('homeowner', 'homeowner_v1', 'welcome', 'completed', null, null, jsonb_build_object('organization_id', ob_test.get('org'))) #>> '{session,organization_id}') is null);
reset role;
select ob_test.denied('anonym kein Zugriff', $$ set local role anon; select public.onboarding_get('homeowner') $$);
reset role;

\echo '=== Konto löschen entfernt Onboarding-Daten ==='
delete from public.users where id = (select pu.id from public.users pu join auth.users u on u.id = pu.auth_user_id where u.email = 'owner@ob.test');
select ob_test.ok('Sitzungen, Schritte und Präferenzen des gelöschten Nutzers entfernt',
  not exists (select 1 from onboarding_sessions s left join users u on u.id = s.user_id where u.id is null)
  and not exists (select 1 from user_onboarding_preferences p left join users u on u.id = p.user_id where u.id is null));

rollback;
\echo '=== Onboarding-Tests bestanden ==='
