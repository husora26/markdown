-- =============================================================================
-- HUSORA · Test Partner-Portal (Servicepartner als eigene Organisation)
-- =============================================================================
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_portal_test.sql

\set QUIET on
begin;
create schema pp_test;
grant usage on schema pp_test to authenticated;
create table pp_test.vars (k text primary key, v text);
grant all on pp_test.vars to authenticated;

create function pp_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pp_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'PARTNER-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function pp_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'PARTNER-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function pp_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function pp_test.set(k text, v text) returns void language sql as $$ insert into pp_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function pp_test.get(k text) returns text language sql as $$ select v from pp_test.vars where vars.k = get.k $$;
grant execute on all functions in schema pp_test to authenticated;

-- Testkonten der Partnerseite
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('firma@partner.test', 'Fiona'), ('techniker@partner.test', 'Tom'), ('kollege@partner.test', 'Kai'), ('fremdfirma@partner.test', 'Frank')) v(e, f);
\set QUIET off

\echo '=== Partner legt Servicebetrieb an ==='
select pp_test.login('firma@partner.test');
select pp_test.set('org', public.create_partner_organization('{"name":"Värmland Hausservice AB","legal_form":"AB","contact_name":"Fiona","email":"info@vhs.test","phone":"+46 70 1","city":"Sunne","country":"SE","vat_id":"SE556677889901","service_radius_km":"60","services":["inspection","cleaning","gardening"]}')::text);
select pp_test.ok('Organisation angelegt, Rolle admin', (public.partner_context() ->> 'role') = 'admin');
select pp_test.ok('Eigener Partner-Datensatz + 3 Leistungen', (select count(*) from service_partner_services where service_partner_id = (public.partner_context() ->> 'self_partner_id')::uuid) = 3);
select pp_test.ok('5 Standard-Kontrollvorlagen', (select count(*) from inspection_templates where organization_id = pp_test.get('org')::uuid) = 5);
select pp_test.denied('Zweiter Betrieb mit demselben Konto nicht möglich', $$ select public.create_partner_organization('{"name":"Doppelt"}') $$);
select pp_test.ok('Partner sieht noch keine Hausbesitzer-Daten', (select count(*) from properties where organization_id = 'cccccccc-0000-4000-8000-000000000001') = 0);
select pp_test.set('team_code', public.create_member_invite(pp_test.get('org')::uuid, 'techniker@partner.test', 'technician'));
select pp_test.ok('Mitarbeiter-Einladung erstellt', pp_test.get('team_code') ~ '^TEAM-');
select pp_test.set('team_code2', public.create_member_invite(pp_test.get('org')::uuid, 'kollege@partner.test', 'technician'));
reset role;

\echo '=== Techniker nimmt Einladung an ==='
select pp_test.login('kollege@partner.test');
select pp_test.denied('Einladung gilt nur für die eingeladene E-Mail', $$ select public.accept_member_invite(pp_test.get('team_code')) $$);
select public.accept_member_invite(pp_test.get('team_code2'));
reset role;
select pp_test.login('techniker@partner.test');
select pp_test.ok('Techniker tritt bei', (public.accept_member_invite(pp_test.get('team_code')) ->> 'role') = 'technician');
reset role;

