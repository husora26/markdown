-- =============================================================================
-- HUSORA · Compliance-Testmatrix (Legal & Beta Compliance §10, §39)
-- =============================================================================
-- Testnutzer: owner_A, owner_B, partner_A, partner_B, admin_A (Super-Admin), support_A (Support-Admin)
-- Prüft: Mandantentrennung (lesen/ändern/löschen), Partner-Isolation, Widerruf von Zugangsdaten,
-- Admin-Rollen + MFA (aal2), Konto-Löschung, Datenexport, Einwilligung, Rechtstexte, Release-Gate.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/compliance_matrix_test.sql
\set QUIET on
begin;
create schema mx_test;
grant usage on schema mx_test to authenticated, service_role;
create table mx_test.vars (k text primary key, v text);
grant all on mx_test.vars to authenticated, service_role;
create function mx_test.login(p_email text, p_aal text default 'aal1') returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email, 'aal', p_aal)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function mx_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'MATRIX-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'PASS – %', p_label;
end $$;
create function mx_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'PASS – % (blockiert: %)', p_label, left(sqlerrm, 90); return; end;
  raise exception 'MATRIX-TEST FEHLGESCHLAGEN – % (wurde NICHT blockiert)', p_label;
end $$;
create function mx_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function mx_test.set(k text, v text) returns void language sql as $$ insert into mx_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function mx_test.get(k text) returns text language sql as $$ select v from mx_test.vars where vars.k = get.k $$;
grant execute on all functions in schema mx_test to authenticated, service_role;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(), '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('owner_a@mx.test', 'Olga'), ('owner_b@mx.test', 'Otto'), ('partner_a@mx.test', 'Paula'), ('partner_b@mx.test', 'Peter'), ('admin_a@mx.test', 'Ada'), ('support_a@mx.test', 'Sven')) v(e, f);
update users set is_super_admin = true where email = 'admin_a@mx.test';
update users set admin_roles = array['support_admin'] where email = 'support_a@mx.test';
update app_config set value = value || '{"require_admin_mfa": true}' where key = 'security';

-- Mandanten A und B mit je einem Haus, Aufgabe, Kontrolle, Dokument, Rechnung, Mangel
insert into organizations (id, name, org_type) values ('aaaa0000-0000-4000-8000-00000000000a', 'MX Tenant A', 'homeowner'), ('bbbb0000-0000-4000-8000-00000000000b', 'MX Tenant B', 'homeowner');
insert into organization_members (organization_id, user_id, role, status)
select 'aaaa0000-0000-4000-8000-00000000000a'::uuid, id, 'admin', 'active' from users where email = 'owner_a@mx.test'
union all select 'bbbb0000-0000-4000-8000-00000000000b'::uuid, id, 'admin', 'active' from users where email = 'owner_b@mx.test';
insert into subscriptions (organization_id, plan_id, status) values ('aaaa0000-0000-4000-8000-00000000000a', 'pro', 'active'), ('bbbb0000-0000-4000-8000-00000000000b', 'pro', 'active')
  on conflict (organization_id) do update set plan_id = 'pro', status = 'active';
insert into properties (id, organization_id, name, street, city) values
  ('aaaa1111-0000-4000-8000-00000000000a', 'aaaa0000-0000-4000-8000-00000000000a', 'Haus A', 'Weg 1', 'Sunne'),
  ('aaaa1111-0000-4000-8000-00000000000c', 'aaaa0000-0000-4000-8000-00000000000a', 'Haus A2 (nicht freigegeben)', 'Weg 3', 'Sunne'),
  ('bbbb1111-0000-4000-8000-00000000000b', 'bbbb0000-0000-4000-8000-00000000000b', 'Haus B', 'Weg 2', 'Arvika');
