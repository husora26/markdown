-- =============================================================================
-- HUSORA · Test Beta Mode (Analytics, Feedback, Bewertungen, Beta-Status, Dashboard)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/beta_mode_test.sql

\set QUIET on
begin;
create schema bt_test;
grant usage on schema bt_test to authenticated, anon;
create function bt_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email, 'aal', 'aal2')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function bt_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'BETA-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function bt_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'BETA-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function bt_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
grant execute on all functions in schema bt_test to authenticated, anon;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('a@bt.test', 'Anna'), ('b@bt.test', 'Ben')) v(e, f);
\set QUIET off

\echo '=== Registrierung wird serverseitig gezählt ==='
select bt_test.ok('user_registered ohne Einwilligung nur anonym gezählt', (select count(*) from analytics_events e where e.event_name = 'user_registered' and e.user_id is null and e.created_at >= now() - interval '1 minute') >= 2);

\echo '=== Konfiguration ==='
select bt_test.login('a@bt.test');
select bt_test.ok('Beta-Konfiguration lesbar', (select (value ->> 'enabled')::boolean from app_config where key = 'beta'));
select bt_test.ok('Normale Nutzer können Beta nicht abschalten', bt_test.affected($$ update app_config set value = '{"enabled": false}' where key = 'beta' $$) = 0);
reset role;

\echo '=== Analytics: nur eigene, erlaubte, datensparsame Ereignisse ==='
select bt_test.login('a@bt.test');
insert into consent_log (purpose, version, accepted, source) values ('analytics', '2026-11-02', true, 'test');
select bt_test.ok('Stapel gespeichert (2 gültig, 1 unbekannt verworfen)', public.track_events($$[
  {"event_name":"house_created","entity_type":"house","entity_ref":"p1","app_role":"owner","metadata":{"count":1,"password":"x","owner_name":"Anna","nested":{"a":1}}},
  {"event_name":"task_created","entity_type":"task","entity_ref":"t1"},
  {"event_name":"drop_table","entity_ref":"x"}]$$::jsonb) = 2);
select bt_test.ok('Doppeltes Ereignis wird nicht erneut gezählt', public.track_events('[{"event_name":"house_created","entity_type":"house","entity_ref":"p1"}]') = 0);
select bt_test.ok('Server-Ereignisse kann der Client nicht vortäuschen', public.track_events('[{"event_name":"service_completed","entity_ref":"x"},{"event_name":"user_registered","entity_ref":"y"}]') = 0);
select bt_test.ok('Fremde Organisation wird nicht übernommen', public.track_events('[{"event_name":"task_completed","entity_ref":"t1"}]', 'cccccccc-0000-4000-8000-000000000001') = 1);
select bt_test.ok('Analytics für Nutzer nicht lesbar', (select count(*) from analytics_events) = 0);
select bt_test.denied('Direktes Schreiben in analytics_events verboten', $$ insert into analytics_events (event_name) values ('house_created') $$);
select bt_test.ok('Beta-Status nicht selbst änderbar', bt_test.affected($$ update users set beta_group = 'alpha', is_beta_user = false where email = 'a@bt.test' $$) = 1);
reset role;
select bt_test.ok('Metadaten ohne Passwort/Name/verschachtelt', (select metadata from analytics_events e join users u on u.id = e.user_id where u.email = 'a@bt.test' and event_name = 'house_created') = '{"count": 1}'::jsonb);
select bt_test.ok('Organisation leer statt fremd', (select organization_id is null from analytics_events e join users u on u.id = e.user_id where u.email = 'a@bt.test' and event_name = 'task_completed'));
select bt_test.ok('Beta-Nutzer markiert (Gruppe aus Konfiguration, unverändert)', (select is_beta_user and beta_group = 'closed_beta' and beta_started_at is not null from users where email = 'a@bt.test'));
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select bt_test.denied('Ohne Anmeldung kein Tracking', $$ select public.track_events('[{"event_name":"house_created"}]') $$);
reset role;

