-- =============================================================================
-- HUSORA · Beta Release (Spec „Beta Release & App Distribution“ §7, §8, §9, §10, §19, §23–§26)
-- =============================================================================
-- Testnutzer: rel_owner_a, rel_owner_b, rel_member_a (viewer in A), rel_partner_a, rel_partner_b, rel_admin (Super-Admin), rel_new
-- Teil 1: Multi-Tenant-Matrix (SELECT/INSERT/UPDATE/DELETE, Storage Upload/Download/Delete, Aufträge, Partnerzugriff, Hausmitglieder)
-- Teil 2: Beta-Release-Funktionen (Umgebung, Version, Rollen, Einladungscodes, Sperre, Admin-Übersicht, Löschung)
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/beta_release_test.sql
\set QUIET on
begin;
create schema rel_test;
grant usage on schema rel_test to anon, authenticated, service_role;
create table rel_test.vars (k text primary key, v text);
grant all on rel_test.vars to authenticated, service_role;
create function rel_test.login(p_email text, p_aal text default 'aal1') returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email, 'aal', p_aal)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function rel_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'RELEASE-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'PASS – %', p_label;
end $$;
create function rel_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'PASS – % (blockiert: %)', p_label, left(sqlerrm, 90); return; end;
  raise exception 'RELEASE-TEST FEHLGESCHLAGEN – % (wurde NICHT blockiert)', p_label;
end $$;
create function rel_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function rel_test.set(k text, v text) returns void language sql as $$ insert into rel_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function rel_test.get(k text) returns text language sql as $$ select v from rel_test.vars where vars.k = get.k $$;
-- Löschen wie die Storage-API (die setzt storage.allow_delete_query; RLS gilt weiter)
create function rel_test.storage_delete(p_like text) returns integer language plpgsql as $$
declare v integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects where name like p_like; get diagnostics v = row_count;
  perform set_config('storage.allow_delete_query', 'false', true);
  return v;
end $$;
grant execute on all functions in schema rel_test to anon, authenticated, service_role;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(), '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('rel_owner_a@rel.test', 'Anna'), ('rel_owner_b@rel.test', 'Bert'), ('rel_member_a@rel.test', 'Mia'), ('rel_partner_a@rel.test', 'Pia'),
             ('rel_partner_b@rel.test', 'Pit'), ('rel_admin@rel.test', 'Adam'), ('rel_new@rel.test', 'Neo'), ('rel_new2@rel.test', 'Nina')) v(e, f);
update users set is_super_admin = true where email = 'rel_admin@rel.test';
update app_config set value = value || '{"require_admin_mfa": true}' where key = 'security';

insert into organizations (id, name, org_type) values ('a1a10000-0000-4000-8000-00000000000a', 'REL Tenant A', 'homeowner'), ('b1b10000-0000-4000-8000-00000000000b', 'REL Tenant B', 'homeowner');
insert into organization_members (organization_id, user_id, role, status)
select 'a1a10000-0000-4000-8000-00000000000a'::uuid, id, 'admin', 'active' from users where email = 'rel_owner_a@rel.test'
union all select 'a1a10000-0000-4000-8000-00000000000a'::uuid, id, 'viewer', 'active' from users where email = 'rel_member_a@rel.test'
union all select 'b1b10000-0000-4000-8000-00000000000b'::uuid, id, 'admin', 'active' from users where email = 'rel_owner_b@rel.test';
insert into subscriptions (organization_id, plan_id, status) values ('a1a10000-0000-4000-8000-00000000000a', 'pro', 'active'), ('b1b10000-0000-4000-8000-00000000000b', 'pro', 'active')
  on conflict (organization_id) do update set plan_id = 'pro', status = 'active';
insert into properties (id, organization_id, name, street, city) values
  ('a1a11111-0000-4000-8000-00000000000a', 'a1a10000-0000-4000-8000-00000000000a', 'REL Haus A', 'Weg 1', 'Sunne'),
  ('b1b11111-0000-4000-8000-00000000000b', 'b1b10000-0000-4000-8000-00000000000b', 'REL Haus B', 'Weg 2', 'Arvika');
