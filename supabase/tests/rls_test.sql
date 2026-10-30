-- =============================================================================
-- HUSORA · RLS-Test
-- =============================================================================
-- Prüft Mandantentrennung und Rollenrechte mit den Seed-Daten.
-- Läuft komplett in einer Transaktion und wird am Ende zurückgerollt.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
--
-- Jede Prüfung meldet "OK – …". Beim ersten Fehler bricht das Skript mit
-- "RLS-TEST FEHLGESCHLAGEN – …" ab.

\set QUIET on
begin;

create schema rls_test;
grant usage on schema rls_test to anon, authenticated, service_role;

-- Als Testbenutzer anmelden (simuliert das JWT, das PostgREST setzt)
create function rls_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  if v_id is null then raise exception 'Testbenutzer % fehlt – Seed geladen?', p_email; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function rls_test.login_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  perform set_config('role', 'anon', true);
end $$;

create function rls_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then
    raise exception 'RLS-TEST FEHLGESCHLAGEN – %', p_label;
  end if;
  raise notice 'OK – %', p_label;
end $$;

-- Erwartet, dass die Anweisung mit einem Fehler abgelehnt wird
create function rls_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm;
    return;
  end;
  raise exception 'RLS-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;

-- Anzahl betroffener Zeilen einer Anweisung
create function rls_test.affected(p_sql text) returns integer language plpgsql as $$
declare v_count integer;
begin
  execute p_sql;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

grant execute on all functions in schema rls_test to anon, authenticated, service_role;

\set QUIET off
\echo
\echo '=== Admin (admin@husora.test) ==='
select rls_test.login('admin@husora.test');
select rls_test.ok('Admin sieht genau 1 Organisation', (select count(*) from organizations) = 1);
select rls_test.ok('Admin sieht beide Häuser der eigenen Organisation', (select count(*) from properties) = 2);
select rls_test.ok('Admin sieht kein Haus der fremden Organisation',
  not exists (select 1 from properties where id = 'dddddddd-0000-4000-8000-000000000003'));
select rls_test.ok('Admin sieht alle 3 eigenen Servicepartner', (select count(*) from service_partners) = 3);
select rls_test.ok('Admin sieht nur Buchungen der eigenen Organisation',
  (select count(*) from bookings) = 5 and not exists (select 1 from bookings where organization_id <> 'cccccccc-0000-4000-8000-000000000001'));
select rls_test.ok('Admin sieht keine Aufgabe der fremden Organisation',
  not exists (select 1 from service_tasks where title = 'Geheime Reinigung'));
select rls_test.ok('Admin sieht die Mitglieder der Organisation (5 Profile)', (select count(*) from users) = 5);
select rls_test.ok('Admin liest das Audit-Log der eigenen Organisation', (select count(*) from audit_logs) > 0);
select rls_test.ok('Admin kann ein Haus anlegen', rls_test.affected($$
  insert into properties (organization_id, name, city, country)
  values ('cccccccc-0000-4000-8000-000000000001', 'Teststuga', 'Arvika', 'SE') $$) = 1);
select rls_test.denied('Admin kann KEIN Haus in der fremden Organisation anlegen', $$
  insert into properties (organization_id, name) values ('cccccccc-0000-4000-8000-000000000002', 'Einbruch') $$);
select rls_test.denied('Fremdes Haus kann nicht per Fremdschlüssel in die eigene Organisation gezogen werden', $$
  insert into service_tasks (organization_id, property_id, title)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000003', 'Querverweis') $$);
select rls_test.ok('Admin kann Partner nach Ranking abfragen',
  (select count(*) from match_service_partners('dddddddd-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000001')) = 2);
select rls_test.denied('Admin darf Webhooks nicht direkt einspielen (nur service_role)', $$
  select * from webhook_receive('booking', 'airbnb', 'evt-1', '{}'::jsonb, true) $$);
select rls_test.denied('Doppelbuchung desselben Hauses wird verhindert', $$
  insert into bookings (organization_id, property_id, check_in, check_out, status)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
          date_trunc('day', now()) + interval '4 days', date_trunc('day', now()) + interval '6 days', 'confirmed') $$);
