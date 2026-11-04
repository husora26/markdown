-- =============================================================================
-- HUSORA · Test Hybrid Service & Smart Maintenance (Migration 4700)
-- Terminregeln, Idempotenz, Hybrid-Beauftragung, Vertragsprüfung, Bündelung, Budgetgrenze, RLS
-- =============================================================================
\set QUIET on
begin;
create schema ht_test;
grant usage on schema ht_test to authenticated;
create table ht_test.vars (k text primary key, v text);
grant all on ht_test.vars to authenticated;
create function ht_test.login(p_email text) returns void language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function ht_test.ok(p_label text, p_condition boolean) returns void language plpgsql as $$
begin
  if p_condition is distinct from true then raise exception 'HYBRID-TEST FEHLGESCHLAGEN – %', p_label; end if;
  raise notice 'OK – %', p_label;
end $$;
create function ht_test.denied(p_label text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'OK – % (abgelehnt: %)', p_label, sqlerrm; return; end;
  raise exception 'HYBRID-TEST FEHLGESCHLAGEN – % (wurde NICHT abgelehnt)', p_label;
end $$;
create function ht_test.attempt(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ausgeführt'; exception when others then return sqlerrm; end $$;
create function ht_test.set(k text, v text) returns void language sql as $$ insert into ht_test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function ht_test.get(k text) returns text language sql as $$ select v from ht_test.vars where vars.k = get.k $$;
create function ht_test.dates(p_plan jsonb, p_n integer) returns date[] language sql as $$ select array_agg(local_date order by local_date) from public.maintenance_preview(p_plan, p_n) $$;
grant execute on all functions in schema ht_test to authenticated;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', e, '', now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('first_name', f), now(), now()
from (values ('chef@ht.test', 'Hanna'), ('fremd@ht.test', 'Frida')) v(e, f);
\set QUIET off

\echo '=== Terminregeln (Monatsende, Schaltjahr, Quartal, Wochentag, Saison, Ende, Zeitumstellung) ==='
select ht_test.login('admin@husora.test');
select ht_test.ok('Monatlich am 31.: Monatsende ohne Drift', ht_test.dates('{"interval_type":"monthly","start_date":"2027-01-31"}', 4) = array['2027-01-31','2027-02-28','2027-03-31','2027-04-30']::date[]);
select ht_test.ok('Jährlich am 29.02.: Schaltjahr, sonst 28.02.', ht_test.dates('{"interval_type":"yearly","start_date":"2028-02-29"}', 5) = array['2028-02-29','2029-02-28','2030-02-28','2031-02-28','2032-02-29']::date[]);
select ht_test.ok('Vierteljährlich', ht_test.dates('{"interval_type":"quarterly","start_date":"2027-01-15"}', 4) = array['2027-01-15','2027-04-15','2027-07-15','2027-10-15']::date[]);
select ht_test.ok('Halbjährlich', ht_test.dates('{"interval_type":"semi_annual","start_date":"2027-03-10"}', 3) = array['2027-03-10','2027-09-10','2028-03-10']::date[]);
select ht_test.ok('Wöchentlich am Mittwoch (Start Montag)', ht_test.dates('{"interval_type":"weekly","weekday":3,"start_date":"2027-03-01"}', 3) = array['2027-03-03','2027-03-10','2027-03-17']::date[]);
select ht_test.ok('Alle 2 Wochen', ht_test.dates('{"interval_type":"every_n_weeks","interval_value":2,"start_date":"2027-03-01"}', 3) = array['2027-03-01','2027-03-15','2027-03-29']::date[]);
select ht_test.ok('Alle 2 Monate mit festem Tag', ht_test.dates('{"interval_type":"every_n_months","interval_value":2,"day_of_month":30,"start_date":"2027-01-05"}', 3) = array['2027-01-30','2027-03-30','2027-05-30']::date[]);
select ht_test.ok('Saison Dez–März (über den Jahreswechsel)', ht_test.dates('{"interval_type":"monthly","start_date":"2027-01-10","season_start_month":12,"season_end_month":3}', 5) = array['2027-01-10','2027-02-10','2027-03-10','2027-12-10','2028-01-10']::date[]);
select ht_test.ok('Enddatum beendet die Serie', ht_test.dates('{"interval_type":"daily","start_date":"2027-05-01","end_date":"2027-05-03"}', 10) = array['2027-05-01','2027-05-02','2027-05-03']::date[]);
select ht_test.ok('Einmaliger Termin', ht_test.dates('{"interval_type":"once","start_date":"2027-06-01"}', 5) = array['2027-06-01']::date[]);
select ht_test.ok('Eigenes Intervall: alle 10 Tage', ht_test.dates('{"interval_type":"custom","interval_value":10,"interval_unit":"day","start_date":"2027-01-01"}', 3) = array['2027-01-01','2027-01-11','2027-01-21']::date[]);
select ht_test.ok('Zeitumstellung: 09:00 Ortszeit bleibt 09:00 (UTC 08:00 → 07:00)',
  (select array_agg(scheduled_for order by scheduled_for) from public.maintenance_preview('{"interval_type":"weekly","start_date":"2027-03-21","local_time":"09:00","timezone":"Europe/Stockholm"}', 2))
  = array['2027-03-21 08:00+00','2027-03-28 07:00+00']::timestamptz[]);
reset role;

\echo '=== Vorbereitung: verbundener Servicepartner, Objektzuordnung ==='
select ht_test.login('chef@ht.test');
select ht_test.set('porg', public.create_partner_organization('{"name":"Hybrid Garten AB","email":"info@ht.test","services":["garden"]}')::text);
reset role;
select ht_test.login('admin@husora.test');
insert into service_partners (organization_id, company_name, email) values ('cccccccc-0000-4000-8000-000000000001', 'Hybrid Garten AB', 'info@ht.test');
select ht_test.set('sp', (select id::text from service_partners where company_name = 'Hybrid Garten AB' and organization_id = 'cccccccc-0000-4000-8000-000000000001'));
select ht_test.set('code', public.create_service_partner_invite(ht_test.get('sp')::uuid, 'info@ht.test'));
reset role;
select ht_test.login('chef@ht.test');
select public.accept_service_partner_invite(ht_test.get('code'));
reset role;
insert into property_service_assignments (organization_id, property_id, service_partner_id, start_date)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', ht_test.get('sp')::uuid, current_date - 1);

\echo '=== Eigentümer erledigt selbst: Fälligkeiten, Idempotenz, Erledigen/Überspringen/Verschieben ==='
select ht_test.login('admin@husora.test');
select ht_test.set('p_self', public.save_maintenance_plan(jsonb_build_object('property_id', 'dddddddd-0000-4000-8000-000000000001', 'title', 'HT Rauchmelder testen',
  'category', 'Sicherheit', 'interval_type', 'weekly', 'start_date', current_date, 'automation_mode', 'owner_self_service', 'timezone', 'Europe/Stockholm'))::text);
select ht_test.ok('Plan ohne Partner: Zuständigkeit Eigentümer', (select assigned_type = 'owner' and organization_id = 'cccccccc-0000-4000-8000-000000000001' from maintenance where id = ht_test.get('p_self')::uuid));
select ht_test.set('n_self', (select count(*)::text from service_tasks where maintenance_id = ht_test.get('p_self')::uuid));
select ht_test.ok('Fälligkeiten für 60 Tage erzeugt (wöchentlich ≈ 9)', ht_test.get('n_self')::int between 8 and 10);
select ht_test.ok('Fälligkeiten im Vorlauf: „selbst erledigen“, kein Auftrag',
  (select bool_and(owner_action = 'self_service') from service_tasks where maintenance_id = ht_test.get('p_self')::uuid and local_scheduled_date <= current_date + 14)
  and not exists (select 1 from service_orders o join service_tasks t on t.id = o.service_task_id where t.maintenance_id = ht_test.get('p_self')::uuid));
select ht_test.ok('Erneutes Planen erzeugt nichts doppelt', (public.refresh_maintenance_plan(ht_test.get('p_self')::uuid) ->> 'created')::int = 0
  and (select count(*) from service_tasks where maintenance_id = ht_test.get('p_self')::uuid) = ht_test.get('n_self')::int);
select ht_test.ok('Erzeugungsschlüssel eindeutig', (select count(distinct generation_key) = count(*) from service_tasks where maintenance_id = ht_test.get('p_self')::uuid));
select ht_test.ok('Lesesicht: erste Fälligkeit heute = „due“', (select occurrence_status = 'due' from maintenance_occurrences where maintenance_id = ht_test.get('p_self')::uuid order by local_scheduled_date limit 1));
select ht_test.set('t1', (select id::text from service_tasks where maintenance_id = ht_test.get('p_self')::uuid order by local_scheduled_date limit 1));
select ht_test.set('t2', (select id::text from service_tasks where maintenance_id = ht_test.get('p_self')::uuid order by local_scheduled_date offset 1 limit 1));
select ht_test.set('t3', (select id::text from service_tasks where maintenance_id = ht_test.get('p_self')::uuid order by local_scheduled_date offset 2 limit 1));
select ht_test.set('r', public.complete_maintenance_task(ht_test.get('t1')::uuid, 'Alle Melder piepen'));
select ht_test.ok('Erledigt markiert', ht_test.get('r') = 'completed'
  and (select last_performed_at is not null from maintenance where id = ht_test.get('p_self')::uuid));
select ht_test.denied('Überspringen ohne Grund', format($$ select public.skip_maintenance_task(%L, '  ') $$, ht_test.get('t2')));
select ht_test.ok('Übersprungen mit Grund', public.skip_maintenance_task(ht_test.get('t2')::uuid, 'Im Urlaub') = 'skipped');
select ht_test.set('r', public.reschedule_maintenance_task(ht_test.get('t3')::uuid, current_date + 20)::text);
select ht_test.ok('Einzeltermin verschoben, Serie unverändert',
  (select local_scheduled_date = current_date + 14 and (scheduled_start at time zone 'Europe/Stockholm')::date = current_date + 20 from service_tasks where id = ht_test.get('t3')::uuid));
select ht_test.attempt(format($$ delete from service_tasks where id = %L $$, ht_test.get('t3')));
select ht_test.ok('Fälligkeiten aus Plänen werden nicht gelöscht', exists (select 1 from service_tasks where id = ht_test.get('t3')::uuid));
select ht_test.ok('Abgeschlossene Fälligkeit bleibt abgeschlossen', (select status = 'completed' from service_tasks where id = ht_test.get('t1')::uuid));
reset role;
select ht_test.ok('Täglicher Lauf erzeugt nichts doppelt', (public.run_maintenance_scheduler() ->> 'created')::int = 0);
select ht_test.ok('Lauf protokolliert', exists (select 1 from maintenance_runs where status = 'ok' and finished_at is not null));
select ht_test.denied('Gesamtlauf nur für den Server', $$ set local role authenticated; select public.run_maintenance_scheduler() $$);
reset role;

\echo '=== Einzelauftrag mit Eigentümerfreigabe (Szenario B) + Bündelung ==='
select ht_test.login('admin@husora.test');
select ht_test.set('p_appr', public.save_maintenance_plan(jsonb_build_object('property_id', 'dddddddd-0000-4000-8000-000000000001', 'template_key', 'tpl-heatpump',
  'title', 'HT Heizung prüfen', 'interval_type', 'quarterly', 'start_date', current_date + 2, 'automation_mode', 'owner_approval', 'assigned_partner_id', ht_test.get('sp')))::text);
select ht_test.set('p_gutter', public.save_maintenance_plan(jsonb_build_object('property_id', 'dddddddd-0000-4000-8000-000000000001',
  'title', 'HT Dachrinne prüfen', 'category', 'Dach', 'interval_type', 'yearly', 'start_date', current_date + 5, 'automation_mode', 'owner_approval',
  'assigned_partner_id', ht_test.get('sp'), 'checklist', '["Laub entfernen","Fallrohr prüfen"]'::jsonb))::text);
select ht_test.set('a1', (select id::text from service_tasks where maintenance_id = ht_test.get('p_appr')::uuid order by local_scheduled_date limit 1));
select ht_test.set('a2', (select id::text from service_tasks where maintenance_id = ht_test.get('p_gutter')::uuid order by local_scheduled_date limit 1));
select ht_test.ok('Fälligkeit wartet auf Freigabe, kein Auftrag', (select owner_action = 'approval_required' from service_tasks where id = ht_test.get('a1')::uuid)
  and private.mt_active_order(ht_test.get('a1')::uuid) is null);
select ht_test.ok('Lesesicht: „owner_action_required“', (select occurrence_status = 'owner_action_required' from maintenance_occurrences where id = ht_test.get('a1')::uuid));
select ht_test.ok('Eigentümer erhält Hinweis „Service erforderlich“ genau einmal', (select count(*) = 1 from notifications where title = 'Service erforderlich: HT Heizung prüfen'
  and user_id = (select id from users where email = 'admin@husora.test')));
select ht_test.ok('Erneuter Lauf: kein doppelter Hinweis', (public.refresh_maintenance_plan(ht_test.get('p_appr')::uuid) is not null)
  and (select count(*) = 1 from notifications where title = 'Service erforderlich: HT Heizung prüfen' and user_id = (select id from users where email = 'admin@husora.test')));
select ht_test.set('bundle', public.request_maintenance_service(array[ht_test.get('a1')::uuid, ht_test.get('a2')::uuid], ht_test.get('sp')::uuid, 'Bitte zusammen erledigen', 180)::text);
select ht_test.ok('Ein Auftrag mit zwei Positionen', (select count(*) = 2 and count(distinct occurrence_id) = 2 from service_order_items where service_order_id = ht_test.get('bundle')::uuid));
select ht_test.ok('Checkliste aus dem Plan in der Position', (select checklist = '["Laub entfernen","Fallrohr prüfen"]'::jsonb from service_order_items where occurrence_id = ht_test.get('a2')::uuid));
select ht_test.ok('Auftragsquelle Wartung, beide Fälligkeiten beim Partner angefragt',
  (select source_type = 'maintenance' and status = 'offered' from service_orders where id = ht_test.get('bundle')::uuid)
  and (select bool_and(status = 'assigned') from service_tasks where id in (ht_test.get('a1')::uuid, ht_test.get('a2')::uuid)));
select ht_test.ok('Wiederholte Anfrage liefert denselben Auftrag', public.request_maintenance_service(array[ht_test.get('a1')::uuid, ht_test.get('a2')::uuid], ht_test.get('sp')::uuid) = ht_test.get('bundle')::uuid);
select ht_test.ok('Teilmenge eines aktiven Auftrags liefert denselben Auftrag', public.request_maintenance_service(array[ht_test.get('a2')::uuid], ht_test.get('sp')::uuid) = ht_test.get('bundle')::uuid);
reset role;
select ht_test.denied('Fälligkeit nicht zweimal aktiv beauftragen', format($$ insert into service_order_items (service_order_id, occurrence_id, title)
  values ((select id from service_orders where id <> %L and status not in ('rejected', 'cancelled') limit 1), %L, 'Doppelt') $$, ht_test.get('bundle'), ht_test.get('a2')));
select ht_test.login('admin@husora.test');
select ht_test.denied('Selbst erledigen nicht während laufendem Auftrag', format($$ select public.complete_maintenance_task(%L) $$, ht_test.get('a1')));
reset role;
select ht_test.login('chef@ht.test');
select ht_test.ok('Partner sieht die Positionen', (select count(*) = 2 from service_order_items where service_order_id = ht_test.get('bundle')::uuid));
select ht_test.ok('Partner sieht keine Wartungspläne (Budget/Notizen privat)', (select count(*) = 0 from maintenance));
select ht_test.denied('Partner kann keine Pläne anlegen', $$ insert into maintenance (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'x') $$);
select ht_test.denied('Partner ändert Positionen nicht direkt', format($$ update service_order_items set unit_price = 1 where service_order_id = %L $$, ht_test.get('bundle')));
select ht_test.denied('Position nur bei laufendem Auftrag dokumentieren', format($$ select public.update_order_item((select id from service_order_items where occurrence_id = %L), 'done') $$, ht_test.get('a1')));
select public.transition_service_order(ht_test.get('bundle')::uuid, 'accepted');
select ht_test.ok('Partner liest keine Fälligkeiten des Eigentümers', (select count(*) from maintenance_occurrences) = 0);
reset role;
select ht_test.ok('Annahme: beide Fälligkeiten „assigned“', (select bool_and(occurrence_status = 'assigned') from maintenance_occurrences where id in (ht_test.get('a1')::uuid, ht_test.get('a2')::uuid)));
select ht_test.login('chef@ht.test');
select public.transition_service_order(ht_test.get('bundle')::uuid, 'in_progress');
select ht_test.ok('Checkliste je Position dokumentiert', (public.update_order_item((select id from service_order_items where occurrence_id = ht_test.get('a2')::uuid),
  'done', '{"Laub entfernen":true,"Fallrohr prüfen":true}', 'Rinne sauber')).checklist_results ->> 'Fallrohr prüfen' = 'true');
select public.update_order_item((select id from service_order_items where occurrence_id = ht_test.get('a1')::uuid), 'not_done', null, 'Ersatzteil fehlt');
select public.transition_service_order(ht_test.get('bundle')::uuid, 'completed');
reset role;
select ht_test.ok('Erledigte Position → Fälligkeit erledigt', (select status = 'completed' and completion_notes = 'Rinne sauber' from service_tasks where id = ht_test.get('a2')::uuid));
select ht_test.ok('Nicht erledigte Position → Fälligkeit wieder offen beim Eigentümer',
  (select status = 'pending' and owner_action = 'approval_required' and blocked_reason like 'Beim Einsatz nicht erledigt%' from service_tasks where id = ht_test.get('a1')::uuid));
select ht_test.ok('Plan-Historie aktualisiert', (select last_performed_at is not null from maintenance where id = ht_test.get('p_gutter')::uuid));
select ht_test.login('fremd@ht.test');
select ht_test.denied('Fremde bestätigen keinen Abschluss', format($$ select public.confirm_service_completion(%L, true) $$, ht_test.get('bundle')));
reset role;
select ht_test.login('admin@husora.test');
select ht_test.denied('Rückfrage braucht einen Text', format($$ select public.confirm_service_completion(%L, false, ' ') $$, ht_test.get('bundle')));
select ht_test.ok('Eigentümer meldet Rückfrage', public.confirm_service_completion(ht_test.get('bundle')::uuid, false, 'Heizung fehlt noch') = 'disputed');
select ht_test.set('r', public.confirm_service_completion(ht_test.get('bundle')::uuid, true));
select ht_test.ok('Eigentümer bestätigt Abschluss', ht_test.get('r') = 'confirmed'
  and (select owner_confirmed_at is not null and owner_dispute_note is null from service_orders where id = ht_test.get('bundle')::uuid));
select ht_test.ok('Ereignisse protokolliert', (select count(*) = 3 from service_order_events where service_order_id = ht_test.get('bundle')::uuid and event_type in ('bundled', 'owner_disputed', 'owner_confirmed')));
reset role;
select ht_test.ok('Partner benachrichtigt (Bestätigung)', exists (select 1 from notifications where title like 'Abschluss bestätigt: Wartungsbesuch%'));

\echo '=== Ablehnung: Fälligkeit bleibt offen, keine automatische Neubeauftragung ==='
select ht_test.login('admin@husora.test');
select ht_test.set('o_rej', public.request_maintenance_service(array[ht_test.get('a1')::uuid], ht_test.get('sp')::uuid)::text);
reset role;
select ht_test.login('chef@ht.test');
select public.transition_service_order(ht_test.get('o_rej')::uuid, 'rejected', 'Keine Kapazität');
reset role;
select ht_test.ok('Nach Ablehnung: offen, Eigentümer entscheidet neu', (select status = 'pending' and assigned_partner_id is null and owner_action = 'approval_required'
  and blocked_reason like 'Servicepartner hat abgelehnt%' from service_tasks where id = ht_test.get('a1')::uuid));

\echo '=== Dauerauftrag mit automatischer Beauftragung (Szenario A) ==='
insert into service_agreements (organization_id, property_id, service_partner_id, title, task_title, task_titles, visits_per_year, annual_price, currency,
                                starts_on, ends_on, status, proposed_by, pricing_type, unit_price, max_price_per_visit, approval_mode, categories)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', ht_test.get('sp')::uuid, 'HT Gartenpflege', 'HT Rasen mähen', array['HT Rasen mähen'],
        30, 1200, 'EUR', current_date - 1, current_date + 200, 'active', 'owner', 'per_visit', 40, 50, 'auto_within_limits', array['Garten']);
select ht_test.set('ag', (select id::text from service_agreements where title = 'HT Gartenpflege'));
select ht_test.ok('Vertragsfassung 1 festgehalten', exists (select 1 from service_agreement_versions where agreement_id = ht_test.get('ag')::uuid and version = 1));
update service_agreements set approval_mode = 'owner_each' where id = ht_test.get('ag')::uuid;
select ht_test.login('admin@husora.test');
select ht_test.denied('Automatik nur mit ausdrücklich erlaubter Freigabeart', format($$ select public.save_maintenance_plan(jsonb_build_object('property_id', 'dddddddd-0000-4000-8000-000000000001',
  'title', 'HT Rasen mähen', 'category', 'Garten', 'interval_type', 'weekly', 'automation_mode', 'agreement_auto', 'service_agreement_id', %L)) $$, ht_test.get('ag')));
reset role;
update service_agreements set approval_mode = 'auto_within_limits' where id = ht_test.get('ag')::uuid;
select ht_test.login('admin@husora.test');
select ht_test.set('p_auto', public.save_maintenance_plan(jsonb_build_object('property_id', 'dddddddd-0000-4000-8000-000000000001', 'title', 'HT Rasen mähen',
  'category', 'Garten', 'interval_type', 'weekly', 'start_date', current_date, 'automation_mode', 'agreement_auto', 'service_agreement_id', ht_test.get('ag')))::text);
reset role;
select ht_test.ok('Partner aus dem Vertrag übernommen', (select assigned_partner_id = ht_test.get('sp')::uuid from maintenance where id = ht_test.get('p_auto')::uuid));
select ht_test.set('n_auto', (select count(*)::text from service_orders o where o.agreement_id = ht_test.get('ag')::uuid and o.source_type = 'agreement_auto'));
select ht_test.ok('Aufträge im Vorlauf (14 Tage) automatisch erstellt', ht_test.get('n_auto')::int between 2 and 3);
select ht_test.ok('Auftrag: Preis aus Vertrag, Version, Freigabe durch Vertrag, Position mit Preis',
  (select bool_and(o.estimated_cost = 40 and o.agreement_version = 1 and o.approval_status = 'approved' and o.status = 'offered' and i.unit_price = 40 and i.line_total = 40)
   from service_orders o join service_order_items i on i.service_order_id = o.id where o.agreement_id = ht_test.get('ag')::uuid and o.source_type = 'agreement_auto'));
select ht_test.ok('Partner benachrichtigt (neue Anfrage)', exists (select 1 from notifications where title = 'Neue Anfrage: HT Rasen mähen'));
select ht_test.ok('Zweiter Lauf: keine doppelten Aufträge', (public.run_maintenance_scheduler() ->> 'orders')::int = 0
  and (select count(*) from service_orders o where o.agreement_id = ht_test.get('ag')::uuid and o.source_type = 'agreement_auto') = ht_test.get('n_auto')::int);
select ht_test.ok('Jahresvertrags-Planung plant diesen Vertrag nicht zusätzlich', (select auto_schedule from service_agreements where id = ht_test.get('ag')::uuid) = false
  or not exists (select 1 from service_orders where agreement_id = ht_test.get('ag')::uuid and recurrence_key not like 'mt:%'));
select ht_test.set('o_auto', (select o.id::text from service_orders o join service_tasks t on t.id = o.service_task_id where o.agreement_id = ht_test.get('ag')::uuid order by t.local_scheduled_date limit 1));

\echo '=== Budgetüberschreitung (Szenario D) ==='
select ht_test.login('chef@ht.test');
select public.transition_service_order(ht_test.get('o_auto')::uuid, 'accepted');
select public.transition_service_order(ht_test.get('o_auto')::uuid, 'in_progress');
select ht_test.denied('Abschluss mit 65 € bei 40 € Rahmen blockiert', format($$ update service_orders set actual_cost = 65, status = 'completed' where id = %L $$, ht_test.get('o_auto')));
select ht_test.ok('Mehrkosten über Vertragsmaximum nie automatisch freigegeben', (public.request_approval(ht_test.get('o_auto')::uuid, 'Zusätzlicher Heckenschnitt', 25) ->> 'status') = 'pending');
select ht_test.denied('Abschluss während offener Freigabe blockiert', format($$ update service_orders set actual_cost = 65, status = 'completed' where id = %L $$, ht_test.get('o_auto')));
reset role;
select ht_test.login('admin@husora.test');
select public.respond_approval((select id from approval_requests where service_order_id = ht_test.get('o_auto')::uuid), true, 'ok');
reset role;
select ht_test.login('chef@ht.test');
update service_orders set actual_cost = 65, status = 'completed' where id = ht_test.get('o_auto')::uuid;
reset role;
select ht_test.ok('Nach expliziter Freigabe abgeschlossen; Fälligkeit erledigt', (select o.status = 'completed' and t.status = 'completed'
  from service_orders o join service_tasks t on t.id = o.service_task_id where o.id = ht_test.get('o_auto')::uuid));

\echo '=== Vertragsprüfung: maschinenlesbare Gründe ==='
select ht_test.ok('außerhalb des Umfangs', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'Fenster putzen', 'Reinigung', current_date) ->> 'code' = 'out_of_scope');
select ht_test.ok('falsches Objekt', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000002', null, 'HT Rasen mähen', 'Garten', current_date) ->> 'code' = 'wrong_property');
select ht_test.ok('außerhalb der Laufzeit', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date + 400) ->> 'code' = 'expired');
select ht_test.ok('über dem Budget des Plans', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date, 30) ->> 'code' = 'over_plan_budget');
update service_agreements set budget_period_amount = 100, budget_period = 'term' where id = ht_test.get('ag')::uuid;
select ht_test.ok('Gesamtbudget würde überschritten', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date) ->> 'code' = 'over_period_budget');
update service_agreements set budget_period_amount = null, pricing_type = 'hourly' where id = ht_test.get('ag')::uuid;
select ht_test.ok('Preis unklar (Stundenpreis)', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date) ->> 'code' = 'price_unclear');
update service_agreements set pricing_type = 'per_visit', max_price_per_visit = 30 where id = ht_test.get('ag')::uuid;
select ht_test.ok('Preis über Maximum je Einsatz', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date) ->> 'code' = 'over_max_per_visit');
update service_agreements set max_price_per_visit = 50 where id = ht_test.get('ag')::uuid;
select ht_test.set('r', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date)::text);
select ht_test.ok('Gültiger Vertrag: ok mit Preis', ht_test.get('r')::jsonb ->> 'code' = 'ok' and (ht_test.get('r')::jsonb ->> 'price')::numeric = 40);

