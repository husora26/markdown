-- =============================================================================
-- HUSORA · Test Tarife für Servicepartner (Akzeptanztests 1–5, 7–17 der Spezifikation)
-- =============================================================================
-- Test 6 (parallele Requests) läuft über die REST-API: tests/e2e/partnerlimits.js
-- Voraussetzung: Migrationen + seed.sql. Läuft in einer Transaktion, wird zurückgerollt.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_plans_test.sql

\set QUIET on
begin;
create schema plan_test;
grant usage on schema plan_test to authenticated;
create table plan_test.vars (k text primary key, v text);
grant all on plan_test.vars to authenticated;

create function plan_test.login(p_email text, p_aal text default 'aal1') returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email, 'aal', p_aal)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function plan_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'TARIF-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
-- erwartet Ablehnung; optional mit Text, der in der Meldung vorkommen muss
create function plan_test.denied(p_label text, p_sql text, p_expect text default null) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if p_expect is not null and position(p_expect in sqlerrm) = 0 then
      raise exception 'TARIF-TEST FEHLGESCHLAGEN – % (falsche Meldung: %)', p_label, sqlerrm;
    end if;
    raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return;
  end;
  raise exception 'TARIF-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function plan_test.set(k text, v text) returns void language sql as $$ insert into plan_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function plan_test.get(k text) returns text language sql as $$ select v from plan_test.vars where vars.k = get.k $$;
create function plan_test.org() returns uuid language sql as $$ select v::uuid from plan_test.vars where k = 'org' $$;
-- n Kunden auf einmal anlegen (jede Zeile läuft durch die Limitprüfung)
create function plan_test.add_customers(p_n integer, p_prefix text default 'K') returns void language sql as $$
  insert into public.customers (organization_id, company_name) select plan_test.org(), p_prefix || ' ' || g from generate_series(1, p_n) g $$;
create function plan_test.add_properties(p_n integer) returns void language sql as $$
  insert into public.properties (organization_id, name, owner_customer_id)
  select plan_test.org(), 'Objekt ' || g, (select id from public.customers where organization_id = plan_test.org() order by created_at limit 1) from generate_series(1, p_n) g $$;
create function plan_test.add_orders(p_n integer) returns void language sql as $$
  insert into public.service_orders (organization_id, property_id, service_partner_id, title, status)
  select plan_test.org(), (select id from public.properties where organization_id = plan_test.org() limit 1), private.self_partner_id(plan_test.org()), 'Auftrag ' || g, 'accepted'
  from generate_series(1, p_n) g $$;
-- Tarif als Husora (ohne Anmeldung, wie der Zahlungs-Webhook)
create function plan_test.plan(p_plan text, p_status text default 'active', p_end timestamptz default now() + interval '20 days', p_cancel boolean default false) returns void language sql as $$
  insert into public.partner_subscriptions (organization_id, plan_id, status, billing_provider, current_period_start, current_period_end, cancel_at_period_end)
  values (plan_test.org(), p_plan, p_status, 'manual', now() - interval '10 days', p_end, p_cancel)
  on conflict (organization_id) do update set plan_id = excluded.plan_id, status = excluded.status, current_period_end = excluded.current_period_end, cancel_at_period_end = excluded.cancel_at_period_end $$;
create function plan_test.affected(p_sql text) returns integer language plpgsql as $$
declare v integer; begin execute p_sql; get diagnostics v = row_count; return v; end $$;
create function plan_test.count(p_table text) returns bigint language plpgsql as $$
declare v bigint; begin execute format('select count(*) from public.%I where organization_id = %L', p_table, plan_test.org()) into v; return v; end $$;
grant execute on all functions in schema plan_test to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@tarif.test', 'Clara'), ('mitarbeiter@tarif.test', 'Max'), ('zwei@tarif.test', 'Zoe'), ('fremd@tarif.test', 'Fritz')) v(e, f);
update public.app_config set value = '{"enforce": true}' where key = 'partner_plans';
\set QUIET off

\echo '=== Startwerte ==='
select plan_test.ok('Vier aktive Partner-Tarife mit Pflichtpreisen',
  (select string_agg(code || '=' || price_monthly_cents, ',' order by sort_order) from partner_plans where is_active) = 'free=0,plus=1490,pro=2990,ultra=5990');