reset role;

\echo
\echo '=== Eigentümer (eigentuemer@husora.test) ==='
select rls_test.login('eigentuemer@husora.test');
select rls_test.ok('Eigentümer sieht nur sein eigenes Haus',
  (select count(*) from properties) = 1 and (select name from properties) = 'Stuga Björkbacken');
select rls_test.ok('Eigentümer sieht nur Buchungen seines Hauses',
  (select count(*) from bookings) = 4 and not exists (select 1 from bookings where property_id <> 'dddddddd-0000-4000-8000-000000000001'));
select rls_test.ok('Eigentümer sieht nur Aufgaben seines Hauses',
  (select count(*) from service_tasks) > 0 and not exists (select 1 from service_tasks where property_id <> 'dddddddd-0000-4000-8000-000000000001'));
select rls_test.ok('Eigentümer sieht Kontrolle, Mangel und Reparatur seines Hauses',
  exists (select 1 from inspection_items where status = 'defect') and (select count(*) from repairs) = 1);
select rls_test.ok('Eigentümer sieht den Partner seiner Aufträge, aber nicht Mora Bygg',
  exists (select 1 from service_partners where company_name = 'Nortivo Service AB')
  and not exists (select 1 from service_partners where company_name = 'Mora Bygg & VVS AB'));
select rls_test.ok('Eigentümer sieht keine Rechnung des anderen Hauses', (select count(*) from invoices) = 0);
select rls_test.ok('Eigentümer sieht nur eigene Benachrichtigungen',
  (select count(*) from notifications) = 2 and not exists (select 1 from notifications where user_id <> 'bbbbbbbb-0000-4000-8000-000000000002'));
select rls_test.ok('Eigentümer liest kein Audit-Log', (select count(*) from audit_logs) = 0);
select rls_test.ok('Eigentümer kann für sein Haus eine Reparatur melden', rls_test.affected($$
  insert into repairs (organization_id, property_id, title)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'Steg wackelt') $$) = 1);