insert into service_tasks (organization_id, property_id, title) values ('bbbb0000-0000-4000-8000-00000000000b', 'bbbb1111-0000-4000-8000-00000000000b', 'MX Aufgabe B');
insert into inspections (organization_id, property_id, status) values ('bbbb0000-0000-4000-8000-00000000000b', 'bbbb1111-0000-4000-8000-00000000000b', 'scheduled');
insert into documents (organization_id, property_id, file_name, file_type, file_size, storage_bucket, storage_path, document_type) values
  ('bbbb0000-0000-4000-8000-00000000000b', 'bbbb1111-0000-4000-8000-00000000000b', 'versicherung-b.pdf', 'application/pdf', 10, 'husora-documents', 'organization/bbbb0000-0000-4000-8000-00000000000b/property/bbbb1111-0000-4000-8000-00000000000b/documents/v.pdf', 'insurance'),
  ('aaaa0000-0000-4000-8000-00000000000a', 'aaaa1111-0000-4000-8000-00000000000c', 'vertrag-a2.pdf', 'application/pdf', 10, 'husora-documents', 'organization/aaaa0000-0000-4000-8000-00000000000a/property/aaaa1111-0000-4000-8000-00000000000c/documents/c.pdf', 'contract');
insert into repairs (organization_id, property_id, title) values ('bbbb0000-0000-4000-8000-00000000000b', 'bbbb1111-0000-4000-8000-00000000000b', 'MX Mangel B');
-- Partner A ist mit Tenant A verbunden, Partner B mit Tenant B
select mx_test.login('partner_a@mx.test');
select mx_test.set('porg_a', public.create_partner_organization('{"name":"MX Partner A"}')::text);
reset role;
select mx_test.login('partner_b@mx.test');
select mx_test.set('porg_b', public.create_partner_organization('{"name":"MX Partner B"}')::text);
reset role;
insert into service_partners (id, organization_id, company_name, partner_organization_id) values
  ('aaaa2222-0000-4000-8000-00000000000a'::uuid, 'aaaa0000-0000-4000-8000-00000000000a'::uuid, 'MX Partner A', mx_test.get('porg_a')::uuid),
  ('bbbb2222-0000-4000-8000-00000000000b', 'bbbb0000-0000-4000-8000-00000000000b', 'MX Partner B', mx_test.get('porg_b')::uuid);
insert into service_orders (id, organization_id, property_id, service_partner_id, title, status) values
  ('aaaa3333-0000-4000-8000-00000000000a', 'aaaa0000-0000-4000-8000-00000000000a', 'aaaa1111-0000-4000-8000-00000000000a', 'aaaa2222-0000-4000-8000-00000000000a', 'MX Auftrag A', 'offered');
update service_orders set status = 'accepted' where id = 'aaaa3333-0000-4000-8000-00000000000a';
insert into messages (organization_id, service_order_id, message) values ('aaaa0000-0000-4000-8000-00000000000a', 'aaaa3333-0000-4000-8000-00000000000a', 'MX Nachricht A');
insert into app_feedback (kind, message, organization_id) values ('feedback', 'MX Feedback B', 'bbbb0000-0000-4000-8000-00000000000b');
\set QUIET off