insert into service_tasks (id, organization_id, property_id, title) values
  ('a1a14444-0000-4000-8000-00000000000a', 'a1a10000-0000-4000-8000-00000000000a', 'a1a11111-0000-4000-8000-00000000000a', 'REL Aufgabe A'),
  ('b1b14444-0000-4000-8000-00000000000b', 'b1b10000-0000-4000-8000-00000000000b', 'b1b11111-0000-4000-8000-00000000000b', 'REL Aufgabe B');
insert into storage.objects (bucket_id, name) values
  ('husora-property-photos', 'organization/b1b10000-0000-4000-8000-00000000000b/property/b1b11111-0000-4000-8000-00000000000b/photos/b.jpg'),
  ('husora-documents', 'organization/b1b10000-0000-4000-8000-00000000000b/property/b1b11111-0000-4000-8000-00000000000b/documents/b.pdf'),
  ('husora-documents', 'organization/a1a10000-0000-4000-8000-00000000000a/property/a1a11111-0000-4000-8000-00000000000a/documents/a.pdf');
select rel_test.login('rel_partner_a@rel.test');
select rel_test.set('porg_a', public.create_partner_organization('{"name":"REL Partner A"}')::text);
reset role;
select rel_test.login('rel_partner_b@rel.test');
select rel_test.set('porg_b', public.create_partner_organization('{"name":"REL Partner B"}')::text);
reset role;
insert into service_partners (id, organization_id, company_name, partner_organization_id) values
  ('a1a12222-0000-4000-8000-00000000000a'::uuid, 'a1a10000-0000-4000-8000-00000000000a'::uuid, 'REL Partner A', rel_test.get('porg_a')::uuid),
  ('b1b12222-0000-4000-8000-00000000000b', 'b1b10000-0000-4000-8000-00000000000b', 'REL Partner B', rel_test.get('porg_b')::uuid);
insert into service_orders (id, organization_id, property_id, service_partner_id, title, status) values
  ('a1a13333-0000-4000-8000-00000000000a', 'a1a10000-0000-4000-8000-00000000000a', 'a1a11111-0000-4000-8000-00000000000a', 'a1a12222-0000-4000-8000-00000000000a', 'REL Auftrag A', 'offered'),
  ('b1b13333-0000-4000-8000-00000000000b', 'b1b10000-0000-4000-8000-00000000000b', 'b1b11111-0000-4000-8000-00000000000b', 'b1b12222-0000-4000-8000-00000000000b', 'REL Auftrag B', 'offered');
\set QUIET off