select rls_test.denied('Eigentümer kann für fremdes Haus KEINE Reparatur melden', $$
  insert into repairs (organization_id, property_id, title)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002', 'Nicht meins') $$);
select rls_test.ok('Eigentümer kann das andere Haus nicht ändern', rls_test.affected($$
  update properties set description = 'gehackt' where id = 'dddddddd-0000-4000-8000-000000000002' $$) = 0);
select rls_test.ok('Eigentümer kann die Beschreibung seines Hauses ändern', rls_test.affected($$
  update properties set description = 'Neu gestrichen 2026' where id = 'dddddddd-0000-4000-8000-000000000001' $$) = 1);
update properties set owner_user_id = null where id = 'dddddddd-0000-4000-8000-000000000001';
select rls_test.ok('Eigentümer kann sich nicht als Eigentümer austragen/übertragen (Spaltenschutz)',
  (select owner_user_id from properties where id = 'dddddddd-0000-4000-8000-000000000001') = 'bbbbbbbb-0000-4000-8000-000000000002');
update users set is_super_admin = true where id = 'bbbbbbbb-0000-4000-8000-000000000002';
select rls_test.ok('Benutzer kann sich nicht selbst zum Super-Admin machen',
  (select is_super_admin from users where id = 'bbbbbbbb-0000-4000-8000-000000000002') = false);
select rls_test.ok('Eigentümer kann sich nicht selbst zum Admin machen', rls_test.affected($$
  update organization_members set role = 'admin' where user_id = 'bbbbbbbb-0000-4000-8000-000000000002' $$) = 0);
reset role;

\echo
\echo '=== Servicepartner (partner@husora.test · Nortivo Service AB) ==='
select rls_test.login('partner@husora.test');
select rls_test.ok('Partner sieht nur Aufträge seines Betriebs',
  (select count(*) from service_orders) > 0
  and not exists (select 1 from service_orders where service_partner_id <> 'ffffffff-0000-4000-8000-000000000001'));
select rls_test.ok('Partner sieht den Heizungsauftrag von Mora Bygg nicht',
  not exists (select 1 from service_orders where title = 'Jährliche Heizungswartung'));
select rls_test.ok('Partner sieht keine Buchungen/Gästedaten', (select count(*) from bookings) = 0);
select rls_test.ok('Partner sieht nur Häuser, an denen er arbeitet',
  (select count(*) from properties) = 1 and (select name from properties) = 'Stuga Björkbacken');
select rls_test.ok('Partner sieht nur den eigenen Betrieb', (select count(*) from service_partners) = 1);
select rls_test.ok('Partner sieht die Nachrichten zu seinem Auftrag', (select count(*) from messages) = 2);
select rls_test.ok('Partner kann einen angebotenen Auftrag annehmen',
  (select status from respond_service_order('0d000000-0000-4000-8000-000000000002', true, 'Komme morgen 9 Uhr')) = 'accepted');
update service_orders set estimated_cost = 99999, title = 'geändert' where id = '0d000000-0000-4000-8000-000000000002';
select rls_test.ok('Partner kann Preis und Titel des Auftrags nicht ändern (Spaltenschutz)',
  (select estimated_cost from service_orders where id = '0d000000-0000-4000-8000-000000000002') = 2500.00
  and (select title from service_orders where id = '0d000000-0000-4000-8000-000000000002') <> 'geändert');
select rls_test.denied('Partner kann einen Auftrag nicht stornieren', $$
  update service_orders set status = 'cancelled' where id = '0d000000-0000-4000-8000-000000000002' $$);
select rls_test.ok('Partner kann eine Rechnung einreichen', rls_test.affected($$
  insert into invoices (organization_id, property_id, service_order_id, service_partner_id, invoice_number, amount_net, tax_amount, amount_gross, currency, status)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '0d000000-0000-4000-8000-000000000002',
          'ffffffff-0000-4000-8000-000000000001', 'NOR-2026-500', 2000, 500, 2500, 'SEK', 'received') $$) = 1);
select rls_test.denied('Partner kann eine Rechnung nicht selbst freigeben', $$
  insert into invoices (organization_id, property_id, service_partner_id, invoice_number, amount_gross, status)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
          'ffffffff-0000-4000-8000-000000000001', 'NOR-2026-501', 100, 'approved') $$);
select rls_test.denied('Partner kann keine Rechnung im Namen eines anderen Partners einreichen', $$
  insert into invoices (organization_id, property_id, service_partner_id, invoice_number, amount_gross, status)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002',
          'ffffffff-0000-4000-8000-000000000003', 'FAKE-1', 100, 'received') $$);
select rls_test.ok('Partner kann bei seiner Kontrolle Prüfpunkte nicht mehr ändern, wenn abgeschlossen', rls_test.affected($$
  update inspection_items set status = 'ok' where inspection_id = '1a000000-0000-4000-8000-000000000001' $$) = 0);
reset role;

\echo
\echo '=== Reinigungskraft (reinigung@husora.test) ==='
select rls_test.login('reinigung@husora.test');
select rls_test.ok('Reinigung sieht nur ihre zugewiesene Aufgabe',
  (select count(*) from service_tasks) = 1 and (select title from service_tasks) = 'Wäschewechsel und Begrüßungskorb');
select rls_test.ok('Reinigung sieht das Haus ihrer Aufgabe (Adresse)', (select count(*) from properties) = 1);
select rls_test.ok('Reinigung sieht keine Buchungen/Gästedaten', (select count(*) from bookings) = 0);
select rls_test.ok('Reinigung sieht keine Serviceaufträge', (select count(*) from service_orders) = 0);
select rls_test.ok('Reinigung sieht keine Rechnungen', (select count(*) from invoices) = 0);
select rls_test.ok('Reinigung kann ihre Aufgabe starten', rls_test.affected($$
  update service_tasks set status = 'in_progress' where id = '7a000000-0000-4000-8000-000000000001' $$) = 1);
