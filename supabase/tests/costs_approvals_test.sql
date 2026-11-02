-- =============================================================================
-- HUSORA · Test Arbeitszeit, Material, Anfahrt und Freigaben (Phase 8)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/costs_approvals_test.sql

\set QUIET on
begin;
create schema ca_test;
grant usage on schema ca_test to authenticated;
create table ca_test.vars (k text primary key, v text);
grant all on ca_test.vars to authenticated;

create function ca_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function ca_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'KOSTEN-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function ca_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'KOSTEN-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function ca_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function ca_test.set(k text, v text) returns void language sql as $$ insert into ca_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function ca_test.get(k text) returns text language sql as $$ select v from ca_test.vars where vars.k = get.k $$;
grant execute on all functions in schema ca_test to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@ca.test', 'Rita'), ('fremd@ca.test', 'Fynn'), ('tech@ca.test', 'Theo')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: verbundener Partner mit Auftrag ==='
select ca_test.login('chef@ca.test');
select ca_test.set('org', public.create_partner_organization('{"name":"Kosten Service AB","email":"info@ca.test","services":["inspection"]}')::text);
reset role;
select ca_test.login('fremd@ca.test');
select public.create_partner_organization('{"name":"Fremd Kosten AB","services":["cleaning"]}');
reset role;
select ca_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Kosten Service AB', 'info@ca.test');
select ca_test.set('sp', (select id::text from service_partners where company_name = 'Kosten Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select ca_test.set('code', public.create_service_partner_invite(ca_test.get('sp')::uuid, 'info@ca.test'));
reset role;
select ca_test.login('chef@ca.test');
select public.accept_service_partner_invite(ca_test.get('code'));
reset role;
select ca_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'CA Hausservice');
select ca_test.set('order', public.offer_service_order((select id from service_tasks where title = 'CA Hausservice'), ca_test.get('sp')::uuid, 300)::text);
reset role;

-- Techniker im Partnerbetrieb, dem der Auftrag zugewiesen ist
insert into organization_members (organization_id, user_id, role, status)
select ca_test.get('org')::uuid, u.id, 'technician', 'active' from public.users u where u.email = 'tech@ca.test';
select ca_test.login('chef@ca.test');
update service_orders set status = 'accepted', assigned_user_id = (select id from public.users where email = 'tech@ca.test') where id = ca_test.get('order')::uuid;
reset role;

\echo '=== Zeit, Material und Anfahrt ==='
select ca_test.login('tech@ca.test');
insert into service_order_cost_items (organization_id, service_order_id, kind, user_id, description, started_at, ended_at)
values ('cccccccc-0000-4000-8000-000000000001', ca_test.get('order')::uuid, 'work', private.current_user_id(), 'CA-Zeit', now() - interval '95 minutes', now());
select ca_test.set('w', (select id::text from service_order_cost_items where description = 'CA-Zeit'));
select ca_test.ok('Arbeitszeit: Minuten berechnet, Organisation = Partnerbetrieb (nicht vom Client)',
  (select minutes = 95 and organization_id = ca_test.get('org')::uuid from service_order_cost_items where id = ca_test.get('w')::uuid));
select ca_test.denied('Techniker kann keine Einträge für andere anlegen', format($$ insert into service_order_cost_items (organization_id, service_order_id, kind, user_id, amount)
  values (%L, %L, 'material', null, 10) $$, ca_test.get('org'), ca_test.get('order')));
reset role;
select ca_test.login('chef@ca.test');
insert into service_order_cost_items (organization_id, service_order_id, kind, description, quantity, unit, unit_price, amount)
values (ca_test.get('org')::uuid, ca_test.get('order')::uuid, 'material', 'Silikon', 2, 'Stk', 9.5, 19),
       (ca_test.get('org')::uuid, ca_test.get('order')::uuid, 'travel', 'Anfahrt', 1, null, null, 45);
select ca_test.ok('Leitung sieht alle Positionen', (select count(*) from service_order_cost_items where service_order_id = ca_test.get('order')::uuid) = 3);
select ca_test.ok('Leitung kann die Zeit des Technikers korrigieren', ca_test.affected(format($$ update service_order_cost_items set minutes = 90 where id = %L $$, ca_test.get('w'))) = 1);
reset role;
select ca_test.login('fremd@ca.test');
select ca_test.ok('Fremde Firma sieht keine Positionen', (select count(*) from service_order_cost_items where service_order_id = ca_test.get('order')::uuid) = 0);
select ca_test.denied('Fremde Firma kann keine Position anlegen', format($$ insert into service_order_cost_items (organization_id, service_order_id, kind, user_id, amount)
  values (%L, %L, 'travel', private.current_user_id(), 1) $$, ca_test.get('org'), ca_test.get('order')));
reset role;
select ca_test.login('admin@husora.test');
select ca_test.ok('Hausbesitzer sieht die internen Positionen nicht', (select count(*) from service_order_cost_items where service_order_id = ca_test.get('order')::uuid) = 0);
select ca_test.denied('Hausbesitzer kann keine Position beim Partner anlegen', format($$ insert into service_order_cost_items (organization_id, service_order_id, kind, user_id, amount)
  values ('cccccccc-0000-4000-8000-000000000001', %L, 'travel', private.current_user_id(), 1) $$, ca_test.get('order')));
reset role;

\echo '=== Mehrkosten zur Freigabe ==='
select ca_test.login('admin@husora.test');
select ca_test.denied('Hausbesitzer kann keine Mehrkosten bei sich selbst anfragen', format($$ select public.request_approval(%L, 'x', 10) $$, ca_test.get('order')));
select ca_test.denied('Direktes Anlegen einer Freigabe verboten', format($$ insert into approval_requests (organization_id, service_order_id, service_partner_id, title, amount)
  values ('cccccccc-0000-4000-8000-000000000001', %L, %L, 'x', 1) $$, ca_test.get('order'), ca_test.get('sp')));
reset role;
select ca_test.login('chef@ca.test');
select ca_test.denied('Negativer Betrag abgelehnt', format($$ select public.request_approval(%L, 'Rohr', -5) $$, ca_test.get('order')));
select ca_test.set('a1', (public.request_approval(ca_test.get('order')::uuid, 'Zusätzliches Rohrstück', 180, 'Altes Rohr korrodiert') ->> 'id'));
select ca_test.ok('Ohne Limit: Anfrage offen', (select status = 'pending' and not auto_approved from approval_requests where id = ca_test.get('a1')::uuid));
select ca_test.ok('Auftrag wartet auf Freigabe', (select approval_status = 'pending' and requires_approval from service_orders where id = ca_test.get('order')::uuid));
select ca_test.denied('Partner kann nicht selbst freigeben', format($$ select public.respond_approval(%L, true) $$, ca_test.get('a1')));
reset role;
select ca_test.login('fremd@ca.test');
select ca_test.ok('Fremde Firma sieht die Freigabe nicht', (select count(*) from approval_requests where id = ca_test.get('a1')::uuid) = 0);
select ca_test.denied('Fremde Firma kann keine Mehrkosten anfragen', format($$ select public.request_approval(%L, 'x', 1) $$, ca_test.get('order')));
reset role;
select ca_test.login('admin@husora.test');
select ca_test.ok('Hausbesitzer benachrichtigt', exists (select 1 from notifications where entity_id = ca_test.get('order')::uuid and title like 'Freigabe angefragt%'));
select ca_test.ok('Freigeben', public.respond_approval(ca_test.get('a1')::uuid, true, 'Ok') = 'approved');
select ca_test.ok('Auftrag: freigegeben, Kostenschätzung erhöht', (select approval_status = 'approved' and estimated_cost = 480 from service_orders where id = ca_test.get('order')::uuid));
select ca_test.denied('Zweite Entscheidung nicht möglich', format($$ select public.respond_approval(%L, false) $$, ca_test.get('a1')));
select ca_test.ok('Verlauf enthält Anfrage und Freigabe', (select count(*) from service_order_events where service_order_id = ca_test.get('order')::uuid and message like '%Rohrstück%') = 2);
update organizations set auto_approval_limit = 100 where id = 'cccccccc-0000-4000-8000-000000000001';
reset role;

\echo '=== Automatische Freigabe bis zum Limit ==='
select ca_test.login('tech@ca.test');
select ca_test.ok('Techniker: 60 unter dem Limit → automatisch freigegeben', (public.request_approval(ca_test.get('order')::uuid, 'Dichtungen', 60) ->> 'auto_approved')::boolean);
select ca_test.ok('Kostenschätzung um 60 erhöht', (select estimated_cost from service_orders where id = ca_test.get('order')::uuid) = 540);
select ca_test.set('a3', (public.request_approval(ca_test.get('order')::uuid, 'Neue Pumpe', 650) ->> 'id'));
select ca_test.ok('Über dem Limit → offen', (select status from approval_requests where id = ca_test.get('a3')::uuid) = 'pending');
reset role;
select ca_test.login('admin@husora.test');
select ca_test.ok('Ablehnen', public.respond_approval(ca_test.get('a3')::uuid, false, 'Zu teuer') = 'rejected');
select ca_test.ok('Abgelehnt: Kosten unverändert', (select approval_status = 'rejected' and estimated_cost = 540 from service_orders where id = ca_test.get('order')::uuid));
reset role;
select ca_test.login('chef@ca.test');
select ca_test.ok('Partner sieht Ablehnung mit Grund', (select status || '/' || response_note from approval_requests where id = ca_test.get('a3')::uuid) = 'rejected/Zu teuer');
update service_orders set status = 'completed', actual_cost = 600 where id = ca_test.get('order')::uuid;
select ca_test.denied('Keine Mehrkosten nach Abschluss', format($$ select public.request_approval(%L, 'x', 1) $$, ca_test.get('order')));
reset role;

\echo '=== Alle Kosten-Tests bestanden ==='
rollback;