\echo '=== Teil 1 · Hausbesitzer A gegen Mandant B (SELECT/INSERT/UPDATE/DELETE) ==='
select rel_test.login('rel_owner_a@rel.test');
select rel_test.ok('SELECT: A sieht weder Haus, Aufgabe noch Auftrag von B',
  (select count(*) from properties where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from service_tasks where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from service_orders where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0);
select rel_test.denied('INSERT: A legt kein Haus in B an', $$
  insert into properties (organization_id, name) values ('b1b10000-0000-4000-8000-00000000000b', 'Eingeschmuggelt') $$);
select rel_test.denied('INSERT: A legt keine Aufgabe in B an', $$
  insert into service_tasks (organization_id, property_id, title) values ('b1b10000-0000-4000-8000-00000000000b', 'b1b11111-0000-4000-8000-00000000000b', 'x') $$);
select rel_test.ok('UPDATE: A ändert nichts in B', rel_test.affected($$ update properties set name = 'x' where organization_id = 'b1b10000-0000-4000-8000-00000000000b' $$) = 0);
select rel_test.ok('DELETE: A löscht nichts in B', rel_test.affected($$ delete from service_tasks where organization_id = 'b1b10000-0000-4000-8000-00000000000b' $$) = 0);
select rel_test.ok('Storage Download: A sieht keine Dateien von B',
  (select count(*) from storage.objects where name like 'organization/b1b10000-0000-4000-8000-00000000000b/%') = 0);
select rel_test.denied('Storage Upload: A lädt nicht in Pfade von B hoch', $$
  insert into storage.objects (bucket_id, name) values ('husora-documents', 'organization/b1b10000-0000-4000-8000-00000000000b/property/b1b11111-0000-4000-8000-00000000000b/documents/x.pdf') $$);
select rel_test.ok('Storage Update: A überschreibt keine Datei von B', rel_test.affected($$
  update storage.objects set metadata = '{"x":1}' where name like 'organization/b1b10000-0000-4000-8000-00000000000b/%' $$) = 0);
select rel_test.ok('Storage Delete: A löscht keine Datei von B', rel_test.storage_delete('organization/b1b10000-0000-4000-8000-00000000000b/%') = 0);
select rel_test.ok('Storage: A sieht die eigene Datei', (select count(*) from storage.objects where name like 'organization/a1a10000-0000-4000-8000-00000000000a/%') = 1);
select rel_test.ok('Storage Upload: A lädt in das eigene Haus hoch', rel_test.affected($$
  insert into storage.objects (bucket_id, name) values ('husora-property-photos', 'organization/a1a10000-0000-4000-8000-00000000000a/property/a1a11111-0000-4000-8000-00000000000a/photos/a.jpg') $$) = 1);
select rel_test.ok('Storage Delete: A löscht die eigene Datei', rel_test.storage_delete('organization/a1a10000-0000-4000-8000-00000000000a/property/a1a11111-0000-4000-8000-00000000000a/photos/a.jpg') = 1);
reset role;

\echo '=== Teil 1 · Hausmitglied (viewer) in A ==='
select rel_test.login('rel_member_a@rel.test');
select rel_test.ok('Mitglied liest Haus und Aufgabe von A', (select count(*) from properties where organization_id = 'a1a10000-0000-4000-8000-00000000000a') = 1
  and (select count(*) from service_tasks where id = 'a1a14444-0000-4000-8000-00000000000a') = 1);
select rel_test.ok('Mitglied sieht nichts von B', (select count(*) from properties where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0);
select rel_test.ok('Mitglied (viewer) ändert und löscht nichts', rel_test.affected($$ update properties set name = 'x' $$) = 0
  and rel_test.affected($$ delete from service_tasks $$) = 0);
select rel_test.denied('Mitglied (viewer) lädt nichts hoch', $$
  insert into storage.objects (bucket_id, name) values ('husora-documents', 'organization/a1a10000-0000-4000-8000-00000000000a/property/a1a11111-0000-4000-8000-00000000000a/documents/v.pdf') $$);
select rel_test.ok('Mitglied (viewer) löscht keine Datei', rel_test.storage_delete('organization/a1a10000-0000-4000-8000-00000000000a/%') = 0);
reset role;

\echo '=== Teil 1 · Servicepartner A ==='
select rel_test.login('rel_partner_a@rel.test');
select rel_test.ok('Partner A sieht den eigenen Auftrag', (select count(*) from service_orders where id = 'a1a13333-0000-4000-8000-00000000000a') = 1);
select rel_test.ok('Partner A sieht keine Aufträge von Partner B', (select count(*) from service_orders where id = 'b1b13333-0000-4000-8000-00000000000b') = 0);
select rel_test.ok('Partner A sieht kein Haus von Kunde B', (select count(*) from properties where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0);
select rel_test.ok('Partner A sieht keine Dokumente/Fotos von Kunde B',
  (select count(*) from storage.objects where name like 'organization/b1b10000-0000-4000-8000-00000000000b/%') = 0
  and (select count(*) from documents where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0
  and (select count(*) from photos where organization_id = 'b1b10000-0000-4000-8000-00000000000b') = 0);
select rel_test.ok('Partner A ändert keinen Auftrag von B', rel_test.affected($$ update service_orders set title = 'x' where id = 'b1b13333-0000-4000-8000-00000000000b' $$) = 0);
select rel_test.ok('Partner A löscht keine Aufträge', rel_test.affected($$ delete from service_orders $$) = 0);
select rel_test.denied('Partner A lädt nicht in Kunde B hoch', $$
  insert into storage.objects (bucket_id, name) values ('husora-property-photos', 'organization/b1b10000-0000-4000-8000-00000000000b/property/b1b11111-0000-4000-8000-00000000000b/photos/p.jpg') $$);
reset role;

\echo '=== Teil 2 · Umgebung, Version, Rollen ==='
select rel_test.ok('Umgebungskennung vorhanden (Standard beta)', (select value ->> 'name' from app_config where key = 'environment') in ('beta', 'production'));
select rel_test.login('rel_admin@rel.test', 'aal2');
select rel_test.ok('Auch Super-Admin (aal2) kann die Umgebung nicht umstellen', rel_test.affected($$ update app_config set value = '{"name":"production"}' where key = 'environment' $$) = 0);
select rel_test.ok('Super-Admin (aal2) kann Release-Konfiguration ändern', rel_test.affected($$ update app_config set value = value || '{"android_beta_url":"https://play.google.com/apps/testing/com.husora.app"}' where key = 'release' $$) = 1);
reset role;
select rel_test.login('rel_owner_a@rel.test');
select rel_test.ok('report_app_session speichert Version/Build/Plattform/Umgebung',
  (public.report_app_session('1.0.0-beta.3', '3', 'android', 'beta') ->> 'environment') is not null);
reset role;
select rel_test.ok('… und steht am Profil', (select last_app_version = '1.0.0-beta.3' and last_app_build = '3' and app_platform = 'android' and last_environment = 'beta' and last_seen_at is not null
  from users where email = 'rel_owner_a@rel.test'));
select rel_test.login('rel_owner_a@rel.test');
select rel_test.ok('Ungültige Plattform/Umgebung wird verworfen',
  (public.report_app_session('1.0.0', '4', 'Android<script>', 'hacker') is not null));
reset role;
select rel_test.ok('… alte Werte bleiben', (select app_platform = 'android' and last_environment = 'beta' from users where email = 'rel_owner_a@rel.test'));
select rel_test.login('rel_owner_a@rel.test');
select rel_test.ok('Nutzer kann Tester-/App-Felder nicht selbst setzen', rel_test.affected($$
  update users set tester_group = 'internal', last_app_version = 'fake', last_seen_at = now() - interval '9 days', is_beta_user = true where email = 'rel_owner_a@rel.test' $$) <= 1);
reset role;
select rel_test.ok('… Felder unverändert', (select tester_group is null and last_app_version = '1.0.0' and not is_beta_user from users where email = 'rel_owner_a@rel.test'));
select rel_test.login('rel_owner_a@rel.test');
select rel_test.ok('Rolle Hausbesitzer erkannt', (public.my_beta_status() -> 'roles' ->> 'owner')::boolean and not (public.my_beta_status() -> 'roles' ->> 'partner')::boolean);
reset role;
select rel_test.login('rel_partner_a@rel.test');
select rel_test.ok('Rolle Servicepartner erkannt', (public.my_beta_status() -> 'roles' ->> 'partner')::boolean and not (public.my_beta_status() -> 'roles' ->> 'owner')::boolean
  and not (public.my_beta_status() -> 'roles' ->> 'admin')::boolean);
reset role;
select rel_test.login('rel_admin@rel.test');
select rel_test.ok('Rolle Admin erkannt', (public.my_beta_status() -> 'roles' ->> 'admin')::boolean);
reset role;
set local role anon;
select rel_test.denied('anon: report_app_session gesperrt', $$ select public.report_app_session('1', '1', 'ios', 'beta') $$);
select rel_test.denied('anon: Einladung einlösen gesperrt', $$ select public.redeem_beta_invite('HUSORA-BETA-2026') $$);
reset role;

\echo '=== Teil 2 · Einladungscodes ==='
select rel_test.login('rel_admin@rel.test', 'aal1');
select rel_test.denied('Admin ohne MFA (aal1) legt keine Codes an', $$ select public.beta_invite_create('x') $$);
reset role;
select rel_test.login('rel_owner_b@rel.test', 'aal2');
select rel_test.denied('Normaler Nutzer legt keine Codes an', $$ select public.beta_invite_create('x') $$);
select rel_test.ok('Normaler Nutzer sieht keine Codes', (select count(*) from beta_invites) = 0);
reset role;
select rel_test.login('rel_admin@rel.test', 'aal2');
select rel_test.set('code_shared', public.beta_invite_create('Spec-Beispiel', 'homeowner', 2, 30, 'husora-beta-2026') ->> 'code');
select rel_test.set('code_partner', public.beta_invite_create('Partner', 'service_partner', 1, 30) ->> 'code');
select rel_test.ok('Code normalisiert und zufällige Codes im Format HUSORA-XXXX-XXXX-XXXX',
  rel_test.get('code_shared') = 'HUSORA-BETA-2026' and rel_test.get('code_partner') ~ '^HUSORA-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$');
select rel_test.denied('Doppelter Code wird abgelehnt', $$ select public.beta_invite_create('x', null, 1, 30, 'HUSORA-BETA-2026') $$);
reset role;
select rel_test.ok('Klartext wird nicht gespeichert', not exists (select 1 from beta_invites where code_hash = 'HUSORA-BETA-2026' or code_hint = 'HUSORA-BETA-2026'));
select rel_test.login('rel_admin@rel.test', 'aal2');
select rel_test.denied('Spalte code_hash ist für Clients nicht lesbar (auch nicht für Admins)', $$ select code_hash from public.beta_invites $$);
reset role;

update app_config set value = value || '{"invite_required": true}' where key = 'release';
select rel_test.login('rel_new@rel.test');
select rel_test.ok('Einladungspflicht: Status meldet invite_ok = false', not (public.my_beta_status() ->> 'invite_ok')::boolean and (public.my_beta_status() ->> 'invite_required')::boolean);
select rel_test.denied('Ohne Code: keine Hausbesitzer-Organisation (serverseitig)', $$ select public.ensure_my_organization('Neo Häuser') $$);
select rel_test.denied('Ohne Code: keine Servicepartner-Organisation (serverseitig)', $$ select public.create_partner_organization('{"name":"Neo Service"}') $$);
select rel_test.ok('Falscher Code wird abgelehnt (ohne Ausnahme, Versuch zählt)', (public.redeem_beta_invite('HUSORA-FALSCH-0000') ->> 'ok')::boolean = false);
select rel_test.ok('Richtiger Code (Kleinschreibung, Leerzeichen) wird angenommen', (public.redeem_beta_invite(' husora-beta-2026 ') ->> 'ok')::boolean);
select rel_test.ok('Erneutes Einlösen durch denselben Nutzer verbraucht keinen weiteren Platz', (public.redeem_beta_invite('HUSORA-BETA-2026') ->> 'ok')::boolean);
select rel_test.ok('Mit Code: Organisation kann angelegt werden', public.ensure_my_organization('Neo Häuser') is not null);
reset role;
select rel_test.ok('Tester markiert: is_beta_user, tester_group, beta_started_at, Code-Bezug',
  (select is_beta_user and tester_group = 'homeowner' and beta_started_at is not null and beta_invite_id is not null from users where email = 'rel_new@rel.test'));
select rel_test.ok('Nutzungszähler = 1', (select used_count from beta_invites where code_hint = '…2026') = 1);
select rel_test.login('rel_new2@rel.test');
select rel_test.ok('Zweiter Nutzer löst gemeinsamen Code ein (max 2)', (public.redeem_beta_invite('HUSORA-BETA-2026') ->> 'ok')::boolean);
reset role;
update beta_invites set max_uses = 2, used_count = 2 where code_hint = '…2026';
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'rel_new3@rel.test', '', now(), '{"provider":"email"}', now(), now());
select rel_test.login('rel_new3@rel.test');
select rel_test.ok('Aufgebrauchter Code wird abgelehnt', (public.redeem_beta_invite('HUSORA-BETA-2026') ->> 'ok')::boolean = false);
select rel_test.ok('Rate-Limit: nach 10 Fehlversuchen pro Stunde gesperrt', (
  select count(*) from generate_series(1, 9) g where (public.redeem_beta_invite('HUSORA-NOPE-' || lpad(g::text, 4, '0')) ->> 'ok')::boolean = false) = 9);
select rel_test.denied('… 11. Versuch blockiert', $$ select public.redeem_beta_invite('HUSORA-BETA-2026') $$);
reset role;
select rel_test.login('rel_owner_b@rel.test');
select rel_test.ok('Bestehende Nutzer mit Organisation arbeiten trotz Einladungspflicht weiter', (public.my_beta_status() ->> 'invite_ok')::boolean);
reset role;
update app_config set value = value || '{"invite_required": false}' where key = 'release';

\echo '=== Teil 2 · Admin-Übersicht (Spec §23) ==='
select rel_test.login('rel_owner_a@rel.test', 'aal2');
select rel_test.denied('Normaler Nutzer: keine Tester-Übersicht', $$ select public.beta_testers_overview() $$);
reset role;
select rel_test.login('rel_admin@rel.test', 'aal1');
select rel_test.denied('Admin ohne MFA: keine Tester-Übersicht', $$ select public.beta_testers_overview() $$);
reset role;
select rel_test.login('rel_admin@rel.test', 'aal2');
select rel_test.set('ov', public.beta_testers_overview()::text);
select rel_test.ok('Übersicht: Anzahl, aktiv, Gruppen, Plattformen, Versionen, Einladungen', (rel_test.get('ov')::jsonb -> 'totals' ->> 'testers')::int >= 2
  and (rel_test.get('ov')::jsonb -> 'totals') ? 'active_7d' and (rel_test.get('ov')::jsonb -> 'totals' -> 'by_group') ? 'homeowner'
  and jsonb_array_length(rel_test.get('ov')::jsonb -> 'invites') >= 2);
select rel_test.ok('Übersicht enthält keine E-Mail-Adressen oder Namen', rel_test.get('ov') !~ '@rel\.test' and rel_test.get('ov') !~ '"(email|first_name|last_name|name)"');
select rel_test.ok('Admin markiert internen Tester per E-Mail', (public.admin_set_beta_tester('rel_member_a@rel.test', true, 'internal') ->> 'ok')::boolean);
select rel_test.denied('Ungültige Testgruppe abgelehnt', $$ select public.admin_set_beta_tester('rel_member_a@rel.test', true, 'vip') $$);
select public.beta_invite_set_active((select id from beta_invites where code_hint = '…2026'), false);
reset role;
select rel_test.ok('Interner Tester gesetzt', (select is_beta_user and tester_group = 'internal' from users where email = 'rel_member_a@rel.test'));
select rel_test.ok('Code deaktiviert', not (select active from beta_invites where code_hint = '…2026'));
select rel_test.ok('Admin-Aktionen im Sicherheits-Audit-Log', (select count(*) from security_audit_log where entity_type in ('beta_invite', 'beta_tester')) >= 4);

\echo '=== Teil 2 · Konto löschen (Spec §19) mit Beta-Daten ==='
select rel_test.login('rel_new2@rel.test');
select rel_test.ok('Löschvorschau verfügbar', public.my_deletion_preview() is not null);
reset role;
delete from public.users where email = 'rel_new2@rel.test';
select rel_test.ok('Löschen entfernt Einlösung, Code bleibt erhalten', not exists (select 1 from beta_invite_redemptions r left join users u on u.id = r.user_id where u.id is null)
  and exists (select 1 from beta_invites where code_hint = '…2026'));

\echo
\echo 'Beta-Release-Tests: alle Prüfungen bestanden.'
rollback;