update service_tasks set title = 'umbenannt', status = 'completed', completion_notes = 'Alles erledigt'
where id = '7a000000-0000-4000-8000-000000000001';
select rls_test.ok('Reinigung kann abschließen, aber den Titel nicht ändern',
  (select status from service_tasks where id = '7a000000-0000-4000-8000-000000000001') = 'completed'
  and (select title from service_tasks where id = '7a000000-0000-4000-8000-000000000001') = 'Wäschewechsel und Begrüßungskorb'
  and (select completed_at from service_tasks where id = '7a000000-0000-4000-8000-000000000001') is not null);
select rls_test.denied('Reinigung kann keine Aufgabe stornieren', $$
  update service_tasks set status = 'cancelled' where id = '7a000000-0000-4000-8000-000000000001' $$);
select rls_test.denied('Reinigung kann keine Aufgaben anlegen', $$
  insert into service_tasks (organization_id, property_id, title)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'Selbst erfunden') $$);
select rls_test.ok('Reinigung kann fremde Aufgaben nicht ändern', rls_test.affected($$
  update service_tasks set status = 'completed' where id = '7a000000-0000-4000-8000-000000000002' $$) = 0);
select rls_test.ok('Reinigung kann ein Foto zu ihrer Aufgabe hochladen (Storage)', rls_test.affected($$
  insert into storage.objects (bucket_id, name, owner_id)
  values ('husora-property-photos',
          'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/photos/bett.jpg',
          'aaaaaaaa-0000-4000-8000-000000000004') $$) = 1);
select rls_test.denied('Reinigung kann nicht in ein Haus ohne Aufgabe hochladen (Storage)', $$
  insert into storage.objects (bucket_id, name)
  values ('husora-property-photos',
          'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000002/photos/x.jpg') $$);
reset role;

\echo
\echo '=== Betrachter (betrachter@husora.test · viewer) ==='
select rls_test.login('betrachter@husora.test');
select rls_test.ok('Viewer sieht alle Häuser der Organisation (inkl. der oben angelegten Teststuga)', (select count(*) from properties) = 3);
select rls_test.ok('Viewer kann nichts ändern', rls_test.affected($$ update properties set name = 'x' $$) = 0);
select rls_test.denied('Viewer kann nichts anlegen', $$
  insert into service_tasks (organization_id, property_id, title)
  values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'x') $$);
select rls_test.denied('Viewer kann nichts hochladen (Storage)', $$
  insert into storage.objects (bucket_id, name)
  values ('husora-documents',
          'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/documents/x.pdf') $$);
reset role;

\echo
\echo '=== Fremde Organisation (fremd@husora.test) ==='
select rls_test.login('fremd@husora.test');
select rls_test.ok('Fremd-Admin sieht nur die eigene Organisation',
  (select count(*) from organizations) = 1 and (select name from organizations) = 'Fremde Ferienhaus GmbH');
select rls_test.ok('Fremd-Admin sieht kein Husora-Haus', (select count(*) from properties) = 1);
select rls_test.ok('Fremd-Admin sieht keine Husora-Buchungen', (select count(*) from bookings) = 1);
select rls_test.ok('Fremd-Admin sieht keine Husora-Partner', (select count(*) from service_partners) = 1);
select rls_test.ok('Fremd-Admin sieht keine Husora-Aufträge, Reparaturen, Rechnungen',
  (select count(*) from service_orders) = 0 and (select count(*) from repairs) = 0 and (select count(*) from invoices) = 0);
select rls_test.ok('Fremd-Admin sieht keine Husora-Vorlagen und -Kontrollen',
  (select count(*) from inspection_templates) = 0 and (select count(*) from inspection_items) = 0);
select rls_test.ok('Fremd-Admin sieht keine Husora-Dokumente und -Fotos',
  (select count(*) from documents) = 0 and (select count(*) from photos) = 0);