select plan_test.ok('Kundenlimits 3 / 20 / 100 / unbegrenzt',
  (select string_agg(coalesce(limits ->> 'customers', 'null'), ',' order by sort_order) from partner_plans) = '3,20,100,null');
select plan_test.ok('Hausbesitzer-Tarife unverändert getrennt', not exists (select 1 from plans where id like 'partner_%'));

\echo '=== Servicebetrieb ohne Abo = Free ==='
select plan_test.login('chef@tarif.test');
select plan_test.set('org', public.create_partner_organization('{"name":"Tarif Test AB","services":["cleaning"]}')::text);
select plan_test.ok('Ohne Abo gilt Free', (public.partner_entitlements() ->> 'plan_code') = 'free');
select plan_test.ok('Rechte enthalten Nutzung und Restkapazität',
  (public.partner_entitlements() -> 'usage' ->> 'customers') = '0' and (public.partner_entitlements() -> 'remaining' ->> 'customers') = '3');

\echo '=== 1) Free: 4. Kunde wird abgelehnt, mit Upgrade-Hinweis ==='
select plan_test.add_customers(3);
select plan_test.ok('3 Kunden angelegt', plan_test.count('customers') = 3);
select plan_test.denied('4. Kunde im Free-Tarif', $$ select plan_test.add_customers(1, 'Vierter') $$, 'Wechsle zu Plus, um bis zu 20 Kunden');
select plan_test.ok('Vorabprüfung meldet Limit mit Upgrade-Tarif',
  (public.check_partner_limit(plan_test.org(), 'customers') ->> 'ok') = 'false'
  and (public.check_partner_limit(plan_test.org(), 'customers') ->> 'upgrade_plan_id') = 'partner_plus');
reset role;