\echo '=== Vertragsänderung → neue Version, bis zur Zustimmung keine Automatik ==='
select ht_test.login('admin@husora.test');
select ht_test.set('r', public.update_agreement_terms(ht_test.get('ag')::uuid, '{"unit_price":45}') ->> 'version');
select ht_test.ok('Konditionen geändert → Version 2, Zustimmung nötig', ht_test.get('r')::int = 2
  and (select status = 'proposed' from service_agreements where id = ht_test.get('ag')::uuid));
reset role;
-- Vorlauf verlängern: weitere Fälligkeiten kommen in die Prüfung, während der Vertrag auf Zustimmung wartet
update maintenance set lead_days = 30 where id = ht_test.get('p_auto')::uuid;
select ht_test.login('admin@husora.test');
select public.refresh_maintenance_plan(ht_test.get('p_auto')::uuid);
reset role;
select ht_test.ok('Ohne Zustimmung: blockiert statt beauftragt, Grund sichtbar',
  (select count(*) >= 2 and bool_and(owner_action = 'blocked' and blocked_reason = 'Dauerauftrag ist nicht aktiv') from service_tasks
   where maintenance_id = ht_test.get('p_auto')::uuid and status = 'pending' and local_scheduled_date between current_date + 15 and current_date + 30));
select ht_test.ok('Eigentümer über Blockierung informiert', exists (select 1 from notifications where title = 'Automatische Beauftragung gestoppt: HT Rasen mähen'));
select ht_test.login('chef@ht.test');
select public.respond_service_agreement(ht_test.get('ag')::uuid, true);
reset role;
select ht_test.ok('Fassung 2 nach Zustimmung festgehalten', exists (select 1 from service_agreement_versions where agreement_id = ht_test.get('ag')::uuid and version = 2 and (snapshot ->> 'unit_price')::numeric = 45));
select ht_test.set('r', public.run_maintenance_scheduler() ->> 'orders');
select ht_test.ok('Nach Zustimmung: blockierte Fälligkeiten werden beauftragt (Version 2, 45 €)', ht_test.get('r')::int >= 1
  and exists (select 1 from service_orders where agreement_id = ht_test.get('ag')::uuid and agreement_version = 2 and estimated_cost = 45 and status = 'offered'));