select rls_test.ok('Fremd-Admin sieht kein Husora-Audit-Log',
  not exists (select 1 from audit_logs where organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select rls_test.ok('Fremd-Admin sieht nur das eigene Profil', (select count(*) from users) = 1);
select rls_test.ok('Fremd-Admin kann Husora-Häuser nicht ändern', rls_test.affected($$ update properties set name = 'x'
  where organization_id = 'cccccccc-0000-4000-8000-000000000001' $$) = 0);
select rls_test.denied('Fremd-Admin kann sich nicht in die Husora-Organisation eintragen', $$
  insert into organization_members (organization_id, user_id, role)
  values ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000006', 'admin') $$);
select rls_test.ok('Fremd-Admin sieht keine Husora-Dateien (Storage)', (select count(*) from storage.objects
  where name like 'organization/cccccccc-0000-4000-8000-000000000001/%') = 0);
select rls_test.denied('Fremd-Admin kann nicht in Husora-Pfade hochladen (Storage)', $$
  insert into storage.objects (bucket_id, name)
  values ('husora-documents', 'organization/cccccccc-0000-4000-8000-000000000001/documents/x.pdf') $$);
select rls_test.ok('Fremd-Admin bekommt keine Husora-Partner im Ranking',
  (select count(*) from match_service_partners('dddddddd-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000001')) = 0);
reset role;

\echo
\echo '=== Eigentümer liest Datei seines Hauses (Storage) ==='
select rls_test.login('eigentuemer@husora.test');
select rls_test.ok('Eigentümer sieht das Foto seines Hauses', (select count(*) from storage.objects
  where name like 'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/%') = 1);
reset role;

\echo
\echo '=== Super-Admin (support@husora.test) ==='
select rls_test.login('support@husora.test');
select rls_test.ok('Super-Admin sieht alle Organisationen', (select count(*) from organizations) = 2);
select rls_test.ok('Super-Admin sieht alle Häuser', (select count(*) from properties) = 4);
reset role;

\echo
\echo '=== Nicht angemeldet (anon) ==='
select rls_test.login_anon();
select rls_test.denied('anon darf keine Tabellen lesen', $$ select count(*) from properties $$);
select rls_test.denied('anon darf keine Buchungen lesen', $$ select count(*) from bookings $$);
select rls_test.ok('anon sieht keine privaten Dateien', (select count(*) from storage.objects where bucket_id <> 'husora-public') = 0);
reset role;

\echo
\echo '=== Webhooks (service_role) ==='
select set_config('request.jwt.claims', '{"role": "service_role"}', true);
set local role service_role;
select rls_test.ok('Webhook wird gespeichert',
  (select not is_duplicate from webhook_receive('booking', 'booking_com', 'evt-0001', '{"reservation": "4711"}'::jsonb, true)));
select rls_test.ok('Gleiche Zustellung wird als Duplikat erkannt (idempotent)',
  (select is_duplicate from webhook_receive('booking', 'booking_com', 'evt-0001', '{"reservation": "4711"}'::jsonb, true)));
select rls_test.denied('Webhook mit ungültiger Signatur wird abgelehnt', $$
  select * from webhook_receive('booking', 'booking_com', 'evt-0002', '{}'::jsonb, false) $$);
select rls_test.ok('Ereignis kann zur Verarbeitung gesperrt werden', (select count(*) from webhook_claim(10)) = 1);
select webhook_complete((select id from webhook_events where event_id = 'evt-0001'), false, 'Testfehler');
select rls_test.ok('Fehlgeschlagenes Ereignis wird mit Backoff erneut eingeplant',
  (select status = 'failed' and next_attempt_at > now() from webhook_events where event_id = 'evt-0001'));
select rls_test.ok('Externe Buchung wird idempotent übernommen',
  upsert_external_booking('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002', 'airbnb', 'HM-NEU-1',
    date_trunc('day', now()) + interval '40 days', date_trunc('day', now()) + interval '45 days')
  = upsert_external_booking('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002', 'airbnb', 'HM-NEU-1',
    date_trunc('day', now()) + interval '40 days', date_trunc('day', now()) + interval '46 days'));
reset role;

\echo
\echo '=== Alle RLS-Tests bestanden ==='
rollback;