\echo '=== Einladung eines Hausbesitzers bei vollem Kundenlimit ==='
select plan_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Tarif Test AB', 'info@tarif.test');
select plan_test.set('code', public.create_service_partner_invite((select id from service_partners where company_name = 'Tarif Test AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'), 'info@tarif.test'));
reset role;
select plan_test.login('chef@tarif.test');
select plan_test.denied('Einladung annehmen blockiert, wenn Kundenlimit voll', format($$ select public.accept_service_partner_invite(%L) $$, plan_test.get('code')), 'Kundenlimit');
select plan_test.ok('Einladung bleibt offen, nichts halb verknüpft',
  not exists (select 1 from service_partners where partner_organization_id = plan_test.org() and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
reset role;

\echo '=== 2) Plus: 20. Kunde geht, 21. nicht ==='
select plan_test.plan('partner_plus');
select plan_test.login('chef@tarif.test');
select plan_test.ok('Plus aktiv', (public.partner_entitlements() ->> 'plan_code') = 'plus');
select plan_test.ok('Einladung annehmen klappt nach Upgrade (4. Kunde)', (public.accept_service_partner_invite(plan_test.get('code')) ->> 'organization_name') is not null);
select plan_test.add_customers(16, 'Plus');
select plan_test.ok('20 Kunden im Plus-Tarif', plan_test.count('customers') = 20);
select plan_test.denied('21. Kunde im Plus-Tarif', $$ select plan_test.add_customers(1, 'Zu viel') $$, 'Du hast dein Kundenlimit von 20 Kunden im Plus-Tarif erreicht. Wechsle zu Pro, um bis zu 100 Kunden zu verwalten.');

\echo '=== 7) Plus: höchstens 25 Objekte ==='
select plan_test.add_properties(25);
select plan_test.ok('25 Objekte im Plus-Tarif', plan_test.count('properties') = 25);
select plan_test.denied('26. Objekt im Plus-Tarif', $$ select plan_test.add_properties(1) $$, 'Objektlimit');
reset role;

\echo '=== 3) + 8) Pro: 100 Kunden / 100 Objekte ==='
select plan_test.plan('partner_pro');
select plan_test.login('chef@tarif.test');
select plan_test.add_customers(80, 'Pro');
select plan_test.ok('100 Kunden im Pro-Tarif', plan_test.count('customers') = 100);
select plan_test.denied('101. Kunde im Pro-Tarif', $$ select plan_test.add_customers(1, 'Zu viel') $$, 'Wechsle zu Ultra');
select plan_test.add_properties(75);
select plan_test.ok('100 Objekte im Pro-Tarif', plan_test.count('properties') = 100);
select plan_test.denied('101. Objekt im Pro-Tarif', $$ select plan_test.add_properties(1) $$, 'Objektlimit von 100 Objekten');
reset role;

\echo '=== 4) Ultra: mehr als 100 Kunden ==='
select plan_test.plan('partner_ultra');
select plan_test.login('chef@tarif.test');
select plan_test.add_customers(50, 'Ultra');
select plan_test.add_properties(10);
select plan_test.ok('150 Kunden und 110 Objekte im Ultra-Tarif', plan_test.count('customers') = 150 and plan_test.count('properties') = 110);
reset role;

\echo '=== 11) + 13) Downgrade/Rückstufung löscht nichts, blockiert nur Neues ==='
select plan_test.plan('partner_free', 'active', null);
select plan_test.login('chef@tarif.test');
select plan_test.ok('Nach Rückstufung auf Free: alle Kunden und Objekte lesbar', plan_test.count('customers') = 150 and plan_test.count('properties') = 110);
select plan_test.ok('Vorhandene Kunden bleiben bearbeitbar', plan_test.affected($$ update customers set notes = 'bearbeitet' where organization_id = plan_test.org() $$) = 150);
select plan_test.denied('Neuer Kunde über dem Free-Limit blockiert', $$ select plan_test.add_customers(1, 'Neu') $$, 'Free-Tarif');
select plan_test.ok('Tarifwechsel-Vorschau nennt die Überschreitung',
  (select count(*) from jsonb_array_elements(public.partner_plan_change_preview(plan_test.org(), 'partner_plus') -> 'over_limit')) = 2);
reset role;

\echo '=== 9) Auftragslimit je Kalendermonat, nur selbst angelegte ==='
select plan_test.login('chef@tarif.test');
-- Vormonat voll – zählt nicht für den laufenden Monat
reset role;
insert into usage_counters (organization_id, metric, period, count) values (plan_test.org(), 'partner_orders_month', (private.partner_month_start() - interval '1 month')::date, 10);
select plan_test.login('chef@tarif.test');
select plan_test.add_orders(10);
select plan_test.ok('10 eigene Aufträge im laufenden Monat trotz vollem Vormonat', (public.partner_entitlements() -> 'usage' ->> 'orders_month') = '10');
select plan_test.denied('11. eigener Auftrag im Monat (Free)', $$ select plan_test.add_orders(1) $$, 'Der Zähler beginnt am 1. des nächsten Monats neu.');
delete from service_orders where organization_id = plan_test.org() and title = 'Auftrag 1';
select plan_test.denied('Löschen setzt den Monatszähler nicht zurück', $$ select plan_test.add_orders(1) $$, 'Auftragslimit');
reset role;
select plan_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'Kundenauftrag an Tarif Test');
select plan_test.ok('Aufträge von Hausbesitzern zählen nicht und werden nicht blockiert',
  public.offer_service_order((select id from service_tasks where title = 'Kundenauftrag an Tarif Test'),
    (select id from service_partners where company_name = 'Tarif Test AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001')) is not null);
reset role;
select plan_test.login('chef@tarif.test');
select plan_test.ok('Zähler unverändert bei 10', (public.partner_entitlements() -> 'usage' ->> 'orders_month') = '10');
reset role;
select plan_test.plan('partner_pro');
select plan_test.login('chef@tarif.test');
select plan_test.add_orders(5);
select plan_test.ok('Pro: unbegrenzte Aufträge', (public.check_partner_limit(plan_test.org(), 'orders_month', 1000) ->> 'ok') = 'true');

\echo '=== 10) Benutzerlimit serverseitig ==='
reset role;
select plan_test.plan('partner_free', 'active', null);
select plan_test.login('chef@tarif.test');
select plan_test.denied('Free: kein zweiter Benutzer', $$ select public.create_member_invite(plan_test.org(), 'mitarbeiter@tarif.test', 'technician') $$, 'Benutzerlimit');
reset role;
select plan_test.plan('partner_pro');
select plan_test.login('chef@tarif.test');
select plan_test.set('inv', public.create_member_invite(plan_test.org(), 'mitarbeiter@tarif.test', 'technician'));
select plan_test.set('inv2', public.create_member_invite(plan_test.org(), 'zwei@tarif.test', 'technician'));
select public.create_member_invite(plan_test.org(), 'drei@tarif.test', 'technician');
select public.create_member_invite(plan_test.org(), 'vier@tarif.test', 'technician');
select plan_test.denied('Pro: offene Einladungen zählen mit (6. Benutzer)', $$ select public.create_member_invite(plan_test.org(), 'fuenf@tarif.test', 'technician') $$, 'bis zu 20 Benutzer');
reset role;
select plan_test.login('mitarbeiter@tarif.test');
select plan_test.ok('Mitarbeiter tritt bei', (public.accept_member_invite(plan_test.get('inv')) ->> 'role') = 'technician');
reset role;
-- Rückstufung auf Free mit 2 aktiven Benutzern: beide bleiben aktiv, neuer Beitritt blockiert
select plan_test.plan('partner_free', 'active', null);
select plan_test.ok('Bestehende Benutzer bleiben bei Rückstufung aktiv', plan_test.count('organization_members') = 2
  and not exists (select 1 from organization_members where organization_id = plan_test.org() and status <> 'active'));
select plan_test.login('zwei@tarif.test');
select plan_test.denied('Beitritt über offene Einladung nach Rückstufung blockiert', format($$ select public.accept_member_invite(%L) $$, plan_test.get('inv2')), 'Benutzerlimit');
reset role;

\echo '=== 12) Kündigung: bezahlte Rechte bis Periodenende ==='
select plan_test.plan('partner_pro', 'active', now() + interval '10 days', true);
select plan_test.login('chef@tarif.test');
select plan_test.ok('Gekündigt zum Periodenende: Pro bleibt aktiv', (public.partner_entitlements() ->> 'plan_code') = 'pro'
  and (public.partner_entitlements() ->> 'cancel_at_period_end') = 'true');
reset role;
select plan_test.plan('partner_pro', 'canceled', now() + interval '2 days');
select plan_test.login('chef@tarif.test');
select plan_test.ok('Status canceled vor Periodenende: Pro bleibt aktiv', (public.partner_entitlements() ->> 'plan_code') = 'pro');
reset role;
select plan_test.plan('partner_pro', 'canceled', now() - interval '1 minute');
select plan_test.login('chef@tarif.test');
select plan_test.ok('Nach Periodenende: zurück auf Free', (public.partner_entitlements() ->> 'plan_code') = 'free');
reset role;
select plan_test.plan('partner_ultra', 'incomplete');
select plan_test.login('chef@tarif.test');
select plan_test.ok('Unbestätigte Zahlung schaltet nichts frei', (public.partner_entitlements() ->> 'plan_code') = 'free');
reset role;
select plan_test.ok('Alle Abo-Änderungen protokolliert', (select count(*) from partner_subscription_events where organization_id = plan_test.org()) >= 10);

\echo '=== 14) Mandantentrennung ==='
select plan_test.login('fremd@tarif.test');
select public.create_partner_organization('{"name":"Fremdbetrieb AB","services":["cleaning"]}');
select plan_test.ok('Fremder Betrieb sieht kein fremdes Abo', (select count(*) from partner_subscriptions) = 0);
select plan_test.ok('Fremder Betrieb sieht keine fremden Ereignisse', (select count(*) from partner_subscription_events) = 0);
select plan_test.denied('Fremde Rechte nicht abrufbar', $$ select public.partner_entitlements(plan_test.org()) $$);
select plan_test.denied('Fremde Limitprüfung nicht abrufbar', $$ select public.check_partner_limit(plan_test.org(), 'customers') $$);
select plan_test.denied('Kein Kunde im fremden Betrieb (ohne Limit-Auskunft)', $$ insert into customers (organization_id, company_name) values (plan_test.org(), 'Einbruch') $$, 'row-level security');
select plan_test.denied('Eigenes Abo nicht selbst hochsetzen',
  $$ insert into partner_subscriptions (organization_id, plan_id) values ((public.partner_context() -> 'organization' ->> 'id')::uuid, 'partner_ultra') $$);
select plan_test.denied('Keine Freischaltung selbst setzen',
  $$ insert into partner_entitlements (organization_id, feature_key, unlimited, reason) values ((public.partner_context() -> 'organization' ->> 'id')::uuid, 'customers', true, 'selbst') $$);
select plan_test.ok('Tarifkonfiguration nicht änderbar', plan_test.affected($$ update partner_plans set price_monthly_cents = 0 $$) = 0);
select plan_test.denied('Kein Zusatzmodul für fremden Betrieb', $$ select public.request_partner_addon(plan_test.org(), 'extra_user', 390) $$);
reset role;

\echo '=== 15) Keine Vermittlungsprovision ==='
select plan_test.ok('Keine Provisions-/Gebührenspalte im Schema',
  not exists (select 1 from information_schema.columns where table_schema = 'public'
              and (column_name ~* '(commission|provision|fee_percent|take_rate|platform_fee)')));
select plan_test.ok('Keine Provisionsfunktion', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and p.proname ~* '(commission|provision)'));