select ht_test.login('admin@husora.test');
select ht_test.ok('Vertrag pausiert', public.set_agreement_paused(ht_test.get('ag')::uuid, true) = 'paused');
reset role;
select ht_test.ok('Pausierter Vertrag: Grund „pausiert“', private.validate_service_agreement(ht_test.get('ag')::uuid, 'dddddddd-0000-4000-8000-000000000001', null, 'HT Rasen mähen', 'Garten', current_date) ->> 'code' = 'paused');

\echo '=== Plan pausieren/archivieren, Mandantentrennung ==='
select ht_test.login('admin@husora.test');
select ht_test.set('r', public.set_maintenance_plan_status(ht_test.get('p_self')::uuid, 'paused'));
select ht_test.ok('Plan pausiert: künftige offene Fälligkeiten ohne Auftrag entfernt', ht_test.get('r') = 'paused'
  and not exists (select 1 from service_tasks where maintenance_id = ht_test.get('p_self')::uuid and status = 'pending' and local_scheduled_date >= current_date + 1));
select ht_test.ok('Historie bleibt', (select count(*) = 2 from service_tasks where maintenance_id = ht_test.get('p_self')::uuid and status in ('completed', 'skipped')));
select ht_test.ok('Pausierter Plan erzeugt nichts', (public.refresh_maintenance_plan(ht_test.get('p_self')::uuid) ->> 'skipped')::boolean);
select ht_test.set('r', public.set_maintenance_plan_status(ht_test.get('p_self')::uuid, 'active'));
select ht_test.ok('Fortsetzen erzeugt wieder Fälligkeiten', ht_test.get('r') = 'active'
  and exists (select 1 from service_tasks where maintenance_id = ht_test.get('p_self')::uuid and status = 'pending'));