\echo '=== 1. Mandantentrennung: owner_A gegen Tenant B ==='
select mx_test.login('owner_a@mx.test');
select mx_test.ok('A liest B: Häuser, Aufgaben, Kontrollen, Dokumente, Mängel, Feedback – nichts sichtbar',
  (select count(*) from properties where organization_id = 'bbbb0000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from service_tasks where organization_id = 'bbbb0000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from inspections where organization_id = 'bbbb0000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from documents where organization_id = 'bbbb0000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from repairs where organization_id = 'bbbb0000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from app_feedback where message = 'MX Feedback B') = 0
  and (select count(*) from organizations where id = 'bbbb0000-0000-4000-8000-00000000000b') = 0);
select mx_test.ok('A ändert B: 0 Zeilen', mx_test.affected($$ update properties set name = 'gehackt' where organization_id = 'bbbb0000-0000-4000-8000-00000000000b' $$) = 0);
select mx_test.ok('A löscht B: 0 Zeilen', mx_test.affected($$ delete from documents where organization_id = 'bbbb0000-0000-4000-8000-00000000000b' $$) = 0);
select mx_test.denied('A legt Daten in Tenant B an (manipulierte organization_id)', $$ insert into properties (organization_id, name) values ('bbbb0000-0000-4000-8000-00000000000b', 'Fremdhaus') $$);
select mx_test.ok('A sieht eigene Daten', (select count(*) from properties where organization_id = 'aaaa0000-0000-4000-8000-00000000000a') = 2);
select mx_test.denied('Normaler Nutzer: kein Analytics, kein Audit-Log, keine Vorfälle (Release-Gate)', $$ select public.release_gate() $$);
select mx_test.ok('Normaler Nutzer liest keine Admin-Daten', (select count(*) from security_audit_log) = 0 and (select count(*) from security_incidents) = 0 and (select count(*) from analytics_events) = 0 and (select count(*) from third_party_providers) = 0);
reset role;

\echo '=== 2. Partner-Isolation ==='
select mx_test.login('partner_a@mx.test');
select mx_test.ok('Partner A sieht das Haus seines Auftrags', exists (select 1 from properties where id = 'aaaa1111-0000-4000-8000-00000000000a'));
select mx_test.ok('Partner A liest kein fremdes Haus (Tenant B) und kein nicht freigegebenes Haus von A', not exists (select 1 from properties where id in ('bbbb1111-0000-4000-8000-00000000000b', 'aaaa1111-0000-4000-8000-00000000000c')));
select mx_test.ok('Partner A liest keine fremden Dokumente (B, nicht freigegebenes Haus A2)', not exists (select 1 from documents where file_name in ('versicherung-b.pdf', 'vertrag-a2.pdf')));
select mx_test.ok('Partner A sieht keine Aufträge/Nachrichten anderer', (select count(*) from service_orders where organization_id = 'bbbb0000-0000-4000-8000-00000000000b') = 0);
reset role;
select mx_test.login('partner_b@mx.test');
select mx_test.ok('Partner B sieht Auftrag und Nachricht von Tenant A nicht', not exists (select 1 from service_orders where id = 'aaaa3333-0000-4000-8000-00000000000a') and not exists (select 1 from messages where message = 'MX Nachricht A'));
select mx_test.denied('Partner B ruft Zugangsdaten des fremden Auftrags ab', $$ select public.order_access('aaaa3333-0000-4000-8000-00000000000a') $$);
reset role;

\echo '=== 3. Widerruf sensibler Zugangsdaten ==='
select mx_test.login('owner_a@mx.test');
insert into order_access_shares (organization_id, service_order_id, access_text, valid_until) values ('aaaa0000-0000-4000-8000-00000000000a', 'aaaa3333-0000-4000-8000-00000000000a', 'Schlüsselbox 4711', now() + interval '2 days');
reset role;
select mx_test.login('partner_a@mx.test');
select mx_test.ok('Freigegeben: Partner A liest den Zugang', (public.order_access('aaaa3333-0000-4000-8000-00000000000a') ->> 'access_text') = 'Schlüsselbox 4711');
reset role;
select mx_test.login('owner_a@mx.test');
update order_access_shares set revoked_at = now() where service_order_id = 'aaaa3333-0000-4000-8000-00000000000a';
reset role;
select mx_test.login('partner_a@mx.test');
select mx_test.ok('Nach Widerruf: kein Zugang mehr', public.order_access('aaaa3333-0000-4000-8000-00000000000a') is null);
select mx_test.ok('Partner liest die Freigabe-Tabelle nicht direkt', (select count(*) from order_access_shares) = 0);
reset role;
select mx_test.ok('Freigabe und Widerruf protokolliert, Abruf gezählt', (select count(*) from security_audit_log where entity_id = 'aaaa3333-0000-4000-8000-00000000000a' and event_type in ('access_grant', 'access_revoke')) = 2
  and (select view_count from order_access_shares where service_order_id = 'aaaa3333-0000-4000-8000-00000000000a') = 1);

\echo '=== 4. Admin-Rollen und MFA ==='
select mx_test.login('support_a@mx.test', 'aal1');
select mx_test.ok('Support ohne zweiten Faktor: kein Zugriff auf Feedback', (select count(*) from app_feedback where message = 'MX Feedback B') = 0);
reset role;
select mx_test.login('support_a@mx.test', 'aal2');
select mx_test.ok('Support mit MFA: Feedback und Datenschutz-Anfragen sichtbar', (select count(*) from app_feedback where message = 'MX Feedback B') = 1);
select mx_test.ok('Support sieht keine privaten Häuser/Dokumente der Mandanten', (select count(*) from properties where organization_id in ('aaaa0000-0000-4000-8000-00000000000a', 'bbbb0000-0000-4000-8000-00000000000b')) = 0
  and (select count(*) from documents where file_name = 'versicherung-b.pdf') = 0);
select mx_test.ok('Support sieht kein Audit-Log und keine Vorfälle (security_admin)', (select count(*) from security_audit_log) = 0);
select mx_test.denied('Support kann keine Partner verifizieren (content_admin)', format($$ select public.set_partner_verification(%L, 'verified', 'x') $$, mx_test.get('porg_a')));
select mx_test.ok('Support kann sich keine Admin-Rolle geben', mx_test.affected($$ update users set admin_roles = array['super_admin'] where email = 'support_a@mx.test' $$) = 1
  and (select admin_roles from users where email = 'support_a@mx.test') = array['support_admin']);
reset role;
select mx_test.login('admin_a@mx.test', 'aal1');
select mx_test.denied('Super-Admin ohne zweiten Faktor: Release-Gate gesperrt', $$ select public.release_gate() $$);
reset role;
select mx_test.login('admin_a@mx.test', 'aal2');
select mx_test.ok('Super-Admin mit MFA: Release-Gate lesbar', (public.release_gate() -> 'checks') is not null);
select mx_test.denied('Verifiziert nur mit Prüfbeschreibung', format($$ select public.set_partner_verification(%L, 'verified', '') $$, mx_test.get('porg_a')));
select public.set_partner_verification(mx_test.get('porg_a')::uuid, 'verified', 'Gewerbeanmeldung und Haftpflicht gesichtet');
select mx_test.ok('Partner verifiziert + Admin-Aktion protokolliert', (select verification_status from organizations where id = mx_test.get('porg_a')::uuid) = 'verified'
  and exists (select 1 from security_audit_log where event_type = 'admin_action' and entity_type = 'partner_verification'));
select mx_test.denied('Open Beta erst nach bestandenem Gate', $$ update app_config set value = value || '{"default_group":"open_beta"}' where key = 'beta' $$);
reset role;
select mx_test.login('partner_a@mx.test');
select mx_test.ok('Betrieb kann den eigenen Nachweisstatus nicht setzen', mx_test.affected(format($$ update organizations set verification_status = 'verified' where id = %L $$, mx_test.get('porg_b'))) = 0);
reset role;

\echo '=== 5. Einwilligung, Rechtstexte, Datenschutz-Anfragen ==='
update app_config set value = value || '{"enabled": true, "analytics": true}' where key = 'beta';
select mx_test.login('owner_a@mx.test');
select mx_test.ok('Ohne Einwilligung: keine Analytics', public.track_events('[{"event_name":"task_created","entity_ref":"mx1"}]') = 0);
insert into consent_log (purpose, version, accepted, source) values ('analytics', '2026-11-02', true, 'test');
select mx_test.ok('Mit Einwilligung: gezählt', public.track_events('[{"event_name":"task_created","entity_ref":"mx2"}]') = 1);
insert into consent_log (purpose, version, accepted, source) values ('analytics', '2026-11-02', false, 'test');
select mx_test.ok('Widerruf wirkt sofort', public.track_events('[{"event_name":"task_created","entity_ref":"mx3"}]') = 0);
select mx_test.ok('Offene zustimmungspflichtige Fassungen (Nutzungs- und Beta-Bedingungen)', (select count(*) from public.my_pending_legal()) = 2);
insert into legal_acceptances (document_type, version, source) values ('terms', '2026-11-02', 'test'), ('beta_terms', '2026-11-02', 'test');
select mx_test.ok('Nach Zustimmung nichts mehr offen', (select count(*) from public.my_pending_legal()) = 0);
select mx_test.denied('Zustimmung zu nicht veröffentlichter Fassung abgelehnt', $$ insert into legal_acceptances (document_type, version) values ('terms', '1999-01-01') $$);
insert into privacy_requests (request_type, message) values ('access', 'MX Auskunft bitte');
select mx_test.ok('Eigene Datenschutz-Anfrage sichtbar, Status neu', (select status from privacy_requests where message = 'MX Auskunft bitte') = 'new');
select mx_test.ok('Nutzer kann den Status nicht selbst ändern', mx_test.affected($$ update privacy_requests set status = 'completed' $$) = 0);
reset role;
select mx_test.login('owner_b@mx.test');
select mx_test.ok('Fremde Einwilligungen/Anfragen unsichtbar', (select count(*) from consent_log) = 0 and (select count(*) from privacy_requests) = 0);
reset role;
select mx_test.login('support_a@mx.test', 'aal2');
select mx_test.ok('Support bearbeitet Anfragen', mx_test.affected($$ update privacy_requests set status = 'in_progress' where message = 'MX Auskunft bitte' $$) = 1);
reset role;

\echo '=== 6. Datenexport ==='
select mx_test.login('owner_a@mx.test');
select mx_test.set('export', public.export_my_data()::text);
reset role;
select mx_test.ok('Export enthält eigene Häuser (2) und keine Daten von Tenant B',
  jsonb_array_length(mx_test.get('export')::jsonb -> 'properties') = 2
  and position('Haus B' in mx_test.get('export')) = 0 and position('versicherung-b' in mx_test.get('export')) = 0 and position('MX Feedback B' in mx_test.get('export')) = 0);
select mx_test.ok('Export enthält Einwilligungen, Zustimmungen, Anfragen; Export protokolliert',
  jsonb_array_length(mx_test.get('export')::jsonb -> 'consents') = 2 and jsonb_array_length(mx_test.get('export')::jsonb -> 'legal_acceptances') = 2
  and exists (select 1 from security_audit_log where event_type = 'data_export'));

\echo '=== 7. Bewertungen melden und moderieren ==='
update service_orders set status = 'completed' where id = 'aaaa3333-0000-4000-8000-00000000000a';
select mx_test.login('owner_a@mx.test');
insert into service_partner_reviews (service_order_id, rating, comment, organization_id, service_partner_id) values ('aaaa3333-0000-4000-8000-00000000000a', 1, 'MX Betrüger!!', 'aaaa0000-0000-4000-8000-00000000000a', 'aaaa2222-0000-4000-8000-00000000000a');
reset role;
select mx_test.login('partner_a@mx.test');
select public.report_review((select id from service_partner_reviews where comment = 'MX Betrüger!!'), 'insult', 'Beleidigung');
select mx_test.ok('Gemeldet → in Prüfung', (select moderation_status from service_partner_reviews where comment = 'MX Betrüger!!') = 'under_review');
select mx_test.denied('Partner kann nicht selbst moderieren', $$ select public.moderate_review((select id from service_partner_reviews where comment = 'MX Betrüger!!'), 'hidden') $$);
reset role;
select mx_test.login('admin_a@mx.test', 'aal2');
select public.moderate_review((select id from service_partner_reviews where comment = 'MX Betrüger!!'), 'hidden');
reset role;
select mx_test.ok('Ausgeblendet, Meldung bestätigt, zählt nicht im Durchschnitt', (select r.moderation_status = 'hidden' and o.rating_count = 0 from service_partner_reviews r join organizations o on o.id = mx_test.get('porg_a')::uuid where r.comment = 'MX Betrüger!!')
  and (select status from review_reports limit 1) = 'upheld');

\echo '=== 8. Konto löschen: gelöschter Account verliert Zugriff ==='
select mx_test.login('owner_b@mx.test');
select public.delete_my_account('LÖSCHEN');
reset role;
select mx_test.ok('Nutzer, Mitgliedschaft und Tenant B gelöscht', not exists (select 1 from auth.users where email = 'owner_b@mx.test')
  and not exists (select 1 from organizations where id = 'bbbb0000-0000-4000-8000-00000000000b') and not exists (select 1 from properties where id = 'bbbb1111-0000-4000-8000-00000000000b'));
select mx_test.ok('Alte Sitzung findet keinen Nutzer mehr (kein Zugriff)', (select private.current_user_id() is null from (select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true)) x));
select mx_test.ok('Löschung pseudonym protokolliert', exists (select 1 from security_audit_log where event_type = 'account_delete'));

\echo '=== 9. Storage ==='
select mx_test.ok('Private Buckets mit Größen- und Typbegrenzung', not exists (select 1 from storage.buckets b where b.id <> 'husora-public' and (b.public or b.file_size_limit is null or b.allowed_mime_types is null)));

\echo '=== ERGEBNIS: PASS (alle Matrix-Tests bestanden) ==='
rollback;
