-- =============================================================================
-- HUSORA · Test Status-Engine und Auftragsereignisse (Phase 2)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_flow_test.sql

\set QUIET on
begin;
create schema of_test;
grant usage on schema of_test to authenticated;
create table of_test.vars (k text primary key, v text);
grant all on of_test.vars to authenticated;

create function of_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function of_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'AUFTRAGS-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function of_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'AUFTRAGS-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function of_test.set(k text, v text) returns void language sql as $$ insert into of_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function of_test.get(k text) returns text language sql as $$ select v from of_test.vars where vars.k = get.k $$;
create function of_test.status() returns text language sql as $$ select status from public.service_orders where id = of_test.get('order')::uuid $$;
create function of_test.events(p_type text) returns bigint language sql as $$ select count(*) from public.service_order_events where service_order_id = of_test.get('order')::uuid and event_type = p_type $$;
grant execute on all functions in schema of_test to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@flow.test', 'Clara'), ('fremd@flow.test', 'Fritz')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: Partnerbetrieb, Verbindung, Auftrag ==='
select of_test.login('chef@flow.test');
select of_test.set('org', public.create_partner_organization('{"name":"Flow Service AB","email":"info@flow.test","services":["inspection"]}')::text);
reset role;
select of_test.login('fremd@flow.test');
select public.create_partner_organization('{"name":"Fremd Service AB","services":["cleaning"]}');
reset role;
select of_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Flow Service AB', 'info@flow.test');
select of_test.set('sp', (select id::text from service_partners where company_name = 'Flow Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select of_test.set('code', public.create_service_partner_invite(of_test.get('sp')::uuid, 'info@flow.test'));
reset role;
select of_test.login('chef@flow.test');
select public.accept_service_partner_invite(of_test.get('code'));
reset role;
select of_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'Abwesenheitskontrolle Dezember');
select of_test.set('order', public.offer_service_order((select id from service_tasks where title = 'Abwesenheitskontrolle Dezember'), of_test.get('sp')::uuid, 500)::text);
select of_test.ok('Auftragsart aus dem Titel abgeleitet (inspection)', (select order_type from service_orders where id = of_test.get('order')::uuid) = 'inspection');
select of_test.ok('Ereignis „created“ beim Anlegen', of_test.events('created') = 1);
reset role;

\echo '=== Partner: erlaubte und verbotene Übergänge ==='
select of_test.login('chef@flow.test');
select of_test.denied('offered → completed ist nicht erlaubt', format($$ update service_orders set status = 'completed' where id = %L $$, of_test.get('order')));
select of_test.denied('offered → in_progress ist nicht erlaubt', format($$ select public.transition_service_order(%L, 'in_progress') $$, of_test.get('order')));
select of_test.ok('Annehmen', (select status from public.respond_service_order(of_test.get('order')::uuid, true, 'Gern', now() + interval '2 days')) = 'accepted');
select of_test.ok('Starten (accepted → in_progress), Startzeit gesetzt', (select status = 'in_progress' and started_at is not null from public.transition_service_order(of_test.get('order')::uuid, 'in_progress')));
select of_test.ok('Wartet auf Material, mit Nachricht', (select status from public.transition_service_order(of_test.get('order')::uuid, 'waiting_parts', 'Ersatzteil bestellt')) = 'waiting_parts');
select of_test.ok('Ereignis enthält die Nachricht', exists (select 1 from service_order_events where service_order_id = of_test.get('order')::uuid and new_status = 'waiting_parts' and message = 'Ersatzteil bestellt' and actor_side = 'partner'));
select of_test.ok('Wartet auf Kunde', (select status from public.transition_service_order(of_test.get('order')::uuid, 'waiting_customer', 'Bitte Schlüssel hinterlegen')) = 'waiting_customer');
select of_test.denied('Partner kann nicht stornieren', format($$ select public.transition_service_order(%L, 'cancelled') $$, of_test.get('order')));
select of_test.ok('Weiter (waiting_customer → in_progress)', (select status from public.transition_service_order(of_test.get('order')::uuid, 'in_progress')) = 'in_progress');
select of_test.ok('Abschließen, Abschlusszeit gesetzt', (select status = 'completed' and completed_at is not null from public.transition_service_order(of_test.get('order')::uuid, 'completed', 'Alles in Ordnung')));
select of_test.denied('completed → in_progress direkt nicht erlaubt', format($$ update service_orders set status = 'in_progress' where id = %L $$, of_test.get('order')));
select of_test.ok('Partner sieht das Protokoll seines Auftrags', of_test.events('status_changed') >= 6);
select of_test.denied('Ereignisse sind nicht direkt beschreibbar', format($$ insert into service_order_events (service_order_id, organization_id, event_type) values (%L, 'cccccccc-0000-4000-8000-000000000001', 'note') $$, of_test.get('order')));
reset role;

\echo '=== Hausbesitzer: Protokoll, Benachrichtigung, Wiedereröffnung ==='
select of_test.login('admin@husora.test');
select of_test.ok('Hausbesitzer sieht das vollständige Protokoll', (select count(*) from service_order_events where service_order_id = of_test.get('order')::uuid) >= 7);
select of_test.ok('Benachrichtigung „Wartet auf Material“', exists (select 1 from notifications where entity_id = of_test.get('order')::uuid and title like 'Wartet auf Material:%'));
select of_test.ok('Benachrichtigung „wartet auf deine Rückmeldung“', exists (select 1 from notifications where entity_id = of_test.get('order')::uuid and title like '%wartet auf deine Rückmeldung'));
select of_test.denied('Auch die Verwaltung kann completed → in_progress nicht direkt setzen', format($$ update service_orders set status = 'in_progress' where id = %L $$, of_test.get('order')));
select of_test.denied('Wiedereröffnung nur mit Grund', format($$ select public.reopen_service_order(%L, '  ') $$, of_test.get('order')));
select of_test.ok('Wiedereröffnung mit Grund', (select status = 'in_progress' and completed_at is null from public.reopen_service_order(of_test.get('order')::uuid, 'Fenster noch undicht')));
select of_test.ok('Ereignis „reopened“ mit Grund', exists (select 1 from service_order_events where service_order_id = of_test.get('order')::uuid and event_type = 'reopened' and message = 'Fenster noch undicht' and actor_side = 'owner'));
select of_test.ok('Stornieren durch die Verwaltung, Zeitpunkt gesetzt', (select status = 'cancelled' and cancelled_at is not null from public.transition_service_order(of_test.get('order')::uuid, 'cancelled', 'Nicht mehr nötig')));
select of_test.denied('cancelled → offered nicht erlaubt', format($$ update service_orders set status = 'offered' where id = %L $$, of_test.get('order')));
select of_test.denied('Unbekannter Status wird abgelehnt', format($$ update service_orders set status = 'pending' where id = %L $$, of_test.get('order')));
reset role;

\echo '=== Fremde Firma sieht nichts ==='
select of_test.login('fremd@flow.test');
select of_test.ok('Fremde Firma sieht keine Auftragsereignisse', (select count(*) from service_order_events) = 0);
select of_test.denied('Fremde Firma kann keinen Status setzen', format($$ select public.transition_service_order(%L, 'in_progress') $$, of_test.get('order')));
select of_test.denied('Fremde Firma kann nicht wieder öffnen', format($$ select public.reopen_service_order(%L, 'x') $$, of_test.get('order')));
reset role;

\echo '=== Status-Engine (Regeltabelle) ==='
select of_test.ok('Engine: waiting_parts → in_progress (Partner)', private.order_transition_allowed('waiting_parts', 'in_progress', 'partner'));
select of_test.ok('Engine: completed → in_progress nie direkt', not private.order_transition_allowed('completed', 'in_progress', 'owner') and not private.order_transition_allowed('completed', 'in_progress', 'partner'));
select of_test.ok('Engine: rejected ist endgültig', not private.order_transition_allowed('rejected', 'offered', 'owner') and not private.order_transition_allowed('rejected', 'accepted', 'partner'));
select of_test.ok('Engine: draft → offered nur Verwaltung', private.order_transition_allowed('draft', 'offered', 'owner') and not private.order_transition_allowed('draft', 'offered', 'partner'));

\echo '=== Alle Auftrags-Tests bestanden ==='
rollback;
