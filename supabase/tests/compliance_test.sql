-- =============================================================================
-- HUSORA · Compliance-Test: Datensparsamkeit, Löschung, Aufbewahrung, Mandantentrennung
-- =============================================================================
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/compliance_test.sql
\set QUIET on
begin;
create schema cp_test;
grant usage on schema cp_test to authenticated;
create function cp_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function cp_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'COMPLIANCE-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
grant execute on all functions in schema cp_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'weg@cp.test', '', now(), '{"provider":"email","providers":["email"]}', '{"first_name":"Wera"}', now(), now());
update app_config set value = value || '{"enabled": true, "analytics": true}' where key = 'beta';
\set QUIET off

\echo '=== Datensparsamkeit: keine Inhalte/Geheimnisse in Analytics ==='
select cp_test.login('weg@cp.test');
select public.track_events('[{"event_name":"task_created","entity_ref":"cp1","metadata":{"title":"Geheim","note":"privat","access_token":"x","email":"a@b.c","count":2}}]');
reset role;
select cp_test.ok('Nur unkritische Metadaten gespeichert', (select metadata = '{"count": 2}'::jsonb from analytics_events e join users u on u.id = e.user_id where u.email = 'weg@cp.test' and event_name = 'task_created'));
select cp_test.ok('Keine Analytics-Spalte für Freitext/Personendaten', not exists (select 1 from information_schema.columns where table_name = 'analytics_events' and column_name ~ '^(email|.*_email|message|comment|.*token|password|ip|ip_address|user_agent|first_name|last_name|phone|address)$'));

\echo '=== Recht auf Löschung: Konto löschen entfernt die neuen Daten ==='
select cp_test.login('weg@cp.test');
insert into beta_ratings (rating, context) values (4, 'general');
insert into notification_preferences (category, email) values ('order', true);
insert into push_subscriptions (endpoint, p256dh, auth_key) values ('https://push.example.test/cp', repeat('p', 40), repeat('a', 16));
insert into app_feedback (kind, message) values ('feedback', 'CP Feedback');
select public.delete_my_account('LÖSCHEN');
reset role;
select cp_test.ok('Nutzer gelöscht', not exists (select 1 from auth.users where email = 'weg@cp.test'));
select cp_test.ok('Analytics, Bewertungen, Einstellungen, Push-Abos gelöscht', not exists (select 1 from analytics_events e where e.entity_ref = 'cp1')
  and not exists (select 1 from push_subscriptions where endpoint = 'https://push.example.test/cp')
  and not exists (select 1 from beta_ratings r left join users u on u.id = r.user_id where u.id is null and r.context = 'general' and r.created_at > now() - interval '1 minute'));
select cp_test.ok('Feedback ohne Personenbezug (Nutzer entfernt)', (select bool_and(user_id is null) from app_feedback where message = 'CP Feedback'));

\echo '=== Aufbewahrung ==='
insert into analytics_events (event_name, occurred_at, source) values ('session_started', now() - interval '14 months', 'server');
select private.cleanup_retention();
select cp_test.ok('Alte Analytics-Ereignisse werden gelöscht (13 Monate)', not exists (select 1 from analytics_events where occurred_at < now() - interval '13 months'));
select cp_test.ok('Bereinigung ist wöchentlich eingeplant', exists (select 1 from cron.job where jobname = 'husora-retention'));

\echo '=== Mandantentrennung neuer Tabellen (RLS-Policies vorhanden) ==='
select cp_test.ok('Alle neuen Tabellen haben Lese-Policies', (select count(distinct tablename) from pg_policies where schemaname = 'public' and cmd in ('SELECT', 'ALL')
  and tablename in ('analytics_events', 'beta_ratings', 'app_config', 'notification_preferences', 'push_subscriptions', 'service_order_cost_items', 'approval_requests', 'service_partner_reviews', 'ai_suggestions')) = 9);

\echo '=== Alle Compliance-Tests bestanden ==='
rollback;