\echo '=== Feedback und Fehlerberichte ==='
select bt_test.login('a@bt.test');
insert into app_feedback (kind, feedback_type, message, page, app_role, organization_id, auth_user_id)
values ('feedback', 'idea', 'Kalender-Export wäre toll', 'calendar', 'owner', 'cccccccc-0000-4000-8000-000000000001', gen_random_uuid());
insert into app_feedback (kind, title, message, expected_behavior, actual_behavior, page, severity, status)
values ('bug', 'Speichern hängt', 'Beim Speichern dreht sich das Rad', 'Gespeichert', 'Nichts passiert', 'tasks', 'high', 'resolved');
select bt_test.ok('Eigene Meldungen sichtbar (Nutzer/Organisation aus der Sitzung, Status offen)',
  (select count(*) = 2 and bool_and(user_id is not null and organization_id is null and status = 'open') from app_feedback where auth_user_id = auth.uid()));
select bt_test.ok('Sicht beta_bug_reports', (select severity = 'high' and expected_behavior = 'Gespeichert' from beta_bug_reports where title = 'Speichern hängt'));
select bt_test.ok('Nutzer kann Status nicht ändern', bt_test.affected($$ update app_feedback set status = 'resolved' $$) = 0);
reset role;
select bt_test.login('b@bt.test');
select bt_test.ok('Andere Nutzer sehen fremdes Feedback nicht', (select count(*) from app_feedback) = 0 and (select count(*) from beta_feedback) = 0);
reset role;
select bt_test.ok('feedback_created/bug_report_created gezählt', (select count(*) from analytics_events e join users u on u.id = e.user_id where u.email = 'a@bt.test' and event_name in ('feedback_created', 'bug_report_created')) = 2);

\echo '=== Bewertungen und Umfragen ==='
select bt_test.login('a@bt.test');
insert into beta_ratings (rating, context, comment, organization_id) values (5, 'inspection', 'Sehr übersichtlich', 'cccccccc-0000-4000-8000-000000000001');
insert into beta_ratings (rating, context, answers) values (4, 'day7', '{"most_used":"tasks","missing":"Export"}');
select bt_test.denied('7-Tage-Umfrage nur einmal', $$ insert into beta_ratings (rating, context) values (3, 'day7') $$);
select bt_test.denied('Bewertung außerhalb 1–5', $$ insert into beta_ratings (rating, context) values (7, 'service') $$);
insert into beta_ratings (context, answers) values ('day30', '{"continue":"yes","value":"4.99"}');
select bt_test.ok('Eigene Bewertungen sichtbar, Organisation nicht fremd', (select count(*) = 3 and bool_and(organization_id is null) from beta_ratings));
reset role;
select bt_test.login('b@bt.test');
select bt_test.ok('Fremde Bewertungen unsichtbar', (select count(*) from beta_ratings) = 0);
select bt_test.denied('Dashboard nur für das Husora-Team', $$ select public.beta_dashboard() $$);
reset role;

\echo '=== Serverseitige Prozess-Ereignisse ==='
select bt_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'BT Hausservice');
reset role;

\echo '=== Admin-Dashboard ==='
select bt_test.login('support@husora.test');
select bt_test.ok('Super-Admin sieht alle Meldungen', (select count(*) from app_feedback where page in ('calendar', 'tasks') and message like '%Kalender%' or title = 'Speichern hängt') >= 2);
select bt_test.ok('Super-Admin setzt Status (nur Status, Text bleibt)', bt_test.affected($$ update app_feedback set status = 'resolved', message = 'überschrieben' where title = 'Speichern hängt' $$) = 1);
select bt_test.ok('Erledigt mit Zeitstempel, Text unverändert', (select status = 'resolved' and resolved_at is not null and message like 'Beim Speichern%' from app_feedback where title = 'Speichern hängt'));
select bt_test.ok('Dashboard liefert Kennzahlen, Funnel und KPI-Ziele',
  (select (d -> 'users' ->> 'registered')::int >= 2 and jsonb_array_length(d -> 'funnel_owner') = 8 and jsonb_array_length(d -> 'funnel_partner') = 6
          and jsonb_array_length(d -> 'kpis') = 8 and (d -> 'quality' ->> 'avg_rating')::numeric between 4 and 5
          and (d -> 'quality' -> 'value_per_month' ->> '4.99')::int >= 1 from (select public.beta_dashboard() d) x));
select bt_test.ok('Super-Admin kann Beta abschalten', bt_test.affected($$ update app_config set value = value || '{"analytics": false}' where key = 'beta' $$) = 1);
reset role;
select bt_test.login('a@bt.test');
select bt_test.ok('Analytics aus → nichts gespeichert', public.track_events('[{"event_name":"onboarding_completed","entity_ref":"once"}]') = 0);
reset role;

\echo '=== Alle Beta-Tests bestanden ==='
rollback;
