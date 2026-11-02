-- =============================================================================
-- HUSORA · Test Phase 10: Wiederkehrende Vertragsbesuche, Verknüpfung, Automatik Mangel → Reparaturauftrag
-- =============================================================================
\set QUIET on
begin;
create schema rc_test;
grant usage on schema rc_test to authenticated;
create table rc_test.vars (k text primary key, v text);
grant all on rc_test.vars to authenticated;
create function rc_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function rc_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'WIEDERKEHR-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function rc_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'WIEDERKEHR-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function rc_test.set(k text, v text) returns void language sql as $$ insert into rc_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function rc_test.get(k text) returns text language sql as $$ select v from rc_test.vars where vars.k = get.k $$;
grant execute on all functions in schema rc_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@rc.test', 'Nora'), ('fremd@rc.test', 'Fynn')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: verbundener Partner mit Auftrag ==='
select rc_test.login('chef@rc.test');
select rc_test.set('org', public.create_partner_organization('{"name":"Recurring Service AB","email":"info@rc.test","services":["inspection"]}')::text);
reset role;
select rc_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Recurring Service AB', 'info@rc.test');
select rc_test.set('sp', (select id::text from service_partners where company_name = 'Recurring Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select rc_test.set('code', public.create_service_partner_invite(rc_test.get('sp')::uuid, 'info@rc.test'));
reset role;
select rc_test.login('chef@rc.test');
select public.accept_service_partner_invite(rc_test.get('code'));
reset role;
select rc_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'RC Hausservice');
select rc_test.set('order', public.offer_service_order((select id from service_tasks where title = 'RC Hausservice'), rc_test.get('sp')::uuid, 100)::text);
reset role;

\echo '=== Jahresvertrag mit automatischer Planung ==='
insert into service_agreements (organization_id, property_id, service_partner_id, title, task_title, task_titles, visits_per_year, annual_price, currency, starts_on, ends_on, status, proposed_by)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', rc_test.get('sp')::uuid, 'RC Rasenpflege', 'RC Rasen mähen', array['RC Rasen mähen'], 26, 1300, 'SEK',
        current_date - 3, current_date + 360, 'active', 'owner');
select rc_test.set('ag', (select id::text from service_agreements where title = 'RC Rasenpflege'));
select rc_test.login('fremd@rc.test');
select rc_test.denied('Fremde Firma kann die Planung nicht einschalten', format($$ select public.set_agreement_auto_schedule(%L, true) $$, rc_test.get('ag')));
reset role;
select rc_test.login('chef@rc.test');
select rc_test.ok('Partnerleitung schaltet die Planung ein', public.set_agreement_auto_schedule(rc_test.get('ag')::uuid, true, 30));
select rc_test.ok('Besuche der nächsten 30 Tage als Aufträge geplant', (select count(*) from service_orders where agreement_id = rc_test.get('ag')::uuid and recurrence_key is not null and status = 'scheduled') between 2 and 3);
select rc_test.ok('Partner benachrichtigt (Besuch geplant)', exists (select 1 from notifications where title like 'Besuch geplant: RC Rasen mähen%'));
select rc_test.ok('Ohne Angabe bleibt die Vorlaufzeit erhalten', public.set_agreement_auto_schedule(rc_test.get('ag')::uuid, true) and (select lead_days from service_agreements where id = rc_test.get('ag')::uuid) = 30);
reset role;
select rc_test.ok('Zweiter Lauf legt nichts doppelt an', (public.run_recurring_agreements() ->> 'created')::int = 0);
select rc_test.denied('Lauf nur für den Server', $$ set local role authenticated; select public.run_recurring_agreements() $$);
reset role;

\echo '=== Aufgabe des Hausbesitzers wird mit dem geplanten Besuch verknüpft ==='
select rc_test.set('visit', (select id::text from service_orders where agreement_id = rc_test.get('ag')::uuid and recurrence_key is not null order by scheduled_at limit 1 offset 1));
select rc_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title, scheduled_start)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'RC Rasen mähen',
        (select scheduled_at + interval '2 days' from service_orders where id = rc_test.get('visit')::uuid));
select rc_test.ok('offer_service_order liefert den geplanten Besuch', public.offer_service_order((select id from service_tasks where title = 'RC Rasen mähen'), rc_test.get('sp')::uuid) = rc_test.get('visit')::uuid);
select rc_test.ok('Kein zusätzlicher Auftrag, Besuch mit Aufgabe verknüpft', (select count(*) = 1 and bool_and(service_task_id is not null) from service_orders where service_task_id = (select id from service_tasks where title = 'RC Rasen mähen')));
reset role;

\echo '=== Automatik: Mangel aus Kontrolle → Reparaturauftrag beim Partner ==='
select rc_test.login('admin@husora.test');
insert into automation_rules (organization_id, name, trigger_type, action_config) values ('cccccccc-0000-4000-8000-000000000001', 'RC Mangel sofort beheben', 'inspection_item_defect', '{"type":"create_repair_order"}');
reset role;
insert into inspections (organization_id, property_id, service_partner_id, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', rc_test.get('sp')::uuid, 'in_progress');
select rc_test.set('insp', (select id::text from inspections where service_partner_id = rc_test.get('sp')::uuid order by created_at desc limit 1));
insert into inspection_items (inspection_id, category, name, status) values (rc_test.get('insp')::uuid, 'Dach', 'RC Dachrinne', 'ok');
update inspection_items set status = 'defect', notes = 'Rinne lose' where name = 'RC Dachrinne';
select rc_test.ok('Mangel freigegeben mit Auftrag beim Partner', (select r.status = 'approved' and o.status = 'accepted' and o.order_type = 'repair' and o.service_partner_id = rc_test.get('sp')::uuid
  from repairs r join service_orders o on o.id = r.service_order_id where r.title = 'Mangel: RC Dachrinne'));
select rc_test.login('chef@rc.test');
select rc_test.ok('Partner sieht den Reparaturauftrag', exists (select 1 from service_orders where title = 'Mangelbeseitigung: RC Dachrinne'));
reset role;
update inspection_items set status = 'ok' where name = 'RC Dachrinne';
update inspection_items set status = 'defect' where name = 'RC Dachrinne';
select rc_test.ok('Kein zweiter Auftrag für denselben Mangel', (select count(*) from service_orders where title = 'Mangelbeseitigung: RC Dachrinne') = 1);

\echo '=== Alle Wiederkehr-Tests bestanden ==='
rollback;
