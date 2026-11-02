-- =============================================================================
-- HUSORA · Test Phase 9: Benachrichtigungen (Kategorien, Einstellungen, Push-Abos) + Chat-Anhänge
-- =============================================================================
\set QUIET on
begin;
create schema nt_test;
grant usage on schema nt_test to authenticated;
create table nt_test.vars (k text primary key, v text);
grant all on nt_test.vars to authenticated;
create function nt_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function nt_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'NOTIFY-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function nt_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'NOTIFY-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function nt_test.set(k text, v text) returns void language sql as $$ insert into nt_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function nt_test.get(k text) returns text language sql as $$ select v from nt_test.vars where vars.k = get.k $$;
grant execute on all functions in schema nt_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@nt.test', 'Nora'), ('fremd@nt.test', 'Fynn')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: verbundener Partner mit Auftrag ==='
select nt_test.login('chef@nt.test');
select nt_test.set('org', public.create_partner_organization('{"name":"Notify Service AB","email":"info@nt.test","services":["inspection"]}')::text);
reset role;
select nt_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Notify Service AB', 'info@nt.test');
select nt_test.set('sp', (select id::text from service_partners where company_name = 'Notify Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select nt_test.set('code', public.create_service_partner_invite(nt_test.get('sp')::uuid, 'info@nt.test'));
reset role;
select nt_test.login('chef@nt.test');
select public.accept_service_partner_invite(nt_test.get('code'));
reset role;
select nt_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'NT Hausservice');
select nt_test.set('order', public.offer_service_order((select id from service_tasks where title = 'NT Hausservice'), nt_test.get('sp')::uuid, 100)::text);
reset role;

select nt_test.set('chef', (select id::text from users where email = 'chef@nt.test'));
\echo '=== Kategorien ==='
select nt_test.login('chef@nt.test');
select nt_test.ok('Neue Anfrage hat Kategorie order', (select bool_and(category = 'order') from notifications where entity_id = nt_test.get('order')::uuid));
reset role;

\echo '=== Nachrichten benachrichtigen die Gegenseite ==='
select nt_test.login('admin@husora.test');
insert into messages (organization_id, service_order_id, message) values ('cccccccc-0000-4000-8000-000000000001', nt_test.get('order')::uuid, 'NT Bitte klingeln');
reset role;
select nt_test.login('chef@nt.test');
select nt_test.ok('Partner erhält Nachricht des Hausbesitzers (message)', exists (select 1 from notifications where category = 'message' and message = 'NT Bitte klingeln'));
update service_orders set status = 'accepted' where id = nt_test.get('order')::uuid;
insert into messages (organization_id, service_order_id, message) values ('cccccccc-0000-4000-8000-000000000001', nt_test.get('order')::uuid, 'NT Komme um 9');
reset role;
select nt_test.login('admin@husora.test');
select nt_test.ok('Hausbesitzer erhält Partner-Nachricht im Auftragsgespräch', (select count(*) from notifications where category = 'message' and message = 'NT Komme um 9') = 1);
reset role;

\echo '=== Einstellungen je Kategorie ==='
select nt_test.login('admin@husora.test');
insert into notification_preferences (user_id, category, in_app, push, email) values (private.current_user_id(), 'message', false, false, false) on conflict (user_id, category) do update set in_app = false, push = false, email = false;
reset role;
select nt_test.login('chef@nt.test');
insert into messages (organization_id, service_order_id, message) values ('cccccccc-0000-4000-8000-000000000001', nt_test.get('order')::uuid, 'NT stumm');
reset role;
select nt_test.login('admin@husora.test');
select nt_test.ok('Ganz ausgeschaltet → keine Benachrichtigung', (select count(*) from notifications where message = 'NT stumm') = 0);
update notification_preferences set push = true where user_id = private.current_user_id() and category = 'message';
reset role;
select nt_test.login('chef@nt.test');
insert into messages (organization_id, service_order_id, message) values ('cccccccc-0000-4000-8000-000000000001', nt_test.get('order')::uuid, 'NT nur push');
reset role;
select nt_test.login('admin@husora.test');
select nt_test.ok('Nur Push → Eintrag gilt in der App als gelesen', (select bool_and(read_at is not null) from notifications where message = 'NT nur push' and user_id = private.current_user_id()));
select nt_test.denied('Fremde Einstellungen nicht anlegbar', format($$ insert into notification_preferences (user_id, category) values (%L, 'order') $$, nt_test.get('chef')));
reset role;
select nt_test.login('chef@nt.test');
select nt_test.ok('Fremde Einstellungen unsichtbar', (select count(*) from notification_preferences) = 0);
reset role;

\echo '=== Push-Abos ==='
select nt_test.login('chef@nt.test');
insert into push_subscriptions (endpoint, p256dh, auth_key, user_id) values ('https://push.example.test/abc', repeat('p', 40), repeat('a', 16), (select id from users where email = 'admin@husora.test'));
select nt_test.ok('Abo gehört immer dem angemeldeten Nutzer', (select user_id = private.current_user_id() from push_subscriptions where endpoint = 'https://push.example.test/abc'));
select nt_test.denied('Nur https-Endpunkte', $$ insert into push_subscriptions (endpoint, p256dh, auth_key) values ('http://x.test', repeat('p', 40), repeat('a', 16)) $$);
reset role;
select nt_test.login('admin@husora.test');
select nt_test.ok('Fremde Abos unsichtbar', (select count(*) from push_subscriptions where endpoint = 'https://push.example.test/abc') = 0);
reset role;
select nt_test.ok('Ohne Vault-Einträge kein Versand, Benachrichtigung trotzdem gespeichert', (select count(*) from notifications where message = 'NT Komme um 9') = 1);

\echo '=== Chat-Anhänge ==='
select nt_test.login('chef@nt.test');
insert into documents (organization_id, property_id, service_order_id, file_name, file_type, file_size, storage_bucket, storage_path, document_type)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', nt_test.get('order')::uuid, 'nt-foto.pdf', 'application/pdf', 100, 'husora-documents',
        'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/documents/nt.pdf', 'other');
select nt_test.set('doc', (select id::text from documents where file_name = 'nt-foto.pdf'));
insert into messages (organization_id, service_order_id, message, document_id) values ('cccccccc-0000-4000-8000-000000000001', nt_test.get('order')::uuid, '📎 nt-foto.pdf', nt_test.get('doc')::uuid);
select nt_test.ok('Anhang am Auftragsgespräch', exists (select 1 from messages where document_id = nt_test.get('doc')::uuid));
select nt_test.denied('Anhang nur aus demselben Auftrag', format($$ insert into messages (organization_id, service_partner_id, message, document_id) values ('cccccccc-0000-4000-8000-000000000001', %L, 'x', %L) $$, nt_test.get('sp'), nt_test.get('doc')));
reset role;

\echo '=== Alle Benachrichtigungs-Tests bestanden ==='
rollback;