reset role;
select ht_test.login('fremd@ht.test');
select ht_test.ok('Fremde sehen keine Pläne/Fälligkeiten', (select count(*) from maintenance) = 0 and (select count(*) from maintenance_occurrences) = 0);
select ht_test.denied('Fremde legen keinen Plan für fremdes Objekt an', $$ select public.save_maintenance_plan('{"property_id":"dddddddd-0000-4000-8000-000000000001","title":"x","interval_type":"weekly"}') $$);
select ht_test.denied('Fremde erledigen keine fremden Fälligkeiten', format($$ select public.complete_maintenance_task(%L) $$, ht_test.get('t3')));
select ht_test.denied('Fremde ändern keine fremden Pläne', format($$ select public.set_maintenance_plan_status(%L, 'archived') $$, ht_test.get('p_self')));
select ht_test.ok('Fremde sehen keine Auftragspositionen', (select count(*) from service_order_items) = 0);
select ht_test.ok('Fremde sehen keine Vertragsfassungen', (select count(*) from service_agreement_versions) = 0);
select ht_test.ok('Fremde sehen keine Scheduler-Läufe', (select count(*) from maintenance_runs) = 0);
reset role;
select ht_test.login('admin@husora.test');
select ht_test.denied('Eigentümer schreibt Pläne nur über die geprüfte Funktion', $$ update maintenance set budget_limit = 1 $$);
select ht_test.ok('Vorlagen lesbar', (select count(*) >= 20 from maintenance_templates));
select ht_test.set('r', public.save_maintenance_plan('{"property_id":"dddddddd-0000-4000-8000-000000000001","organization_id":"cccccccc-0000-4000-8000-000000000002","title":"HT Org-Test","interval_type":"once"}')::text);
select ht_test.ok('Organisation kommt aus dem Objekt, nicht aus der Eingabe', (select organization_id = 'cccccccc-0000-4000-8000-000000000001' from maintenance where id = ht_test.get('r')::uuid));
reset role;

rollback;
\echo '=== Hybrid-Service-Tests bestanden ==='