\echo '=== 16) Zusatzmodule nur nach Aktivierung mit bestätigtem Preis ==='
select plan_test.plan('partner_pro');
select plan_test.login('chef@tarif.test');
select plan_test.denied('Falscher Preis wird abgelehnt', $$ select public.request_partner_addon(plan_test.org(), 'extra_user', 100) $$, 'Preis');
select plan_test.ok('Anfrage mit bestätigtem Preis', (public.request_partner_addon(plan_test.org(), 'extra_user', 390, 2) ->> 'status') = 'requested');
select plan_test.ok('Angefragtes Modul ändert noch kein Limit', (public.partner_entitlements() -> 'limits' ->> 'users') = '5');
select plan_test.ok('Betrieb kann Modul nicht selbst aktivieren',
  plan_test.affected($$ update partner_addons set status = 'active' where organization_id = plan_test.org() $$) = 0);
reset role;
update partner_addons set status = 'active' where organization_id = plan_test.org();
select plan_test.login('chef@tarif.test');
select plan_test.ok('Aktives Modul: +2 Benutzer', (public.partner_entitlements() -> 'limits' ->> 'users') = '7');
select public.cancel_partner_addon(plan_test.org(), 'extra_user');
select plan_test.ok('Gekündigtes Modul wirkt nicht mehr', (public.partner_entitlements() -> 'limits' ->> 'users') = '5');
reset role;

