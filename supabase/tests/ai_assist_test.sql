-- =============================================================================
-- HUSORA · Test Phase 12: KI-Vorschläge (Zugriff, Kontingent, Fälschungsschutz)
-- =============================================================================
\set QUIET on
begin;
create schema ai_test;
grant usage on schema ai_test to authenticated;
create table ai_test.vars (k text primary key, v text);
grant all on ai_test.vars to authenticated;
create function ai_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function ai_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'KI-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function ai_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'KI-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function ai_test.set(k text, v text) returns void language sql as $$ insert into ai_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function ai_test.get(k text) returns text language sql as $$ select v from ai_test.vars where vars.k = get.k $$;
grant execute on all functions in schema ai_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@ai.test', 'Nora'), ('fremd@ai.test', 'Fynn')) v(e, f);
\set QUIET off

\echo '=== Vorbereitung: verbundener Partner mit Auftrag ==='
select ai_test.login('chef@ai.test');
select ai_test.set('org', public.create_partner_organization('{"name":"KI Service AB","email":"info@ai.test","services":["inspection"]}')::text);
reset role;
select ai_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'KI Service AB', 'info@ai.test');
select ai_test.set('sp', (select id::text from service_partners where company_name = 'KI Service AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select ai_test.set('code', public.create_service_partner_invite(ai_test.get('sp')::uuid, 'info@ai.test'));
reset role;
select ai_test.login('chef@ai.test');
select public.accept_service_partner_invite(ai_test.get('code'));
reset role;
select ai_test.login('admin@husora.test');
insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'AI Hausservice');
select ai_test.set('order', public.offer_service_order((select id from service_tasks where title = 'AI Hausservice'), ai_test.get('sp')::uuid, 100)::text);
reset role;

\echo '=== Vorbereitung: Kontrolle beim Kunden, durchgeführt vom Partner ==='
insert into inspections (organization_id, property_id, service_partner_id, status, started_at, completed_at) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', ai_test.get('sp')::uuid, 'completed', now() - interval '1 hour', now());
select ai_test.set('insp', (select id::text from inspections where service_partner_id = ai_test.get('sp')::uuid order by created_at desc limit 1));
update app_config set value = '{"enabled": false, "daily_limit": 2}' where key = 'ai';

\echo '=== Schalter, Zugriff, Kontingent ==='
select ai_test.login('chef@ai.test');
select ai_test.denied('Ausgeschaltet → keine KI', format($$ select public.ai_begin('inspection_report', 'inspection', %L) $$, ai_test.get('insp')));
reset role;
update app_config set value = '{"enabled": true, "daily_limit": 2}' where key = 'ai';
select ai_test.login('chef@ai.test');
select ai_test.denied('Falsche Kombination abgelehnt', format($$ select public.ai_begin('photo_damage', 'inspection', %L) $$, ai_test.get('insp')));
select ai_test.set('s1', public.ai_begin('inspection_report', 'inspection', ai_test.get('insp')::uuid, ai_test.get('org')::uuid)::text);
select ai_test.ok('Partner der Kontrolle darf auswerten lassen (Organisation = Partner)', (select status = 'pending' and requester_org_id = ai_test.get('org')::uuid and entity_org_id = 'cccccccc-0000-4000-8000-000000000001' from ai_suggestions where id = ai_test.get('s1')::uuid));
select ai_test.denied('Ergebnis kann der Nutzer nicht selbst schreiben', format($$ select public.ai_complete(%L, '{"summary":"gefälscht"}', 'x') $$, ai_test.get('s1')));
select ai_test.denied('Direktes Schreiben verboten', format($$ update ai_suggestions set status = 'suggested', result = '{"x":1}' where id = %L $$, ai_test.get('s1')));
select public.ai_begin('inspection_report', 'inspection', ai_test.get('insp')::uuid, ai_test.get('org')::uuid);
select ai_test.denied('Tageskontingent greift', format($$ select public.ai_begin('inspection_report', 'inspection', %L, %L) $$, ai_test.get('insp'), ai_test.get('org')));
reset role;
select ai_test.login('fremd@ai.test');
select ai_test.denied('Fremde dürfen fremde Kontrollen nicht auswerten lassen', format($$ select public.ai_begin('inspection_report', 'inspection', %L) $$, ai_test.get('insp')));
select ai_test.ok('Fremde sehen keine Vorschläge', (select count(*) from ai_suggestions) = 0);
reset role;

\echo '=== Ergebnis nur über den Server, dann Entscheidung durch den Nutzer ==='
select ai_test.get('s1') as s1_id \gset
set local role service_role;
select public.ai_complete(:'s1_id'::uuid, '{"summary":"Dachrinne lose","priorities":[{"title":"Rinne befestigen","priority":"high"}]}', 'claude-opus-5-5');
reset role;
select ai_test.login('chef@ai.test');
select ai_test.ok('Vorschlag sichtbar, als Vorschlag markiert', (select status = 'suggested' and result ->> 'summary' = 'Dachrinne lose' from ai_suggestions where id = ai_test.get('s1')::uuid));
select public.ai_decide(ai_test.get('s1')::uuid, true);
select ai_test.ok('Übernommen nur durch den Nutzer', (select status from ai_suggestions where id = ai_test.get('s1')::uuid) = 'accepted');
select ai_test.denied('Zweite Entscheidung nicht möglich', format($$ select public.ai_decide(%L, false) $$, ai_test.get('s1')));
reset role;
select ai_test.login('admin@husora.test');
select ai_test.ok('Hausbesitzer sieht den Vorschlag zu seiner Kontrolle', exists (select 1 from ai_suggestions where id = ai_test.get('s1')::uuid));
reset role;

\echo '=== Alle KI-Tests bestanden ==='
rollback;