\echo '=== Hausbesitzer lädt Partner ein ==='
select pp_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Värmland Hausservice AB', 'info@vhs.test');
select pp_test.set('sp', (select id::text from service_partners where company_name = 'Värmland Hausservice AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select pp_test.set('code', public.create_service_partner_invite(pp_test.get('sp')::uuid, 'info@vhs.test'));
select pp_test.ok('Einladungscode im Format HUS-XXXX-XXXX', pp_test.get('code') ~ '^HUS-[A-Z0-9]{4}-[A-Z0-9]{4}$');
reset role;

select pp_test.login('fremdfirma@partner.test');
select public.create_partner_organization('{"name":"Fremde Firma AB","services":["cleaning"]}');
select pp_test.denied('Falscher Code wird abgelehnt', $$ select public.accept_service_partner_invite('HUS-AAAA-BBBB') $$);
reset role;

\echo '=== Partner nimmt Einladung an ==='
select pp_test.login('firma@partner.test');
select pp_test.ok('Einladung angenommen', (public.accept_service_partner_invite(lower(pp_test.get('code'))) ->> 'organization_name') = 'Husora Testorganisation');
select pp_test.ok('Kunde wird automatisch angelegt', exists (select 1 from customers where linked_organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select pp_test.ok('Verbindung im Portal-Kontext', jsonb_array_length(public.partner_context() -> 'links') = 1);
reset role;
select pp_test.login('fremdfirma@partner.test');
select pp_test.denied('Code kann nicht zweimal verwendet werden', format($$ select public.accept_service_partner_invite(%L) $$, pp_test.get('code')));
reset role;

\echo '=== Hausbesitzer beauftragt den Partner ==='
select pp_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title, description, priority, scheduled_start)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'Abwesenheitskontrolle November', 'Bitte auch Briefkasten leeren.', 'normal', now() + interval '3 days');
select pp_test.set('order', public.offer_service_order((select id from service_tasks where title = 'Abwesenheitskontrolle November'), pp_test.get('sp')::uuid, 650)::text);
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002', 'Zweiter Auftrag');
select pp_test.set('order2', public.offer_service_order((select id from service_tasks where title = 'Zweiter Auftrag'), pp_test.get('sp')::uuid)::text);
reset role;

\echo '=== Partner (Leitung) arbeitet mit dem Auftrag ==='
select pp_test.login('firma@partner.test');
select pp_test.ok('Partner sieht beide angebotenen Aufträge', (select count(*) from service_orders where service_partner_id = pp_test.get('sp')::uuid) = 2);
select pp_test.ok('Partner sieht keine fremden Aufträge des Kunden', not exists (select 1 from service_orders where service_partner_id <> pp_test.get('sp')::uuid and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select pp_test.ok('Partner sieht Haus und Adresse des Auftrags', (select count(*) from properties where organization_id = 'cccccccc-0000-4000-8000-000000000001') = 2);
select pp_test.ok('Partner sieht keine Gästebuchungen', (select count(*) from bookings where organization_id = 'cccccccc-0000-4000-8000-000000000001') = 0);
select pp_test.ok('Auftrag annehmen', (select status from public.respond_service_order(pp_test.get('order')::uuid, true, 'Machen wir', now() + interval '3 days')) = 'accepted');
select pp_test.ok('Techniker einteilen', pp_test.affected(format($$ update service_orders set assigned_user_id = (select id from users where email = 'techniker@partner.test') where id = %L $$, pp_test.get('order'))) = 1);
select pp_test.denied('Nur Mitarbeiter des Partners einteilbar', format($$ update service_orders set assigned_user_id = 'bbbbbbbb-0000-4000-8000-000000000002' where id = %L $$, pp_test.get('order')));
select pp_test.ok('Nachricht an den Kunden im Auftrag', pp_test.affected(format($$ insert into messages (organization_id, service_order_id, message) values ('cccccccc-0000-4000-8000-000000000001', %L, 'Wir kommen am Donnerstag.') $$, pp_test.get('order'))) = 1);
select pp_test.set('insp', public.partner_start_inspection('dddddddd-0000-4000-8000-000000000001', (select id from inspection_templates where organization_id = pp_test.get('org')::uuid and name = 'Ferienhaus Kontrolle'))::text);
select pp_test.ok('Kontrolle beim Kunden mit eigener Vorlage (11 Punkte)', (select count(*) from inspection_items where inspection_id = pp_test.get('insp')::uuid) = 11);
select pp_test.ok('Prüfpunkte bearbeiten', pp_test.affected(format($$ update inspection_items set status = 'ok' where inspection_id = %L $$, pp_test.get('insp'))) = 11);
update inspection_items set status = 'defect', notes = 'Dachrinne undicht' where inspection_id = pp_test.get('insp')::uuid and name = 'Dach und Dachrinne';
select pp_test.ok('Kontrolle abschließen', pp_test.affected(format($$ update inspections set status = 'completed', overall_status = 'warning' where id = %L $$, pp_test.get('insp'))) = 1);
select pp_test.ok('Rechnung einreichen', pp_test.affected(format($$ insert into invoices (organization_id, property_id, service_order_id, service_partner_id, invoice_number, amount_net, tax_amount, amount_gross, currency, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', %L, %L, 'VHS-1', 520, 130, 650, 'SEK', 'received') $$, pp_test.get('order'), pp_test.get('sp'))) = 1);
-- eigener Kunde mit Haus und Auftrag
insert into customers (organization_id, first_name, last_name, email) values (pp_test.get('org')::uuid, 'Greta', 'Gärtner', 'greta@kunde.test');
insert into properties (organization_id, name, city, owner_customer_id) values (pp_test.get('org')::uuid, 'Villa Greta', 'Arvika', (select id from customers where last_name = 'Gärtner'));
insert into service_orders (organization_id, property_id, service_partner_id, title, status, estimated_cost)
values (pp_test.get('org')::uuid, (select id from properties where name = 'Villa Greta'), (public.partner_context() ->> 'self_partner_id')::uuid, 'Rasen mähen', 'accepted', 400);
select pp_test.ok('Eigener Kunde, Haus und Auftrag', (select count(*) from service_orders where organization_id = pp_test.get('org')::uuid) = 1);
reset role;

\echo '=== Techniker sieht nur zugewiesene Aufträge ==='
select pp_test.login('techniker@partner.test');
select pp_test.ok('Techniker sieht genau seinen Auftrag', (select count(*) from service_orders) = 1 and (select id::text from service_orders) = pp_test.get('order'));
select pp_test.ok('Techniker sieht das Haus seines Auftrags', (select count(*) from properties) = 1);
select pp_test.ok('Techniker sieht keine Rechnungen', (select count(*) from invoices) = 0);
select pp_test.ok('Techniker sieht die Auftragsnachricht', (select count(*) from messages where service_order_id = pp_test.get('order')::uuid) = 1);
select pp_test.ok('Techniker startet den Auftrag', pp_test.affected(format($$ update service_orders set status = 'in_progress' where id = %L $$, pp_test.get('order'))) = 1);
update service_orders set estimated_cost = 99999, assigned_user_id = null where id = pp_test.get('order')::uuid;
select pp_test.ok('Techniker kann Preis und Zuteilung nicht ändern', (select estimated_cost from service_orders where id = pp_test.get('order')::uuid) = 650
  and (select assigned_user_id from service_orders where id = pp_test.get('order')::uuid) is not null);
select pp_test.ok('Techniker kann zweiten Auftrag nicht annehmen', pp_test.affected(format($$ update service_orders set status = 'accepted' where id = %L $$, pp_test.get('order2'))) = 0);
select pp_test.ok('Techniker schließt ab', pp_test.affected(format($$ update service_orders set status = 'completed', actual_cost = 650 where id = %L $$, pp_test.get('order'))) = 1);
reset role;
select pp_test.login('kollege@partner.test');
select pp_test.ok('Nicht zugewiesener Kollege sieht keine Kundenaufträge', (select count(*) from service_orders where organization_id = 'cccccccc-0000-4000-8000-000000000001') = 0);
reset role;

\echo '=== Fremde Firma bleibt ausgesperrt ==='
select pp_test.login('fremdfirma@partner.test');
select pp_test.ok('Fremde Firma sieht keine Aufträge, Häuser, Kunden, Kontrollen', (select count(*) from service_orders) = 0 and (select count(*) from properties) = 0
  and (select count(*) from customers) = 0 and (select count(*) from inspections) = 0 and (select count(*) from messages) = 0);
select pp_test.denied('Fremde Firma kann keine Kontrolle beim Kunden starten', $$ select public.partner_start_inspection('dddddddd-0000-4000-8000-000000000001', (select id from inspection_templates limit 1)) $$);
reset role;

\echo '=== Hausbesitzer sieht die Ergebnisse ==='
select pp_test.login('admin@husora.test');
select pp_test.ok('Auftrag erledigt, Aufgabe automatisch erledigt', (select status from service_orders where id = pp_test.get('order')::uuid) = 'completed'
  and (select status from service_tasks where title = 'Abwesenheitskontrolle November') = 'completed');
select pp_test.ok('Nachricht des Partners sichtbar', exists (select 1 from messages where message = 'Wir kommen am Donnerstag.'));
select pp_test.ok('Kontrolle des Partners sichtbar, Mangel → Reparatur', (select count(*) from repairs where inspection_id = pp_test.get('insp')::uuid) = 1);
select pp_test.ok('Rechnung des Partners sichtbar', exists (select 1 from invoices where invoice_number = 'VHS-1'));
select pp_test.ok('Hausbesitzer sieht nicht die Kunden des Partners', (select count(*) from customers) = 0);
reset role;

\echo '=== Alle Partner-Tests bestanden ==='
rollback;