\echo '=== 17) Änderungen im Adminbereich wirken sofort ==='
update public.users set is_super_admin = true where email = 'chef@tarif.test';
select plan_test.login('chef@tarif.test', 'aal2');
select plan_test.ok('Admin ändert Pro-Kundenlimit', plan_test.affected($$ update partner_plans set limits = jsonb_set(limits, '{customers}', '200') where id = 'partner_pro' $$) = 1);
select plan_test.ok('Neues Limit gilt sofort', (public.partner_entitlements() -> 'limits' ->> 'customers') = '200');
select plan_test.ok('Admin setzt individuelle Freischaltung', plan_test.affected($$
  insert into partner_entitlements (organization_id, feature_key, enabled, reason, valid_until) values (plan_test.org(), 'api_access', true, 'Pilotkunde', now() + interval '30 days') $$) = 1);
select plan_test.ok('Freischaltung wirkt', public.partner_entitlements() -> 'features' ? 'api_access');
insert into partner_entitlements (organization_id, feature_key, limit_override, reason) values (plan_test.org(), 'customers', 120, 'Übergang');
select plan_test.ok('Freischaltung gewinnt gegenüber Tarif (Prioritätsregel)', (public.partner_entitlements() -> 'limits' ->> 'customers') = '120');
reset role;
select plan_test.login('chef@tarif.test', 'aal1');
select plan_test.ok('Ohne MFA keine Tarifänderung', plan_test.affected($$ update partner_plans set price_monthly_cents = 1 where id = 'partner_pro' $$) = 0);
reset role;

\echo '=== Startschalter aus: keine Sperren ==='
update public.app_config set value = '{"enforce": false}' where key = 'partner_plans';
select plan_test.plan('partner_free', 'active', null);
select plan_test.login('chef@tarif.test');
select plan_test.add_customers(1, 'Ohne Sperre');
select plan_test.ok('Bei ausgeschaltetem Startschalter wird nichts blockiert', (public.partner_entitlements() ->> 'enforced') = 'false');
reset role;

\echo '=== Hausbesitzer unbeeinflusst ==='
select plan_test.login('admin@husora.test');
select plan_test.ok('Hausbesitzer-Tarif weiter über my_plan', (public.my_plan('cccccccc-0000-4000-8000-000000000001') ->> 'plan_id') is not null);
reset role;

rollback;
\echo '=== Partner-Tarif-Tests bestanden ==='
