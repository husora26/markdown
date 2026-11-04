-- =============================================================================
-- HUSORA · Hybrid Service & Smart Maintenance (Spezifikation „Hybrid Service Architecture“)
-- =============================================================================
-- Bestehendes wird erweitert, kein Parallelsystem (siehe docs/husora-service-audit.md):
--   Wartungsplan      = public.maintenance (erweitert)
--   Fälligkeit        = public.service_tasks (+ maintenance_id, generation_key, …); Lesesicht maintenance_occurrences
--   Serviceauftrag    = public.service_orders (Status-Engine bleibt) + Positionen public.service_order_items (neu)
--   Ausführung        = service_order_cost_items, photos/documents, service_order_events + Checkliste je Position
--   Dauerauftrag      = public.service_agreements (erweitert) + public.service_agreement_versions (neu)
--   Scheduler         = public.run_maintenance_scheduler() (idempotent, Advisory-Lock) + public.maintenance_runs
--   Vorlagen          = public.maintenance_templates (aus den App-Vorlagen)
-- Regeln: keine kostenpflichtige Beauftragung ohne explizite Freigabe (Einzelauftrag) oder gültigen,
-- vollständig geprüften Dauerauftrag; Fehler → Status „blockiert“ + Hinweis an den Eigentümer.
-- Zeiten in UTC, Berechnung in der Zeitzone des Plans. Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Vorlagenbibliothek
-- -----------------------------------------------------------------------------
create table if not exists public.maintenance_templates (
  id                      uuid primary key default gen_random_uuid(),
  key                     text not null unique check (key ~ '^[a-z0-9-]{2,60}$'),
  title                   text not null check (length(trim(title)) between 1 and 200),
  description             text check (description is null or length(description) <= 2000),
  category                text not null check (length(category) <= 80),
  task_type               text not null default 'recurring' check (task_type in ('recurring', 'seasonal', 'event', 'once', 'finding', 'repair')),
  default_interval_type   text not null check (default_interval_type in ('once', 'daily', 'weekly', 'every_n_weeks', 'monthly', 'every_n_months', 'quarterly', 'semi_annual', 'yearly', 'seasonal', 'custom')),
  default_interval_value  integer check (default_interval_value is null or default_interval_value between 1 and 366),
  priority                text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  season_start_month      smallint check (season_start_month is null or season_start_month between 1 and 12),
  season_end_month        smallint check (season_end_month is null or season_end_month between 1 and 12),
  checklist               jsonb not null default '[]'::jsonb check (jsonb_typeof(checklist) = 'array' and pg_column_size(checklist) <= 8000),
  is_public               boolean not null default true,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
comment on table public.maintenance_templates is 'Vorlagen für Wartungspläne (aus den bisherigen App-Vorlagen). Eine Vorlage ist kein aktiver Plan.';
alter table public.maintenance_templates enable row level security;
drop policy if exists maintenance_templates_read on public.maintenance_templates;
create policy maintenance_templates_read on public.maintenance_templates for select to authenticated using (is_public);
revoke all on public.maintenance_templates from anon, authenticated;
grant select on public.maintenance_templates to authenticated;
insert into public.maintenance_templates (key, title, category, task_type, default_interval_type, default_interval_value, priority, season_start_month, season_end_month) values
  ('tpl-smoke', 'Rauchmelder testen, Batterien und Prüfdatum der Feuerlöscher kontrollieren', 'Sicherheit', 'recurring', 'semi_annual', 1, 'urgent', null, null),
  ('tpl-chimney', 'Schornsteinfeger beauftragen (Sotning und Brandschutzkontrolle)', 'Sicherheit', 'seasonal', 'yearly', 1, 'urgent', 6, 8),
  ('tpl-locks', 'Schlösser, Schlüsselbox und Alarmanlage testen', 'Sicherheit', 'recurring', 'semi_annual', 1, 'high', null, null),
  ('tpl-electric', 'Elektrik prüfen: FI-Schalter testen, Sicherungen und Kabel kontrollieren', 'Sicherheit', 'recurring', 'yearly', 1, 'high', null, null),
  ('tpl-boiler', 'Heizungsanlage und Warmwasserbereiter warten lassen', 'Heizung, Wasser & Technik', 'seasonal', 'yearly', 1, 'high', 6, 8),
  ('tpl-heatpump', 'Wärmepumpe: Filter reinigen und Service', 'Heizung, Wasser & Technik', 'recurring', 'semi_annual', 1, 'normal', null, null),
  ('tpl-ventilation', 'Lüftung und Abluftfilter reinigen', 'Heizung, Wasser & Technik', 'recurring', 'semi_annual', 1, 'normal', null, null),
  ('tpl-well', 'Brunnenwasser untersuchen lassen (Wasserprobe)', 'Heizung, Wasser & Technik', 'seasonal', 'yearly', 1, 'high', 6, 8),
  ('tpl-septic', 'Kläranlage / Sammelgrube leeren lassen (Slamtömning)', 'Heizung, Wasser & Technik', 'seasonal', 'yearly', 1, 'high', 6, 8),
  ('tpl-sauna', 'Saunaofen und Schornstein prüfen', 'Heizung, Wasser & Technik', 'recurring', 'yearly', 1, 'normal', null, null),
  ('tpl-gutter', 'Dach und Dachrinnen nach dem Winter kontrollieren', 'Gebäude, Dach & Fenster', 'seasonal', 'yearly', 1, 'high', 4, 5),
  ('tpl-facade', 'Fassade und Holz auf Fäulnis prüfen, Falu-Farbe ausbessern', 'Gebäude, Dach & Fenster', 'seasonal', 'yearly', 1, 'normal', 6, 8),
  ('tpl-windows', 'Fenster putzen, Dichtungen und Rahmen prüfen', 'Gebäude, Dach & Fenster', 'recurring', 'semi_annual', 1, 'normal', null, null),
  ('tpl-crawlspace', 'Kriechkeller und Fundament auf Feuchtigkeit und Schimmel prüfen', 'Gebäude, Dach & Fenster', 'seasonal', 'yearly', 1, 'high', 4, 5),
  ('tpl-pests', 'Schädlingsschutz erneuern (Köderstationen, Wespennester entfernen)', 'Gebäude, Dach & Fenster', 'recurring', 'semi_annual', 1, 'normal', null, null),
  ('tpl-garden', 'Grundstück und Außenanlage pflegen', 'Garten & Außenbereich', 'seasonal', 'monthly', 1, 'normal', 6, 8),
  ('tpl-lawn', 'Rasen mähen und Wege freihalten', 'Garten & Außenbereich', 'seasonal', 'every_n_weeks', 2, 'normal', 5, 9),
  ('tpl-deck', 'Terrasse und Holzdeck reinigen und ölen', 'Garten & Außenbereich', 'seasonal', 'yearly', 1, 'normal', 4, 5),
  ('tpl-trees', 'Bäume und Sträucher schneiden, Laub entfernen', 'Garten & Außenbereich', 'seasonal', 'yearly', 1, 'normal', 9, 11),
  ('tpl-boat', 'Boot und Steg winterfest machen', 'Ferienhaus saisonal', 'seasonal', 'yearly', 1, 'normal', 10, 10),
  ('tpl-snow', 'Schneeräumung und Dachlast prüfen', 'Ferienhaus saisonal', 'seasonal', 'monthly', 1, 'high', 12, 3),
  ('tpl-inventory', 'Inventar prüfen und Verbrauchsmaterial auffüllen', 'Allgemeine Instandhaltung', 'recurring', 'quarterly', 1, 'normal', null, null),
  ('tpl-firstaid', 'Erste-Hilfe-Set und Notfallnummern aktualisieren', 'Allgemeine Instandhaltung', 'recurring', 'yearly', 1, 'normal', null, null),
  ('tpl-contracts', 'Versicherung, Strom-, Wasser- und Abfallverträge prüfen', 'Allgemeine Instandhaltung', 'seasonal', 'yearly', 1, 'normal', 1, 1),
  ('tpl-meter', 'Zählerstände ablesen und Verbrauch dokumentieren', 'Allgemeine Instandhaltung', 'recurring', 'quarterly', 1, 'normal', null, null)
on conflict (key) do update set title = excluded.title, category = excluded.category, task_type = excluded.task_type,
  default_interval_type = excluded.default_interval_type, default_interval_value = excluded.default_interval_value,
  priority = excluded.priority, season_start_month = excluded.season_start_month, season_end_month = excluded.season_end_month;

-- -----------------------------------------------------------------------------
-- 2) Wartungsplan = public.maintenance (erweitert)
-- -----------------------------------------------------------------------------
alter table public.maintenance
  add column if not exists template_id               uuid references public.maintenance_templates(id) on delete set null,
  add column if not exists task_type                 text not null default 'recurring',
  add column if not exists interval_type             text,
  add column if not exists interval_value            integer,
  add column if not exists interval_unit             text,
  add column if not exists weekday                   smallint,
  add column if not exists day_of_month              smallint,
  add column if not exists local_time                time not null default '09:00',
  add column if not exists timezone                  text not null default 'Europe/Stockholm',
  add column if not exists start_date                date,
  add column if not exists end_date                  date,
  add column if not exists assigned_type             text not null default 'owner',
  add column if not exists automation_mode           text not null default 'owner_self_service',
  add column if not exists service_agreement_id      uuid references public.service_agreements(id) on delete set null,
  add column if not exists budget_limit              numeric(12, 2),
  add column if not exists currency                  text not null default 'EUR',
  add column if not exists reminder_days             integer[] not null default '{7,1,0}',
  add column if not exists season_start_month        smallint,
  add column if not exists season_end_month          smallint,
  add column if not exists checklist                 jsonb not null default '[]'::jsonb,
  add column if not exists estimated_duration_minutes integer,
  add column if not exists lead_days                 integer not null default 14,
  add column if not exists priority                  text not null default 'normal',
  add column if not exists archived_at               timestamptz;
do $$
begin
  alter table public.maintenance drop constraint if exists maintenance_status_check;
  alter table public.maintenance add constraint maintenance_status_check check (status in ('active', 'due', 'overdue', 'paused', 'retired', 'archived'));
  if not exists (select 1 from pg_constraint where conname = 'maintenance_plan_check') then
    alter table public.maintenance add constraint maintenance_plan_check check (
      task_type in ('recurring', 'seasonal', 'event', 'once', 'finding', 'repair')
      and (interval_type is null or interval_type in ('once', 'daily', 'weekly', 'every_n_weeks', 'monthly', 'every_n_months', 'quarterly', 'semi_annual', 'yearly', 'seasonal', 'custom'))
      and (interval_value is null or interval_value between 1 and 366)
      and (interval_unit is null or interval_unit in ('day', 'week', 'month', 'year'))
      and (weekday is null or weekday between 1 and 7)
      and (day_of_month is null or day_of_month between 1 and 31)
      and (end_date is null or start_date is null or end_date >= start_date)
      and assigned_type in ('owner', 'partner', 'unassigned')
      and automation_mode in ('owner_approval', 'agreement_auto', 'owner_self_service', 'unassigned')
      and (budget_limit is null or budget_limit >= 0)
      and currency ~ '^[A-Z]{3}$'
      and (season_start_month is null or season_start_month between 1 and 12)
      and (season_end_month is null or season_end_month between 1 and 12)
      and jsonb_typeof(checklist) = 'array' and pg_column_size(checklist) <= 8000
      and (estimated_duration_minutes is null or estimated_duration_minutes between 1 and 10080)
      and lead_days between 1 and 120
      and priority in ('low', 'normal', 'high', 'urgent')
      and (description is null or length(description) <= 4000));
  end if;
end $$;
comment on table public.maintenance is 'Wartungsplan: dauerhafte Regel. Ein Plan ist nie selbst ein Auftrag; er erzeugt Fälligkeiten (service_tasks).';
create index if not exists maintenance_status_next_idx on public.maintenance (status, next_due_at);
create index if not exists maintenance_agreement_idx on public.maintenance (service_agreement_id) where service_agreement_id is not null;
create index if not exists maintenance_template_idx on public.maintenance (template_id) where template_id is not null;

-- Lesen: Eigentümer-Organisation; Partner sehen Pläne NICHT (Budget/Notizen sind privat) – sie bekommen Positionen
drop policy if exists maintenance_select on public.maintenance;
create policy maintenance_select on public.maintenance for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id));
-- Schreiben nur über save_maintenance_plan()/set_maintenance_plan_status() (Validierung serverseitig)
revoke insert, update, delete on public.maintenance from authenticated;

-- -----------------------------------------------------------------------------
-- 3) Fälligkeit = public.service_tasks (erweitert)
-- -----------------------------------------------------------------------------
alter table public.service_tasks
  add column if not exists maintenance_id        uuid references public.maintenance(id) on delete set null,
  add column if not exists generation_key        text,
  add column if not exists local_scheduled_date  date,
  add column if not exists assigned_type         text,
  add column if not exists owner_action          text,
  add column if not exists blocked_reason        text,
  add column if not exists skipped_at            timestamptz,
  add column if not exists skip_reason           text;
do $$
begin
  alter table public.service_tasks drop constraint if exists service_tasks_status_check;
  alter table public.service_tasks add constraint service_tasks_status_check
    check (status in ('pending', 'assigned', 'accepted', 'in_progress', 'completed', 'cancelled', 'skipped'));
  if not exists (select 1 from pg_constraint where conname = 'service_tasks_occurrence_check') then
    alter table public.service_tasks add constraint service_tasks_occurrence_check check (
      (assigned_type is null or assigned_type in ('owner', 'partner', 'unassigned'))
      and (owner_action is null or owner_action in ('self_service', 'approval_required', 'assign_partner', 'blocked'))
      and (blocked_reason is null or length(blocked_reason) <= 300)
      and (skip_reason is null or length(skip_reason) <= 500)
      and (status <> 'skipped' or skip_reason is not null));
  end if;
end $$;
create unique index if not exists service_tasks_generation_key_idx on public.service_tasks (generation_key) where generation_key is not null;
create index if not exists service_tasks_maintenance_idx on public.service_tasks (maintenance_id, local_scheduled_date) where maintenance_id is not null;
create index if not exists service_tasks_occurrence_idx on public.service_tasks (property_id, scheduled_start, status) where maintenance_id is not null;

-- Plan-Bezug und Erzeugungsschlüssel sind fest; abgeschlossene Fälligkeiten löscht kein normaler Nutzer
-- bewusst security invoker: in geprüften RPCs (security definer) gilt der Systemkontext, für direkte Client-Zugriffe nicht
create or replace function private.service_tasks_occurrence_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if private.is_system_context() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.maintenance_id is not null then
      raise exception 'Fälligkeiten aus Wartungsplänen werden nicht gelöscht – bitte überspringen oder den Plan pausieren' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.maintenance_id is not null then
    new.maintenance_id := old.maintenance_id; new.generation_key := old.generation_key; new.local_scheduled_date := old.local_scheduled_date;
    new.owner_action := old.owner_action; new.blocked_reason := old.blocked_reason; new.assigned_type := old.assigned_type;
    if old.status in ('completed', 'skipped') then new.status := old.status; new.completed_at := old.completed_at; end if;
  end if;
  return new;
end; $$;
drop trigger if exists service_tasks_occurrence_guard on public.service_tasks;
create trigger service_tasks_occurrence_guard before update or delete on public.service_tasks
  for each row execute function private.service_tasks_occurrence_guard();

-- -----------------------------------------------------------------------------
-- 4) Daueraufträge = public.service_agreements (erweitert) + Versionen
-- -----------------------------------------------------------------------------
alter table public.service_agreements
  add column if not exists pricing_type          text not null default 'annual',
  add column if not exists unit_price            numeric(12, 2),
  add column if not exists max_price_per_visit   numeric(12, 2),
  add column if not exists budget_period_amount  numeric(12, 2),
  add column if not exists budget_period         text not null default 'year',
  add column if not exists tax_mode              text not null default 'gross',
  add column if not exists approval_mode         text not null default 'owner_each',
  add column if not exists categories            text[] not null default '{}',
  add column if not exists window_months         smallint[],
  add column if not exists version               integer not null default 1,
  add column if not exists owner_accepted_at     timestamptz,
  add column if not exists partner_accepted_at   timestamptz,
  add column if not exists paused_at             timestamptz;
do $$
begin
  alter table public.service_agreements drop constraint if exists service_agreements_status_check;
  alter table public.service_agreements add constraint service_agreements_status_check check (status in ('proposed', 'active', 'paused', 'declined', 'ended', 'cancelled'));
  if not exists (select 1 from pg_constraint where conname = 'service_agreements_terms_check') then
    alter table public.service_agreements add constraint service_agreements_terms_check check (
      pricing_type in ('annual', 'per_visit', 'hourly', 'flat', 'quote_required')
      and (unit_price is null or unit_price >= 0) and (max_price_per_visit is null or max_price_per_visit >= 0)
      and (budget_period_amount is null or budget_period_amount >= 0)
      and budget_period in ('month', 'quarter', 'year', 'term')
      and tax_mode in ('gross', 'net', 'exempt')
      and approval_mode in ('owner_each', 'auto_within_limits')
      and cardinality(categories) <= 20
      and (window_months is null or window_months <@ array[1,2,3,4,5,6,7,8,9,10,11,12]::smallint[]));
  end if;
end $$;
comment on column public.service_agreements.approval_mode is 'owner_each = jeder Einsatz braucht Freigabe; auto_within_limits = Wartungspläne dürfen innerhalb Umfang/Preis/Budget automatisch beauftragen';

create table if not exists public.service_agreement_versions (
  id             uuid primary key default gen_random_uuid(),
  agreement_id   uuid not null references public.service_agreements(id) on delete cascade,
  version        integer not null,
  snapshot       jsonb not null,
  accepted_at    timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  unique (agreement_id, version)
);
comment on table public.service_agreement_versions is 'Unveränderliche Vertragsfassungen; Einsätze verweisen auf die damals gültige Version.';
alter table public.service_agreement_versions enable row level security;
drop policy if exists sav_select on public.service_agreement_versions;
create policy sav_select on public.service_agreement_versions for select to authenticated
  using (exists (select 1 from public.service_agreements a where a.id = agreement_id
                 and (private.can_read_org(a.organization_id) or private.is_partner_member(a.service_partner_id))));
revoke all on public.service_agreement_versions from anon, authenticated;
grant select on public.service_agreement_versions to authenticated;

create or replace function private.agreement_terms_snapshot(a public.service_agreements)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('title', a.title, 'task_titles', a.task_titles, 'categories', a.categories, 'pricing_type', a.pricing_type,
    'annual_price', a.annual_price, 'unit_price', a.unit_price, 'max_price_per_visit', a.max_price_per_visit,
    'budget_period_amount', a.budget_period_amount, 'budget_period', a.budget_period, 'currency', a.currency, 'tax_mode', a.tax_mode,
    'visits_per_year', a.visits_per_year, 'window_months', a.window_months, 'starts_on', a.starts_on, 'ends_on', a.ends_on,
    'approval_mode', a.approval_mode, 'property_id', a.property_id, 'service_partner_id', a.service_partner_id)
$$;
-- Zustimmungszeitpunkte und Versionen
create or replace function private.service_agreements_versioning()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or (new.status = 'proposed' and old.status is distinct from 'proposed') then
    new.owner_accepted_at := case when new.proposed_by = 'owner' then now() end;
    new.partner_accepted_at := case when new.proposed_by = 'partner' then now() end;
  elsif new.status = 'active' and old.status = 'proposed' then
    new.owner_accepted_at := coalesce(new.owner_accepted_at, now());
    new.partner_accepted_at := coalesce(new.partner_accepted_at, now());
  end if;
  return new;
end; $$;
drop trigger if exists service_agreements_versioning on public.service_agreements;
create trigger service_agreements_versioning before insert or update on public.service_agreements
  for each row execute function private.service_agreements_versioning();
create or replace function private.service_agreements_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active' or old.version is distinct from new.version) then
    insert into public.service_agreement_versions (agreement_id, version, snapshot)
    values (new.id, new.version, private.agreement_terms_snapshot(new))
    on conflict (agreement_id, version) do nothing;
  end if;
  return null;
end; $$;
drop trigger if exists service_agreements_snapshot on public.service_agreements;
create trigger service_agreements_snapshot after insert or update on public.service_agreements
  for each row execute function private.service_agreements_snapshot();
-- bestehende aktive Verträge: Fassung 1 festhalten
insert into public.service_agreement_versions (agreement_id, version, snapshot)
select a.id, a.version, private.agreement_terms_snapshot(a) from public.service_agreements a where a.status = 'active'
on conflict (agreement_id, version) do nothing;

-- Konditionen ändern (Preis, Umfang, Budget, Frequenz) → neue Version, Zustimmung der anderen Seite nötig
create or replace function public.update_agreement_terms(p_agreement_id uuid, p_terms jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_a public.service_agreements;
  v_side text;
  t jsonb := coalesce(p_terms, '{}'::jsonb);
begin
  select * into v_a from public.service_agreements a where a.id = p_agreement_id for update;
  if v_a.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  if private.is_org_staff(v_a.organization_id) then v_side := 'owner';
  elsif private.is_partner_member(v_a.service_partner_id) then v_side := 'partner';
  else raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_a.status not in ('proposed', 'active', 'paused') then raise exception 'Dieser Vertrag ist beendet' using errcode = '22023'; end if;
  update public.service_agreements a set
    pricing_type = coalesce(t ->> 'pricing_type', a.pricing_type),
    unit_price = case when t ? 'unit_price' then nullif(t ->> 'unit_price', '')::numeric else a.unit_price end,
    max_price_per_visit = case when t ? 'max_price_per_visit' then nullif(t ->> 'max_price_per_visit', '')::numeric else a.max_price_per_visit end,
    budget_period_amount = case when t ? 'budget_period_amount' then nullif(t ->> 'budget_period_amount', '')::numeric else a.budget_period_amount end,
    budget_period = coalesce(t ->> 'budget_period', a.budget_period),
    tax_mode = coalesce(t ->> 'tax_mode', a.tax_mode),
    approval_mode = coalesce(t ->> 'approval_mode', a.approval_mode),
    annual_price = case when t ? 'annual_price' then coalesce(nullif(t ->> 'annual_price', '')::numeric, a.annual_price) else a.annual_price end,
    categories = case when jsonb_typeof(t -> 'categories') = 'array' then array(select jsonb_array_elements_text(t -> 'categories')) else a.categories end,
    window_months = case when t ? 'window_months' then (case when jsonb_typeof(t -> 'window_months') = 'array' then array(select (jsonb_array_elements_text(t -> 'window_months'))::smallint) end) else a.window_months end,
    version = a.version + 1, status = 'proposed', proposed_by = v_side, proposed_by_user = private.current_user_id(), responded_at = null
  where a.id = v_a.id returning * into v_a;
  perform private.agreement_notify(v_a, v_side = 'owner', 'Vertragskonditionen geändert – bitte bestätigen');
  return jsonb_build_object('version', v_a.version, 'status', v_a.status);
end; $$;
revoke all on function public.update_agreement_terms(uuid, jsonb) from public, anon;
grant execute on function public.update_agreement_terms(uuid, jsonb) to authenticated;

create or replace function public.set_agreement_paused(p_agreement_id uuid, p_paused boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare v_a public.service_agreements;
begin
  select * into v_a from public.service_agreements a where a.id = p_agreement_id for update;
  if v_a.id is null or not (private.is_org_staff(v_a.organization_id) or private.is_partner_member(v_a.service_partner_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if p_paused and v_a.status <> 'active' then raise exception 'Nur aktive Verträge können pausiert werden' using errcode = '22023'; end if;
  if not p_paused and v_a.status <> 'paused' then raise exception 'Der Vertrag ist nicht pausiert' using errcode = '22023'; end if;
  update public.service_agreements set status = case when p_paused then 'paused' else 'active' end, paused_at = case when p_paused then now() end
  where id = v_a.id returning * into v_a;
  perform private.agreement_notify(v_a, private.is_org_staff(v_a.organization_id), case when p_paused then 'Vertrag pausiert' else 'Vertrag fortgesetzt' end);
  return v_a.status;
end; $$;
revoke all on function public.set_agreement_paused(uuid, boolean) from public, anon;
grant execute on function public.set_agreement_paused(uuid, boolean) to authenticated;

-- -----------------------------------------------------------------------------
-- 5) Serviceauftrag: Quelle, Abschlussbestätigung, Vertragsversion
-- -----------------------------------------------------------------------------
alter table public.service_orders
  add column if not exists source_type          text not null default 'manual',
  add column if not exists agreement_version    integer,
  add column if not exists owner_confirmed_at   timestamptz,
  add column if not exists owner_confirmed_by   uuid references public.users(id) on update cascade on delete set null,
  add column if not exists owner_dispute_note   text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'service_orders_source_check') then
    alter table public.service_orders add constraint service_orders_source_check check (
      source_type in ('manual', 'app_task', 'maintenance', 'agreement_auto', 'finding', 'emergency')
      and (owner_dispute_note is null or length(owner_dispute_note) <= 2000));
  end if;
end $$;
create index if not exists service_orders_partner_status_idx on public.service_orders (service_partner_id, status, scheduled_at);
create index if not exists service_orders_owner_confirmed_by_idx on public.service_orders (owner_confirmed_by) where owner_confirmed_by is not null;

-- -----------------------------------------------------------------------------
-- 6) Auftragspositionen (Bündelung; jede Position verweist auf höchstens eine Fälligkeit)
-- -----------------------------------------------------------------------------
create table if not exists public.service_order_items (
  id                 uuid primary key default gen_random_uuid(),
  service_order_id   uuid not null references public.service_orders(id) on delete cascade,
  occurrence_id      uuid references public.service_tasks(id) on delete set null,
  source_repair_id   uuid references public.repairs(id) on delete set null,
  title              text not null check (length(trim(title)) between 1 and 200),
  description        text check (description is null or length(description) <= 4000),
  category           text check (category is null or length(category) <= 80),
  quantity           numeric(10, 2) not null default 1 check (quantity > 0),
  unit               text check (unit is null or length(unit) <= 20),
  unit_price         numeric(12, 2) check (unit_price is null or unit_price >= 0),
  line_total         numeric(12, 2) generated always as (round(quantity * unit_price, 2)) stored,
  status             text not null default 'open' check (status in ('open', 'done', 'not_done', 'skipped')),
  checklist          jsonb not null default '[]'::jsonb check (jsonb_typeof(checklist) = 'array' and pg_column_size(checklist) <= 8000),
  checklist_results  jsonb not null default '{}'::jsonb check (jsonb_typeof(checklist_results) = 'object' and pg_column_size(checklist_results) <= 8000),
  partner_note       text check (partner_note is null or length(partner_note) <= 2000),
  sort_order         integer not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (service_order_id, occurrence_id)
);
comment on table public.service_order_items is 'Positionen eines Serviceauftrags (Bündelung mehrerer Fälligkeiten, Checkliste/Ergebnis je Position)';
create index if not exists soi_occurrence_idx on public.service_order_items (occurrence_id) where occurrence_id is not null;
create index if not exists soi_repair_idx on public.service_order_items (source_repair_id) where source_repair_id is not null;
drop trigger if exists soi_set_updated_at on public.service_order_items;
create trigger soi_set_updated_at before update on public.service_order_items for each row execute function private.set_updated_at();
drop trigger if exists service_order_items_audit on public.service_order_items;
create trigger service_order_items_audit after insert or update or delete on public.service_order_items for each row execute function private.audit_row_change();
alter table public.service_order_items enable row level security;
drop policy if exists soi_select on public.service_order_items;
create policy soi_select on public.service_order_items for select to authenticated using (private.can_read_service_order(service_order_id));
revoke all on public.service_order_items from anon, authenticated;
grant select on public.service_order_items to authenticated;

-- Eine Fälligkeit aus einem Wartungsplan gehört höchstens zu einem aktiven Auftrag
-- (App-Aufgaben ohne Plan dürfen weiterhin an mehrere Partner zum Preisvergleich gehen – bestehende Funktion)
create or replace function private.soi_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.occurrence_id is not null
     and exists (select 1 from public.service_tasks t where t.id = new.occurrence_id and t.maintenance_id is not null)
     and exists (select 1 from public.service_order_items i join public.service_orders o on o.id = i.service_order_id
                 where i.occurrence_id = new.occurrence_id and i.service_order_id <> new.service_order_id
                   and o.status not in ('rejected', 'cancelled', 'completed')) then
    raise exception 'Diese Fälligkeit ist bereits einem aktiven Auftrag zugeordnet' using errcode = '23505';
  end if;
  return new;
end; $$;
drop trigger if exists soi_guard on public.service_order_items;
create trigger soi_guard before insert or update of occurrence_id on public.service_order_items for each row execute function private.soi_guard();

-- jeder Auftrag hat mindestens eine Position (auch alle bestehenden Wege, die Aufträge anlegen)
create or replace function private.service_orders_default_item()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_plan public.maintenance;
begin
  select m.* into v_plan from public.service_tasks t join public.maintenance m on m.id = t.maintenance_id where t.id = new.service_task_id;
  insert into public.service_order_items (service_order_id, occurrence_id, title, description, category, checklist, unit_price)
  values (new.id, new.service_task_id, new.title, new.description, v_plan.category, coalesce(v_plan.checklist, '[]'::jsonb),
          case when new.source_type = 'agreement_auto' then new.estimated_cost end)
  on conflict (service_order_id, occurrence_id) do nothing;
  return null;
end; $$;
drop trigger if exists service_orders_default_item on public.service_orders;
create trigger service_orders_default_item after insert on public.service_orders for each row execute function private.service_orders_default_item();
-- Bestand: je Auftrag eine Position (stabile Bezüge, nichts geht verloren)
insert into public.service_order_items (service_order_id, occurrence_id, title, description, status)
select o.id, o.service_task_id, o.title, o.description, case when o.status = 'completed' then 'done' else 'open' end
from public.service_orders o
where not exists (select 1 from public.service_order_items i where i.service_order_id = o.id)
on conflict (service_order_id, occurrence_id) do nothing;
update public.service_order_items i set source_repair_id = r.id
from public.repairs r where r.service_order_id = i.service_order_id and i.source_repair_id is null;

-- -----------------------------------------------------------------------------
-- 7) Benachrichtigungen: Duplikatschutz
-- -----------------------------------------------------------------------------
alter table public.notifications add column if not exists dedupe_key text;
create unique index if not exists notifications_dedupe_idx on public.notifications (user_id, dedupe_key) where dedupe_key is not null;

create or replace function private.mt_notify_owner(p_org uuid, p_title text, p_message text, p_entity_type text, p_entity_id uuid, p_dedupe text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id, dedupe_key)
  select p_org, m.user_id, 'maintenance', 'maintenance', left(p_title, 200), left(p_message, 500), p_entity_type, p_entity_id, p_dedupe
  from public.organization_members m
  where m.organization_id = p_org and m.status = 'active' and m.role in ('admin', 'owner', 'property_manager', 'service_manager')
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
exception when others then raise warning 'Wartungshinweis nicht gespeichert: %', sqlerrm;
end; $$;

-- -----------------------------------------------------------------------------
-- 8) Terminberechnung (Objekt-/Planzeitzone, kein Monatsdrift, Monatsende, Schaltjahr, Saison)
-- -----------------------------------------------------------------------------
create or replace function private.mt_month_date(p_month_start date, p_day integer)
returns date language sql immutable set search_path = '' as $$
  select p_month_start + (least(greatest(p_day, 1), extract(day from (p_month_start + interval '1 month - 1 day'))::integer) - 1)
$$;
create or replace function private.mt_in_season(p_start smallint, p_end smallint, p_date date)
returns boolean language sql immutable set search_path = '' as $$
  select p_start is null or p_end is null
      or case when p_start <= p_end then extract(month from p_date) between p_start and p_end
              else extract(month from p_date) >= p_start or extract(month from p_date) <= p_end end
$$;
create or replace function private.mt_local_ts(p_date date, p_time time, p_tz text)
returns timestamptz language sql stable set search_path = '' as $$
  select ((p_date + coalesce(p_time, '09:00'::time))::timestamp at time zone coalesce(nullif(p_tz, ''), 'Europe/Stockholm'))
$$;
-- nächster Termin (lokales Datum) strikt nach p_after; null = kein weiterer Termin
create or replace function private.maintenance_next_date(p public.maintenance, p_after date)
returns date language plpgsql immutable set search_path = '' as $$
declare
  v_unit   text;
  v_step   integer;
  v_anchor date := p.start_date;
  v_dom    integer;
  v_k      integer;
  v_d      date;
  v_i      integer := 0;
begin
  if p.start_date is null or p.interval_type is null then return null; end if;
  if p.interval_type = 'once' then
    return case when p.start_date > p_after and (p.end_date is null or p.start_date <= p.end_date) then p.start_date end;
  end if;
  case p.interval_type
    when 'daily' then v_unit := 'day'; v_step := coalesce(p.interval_value, 1);
    when 'weekly' then v_unit := 'day'; v_step := 7;
    when 'every_n_weeks' then v_unit := 'day'; v_step := 7 * coalesce(p.interval_value, 2);
    when 'monthly' then v_unit := 'month'; v_step := 1;
    when 'every_n_months' then v_unit := 'month'; v_step := coalesce(p.interval_value, 2);
    when 'quarterly' then v_unit := 'month'; v_step := 3;
    when 'semi_annual' then v_unit := 'month'; v_step := 6;
    when 'yearly' then v_unit := 'month'; v_step := 12;
    when 'seasonal' then v_unit := 'month'; v_step := 12;
    else  -- custom
      v_unit := case when p.interval_unit in ('month', 'year') then 'month' else 'day' end;
      v_step := coalesce(p.interval_value, 1) * case p.interval_unit when 'week' then 7 when 'year' then 12 else 1 end;
  end case;
  v_step := greatest(v_step, 1);
  if v_unit = 'day' then
    if p.weekday is not null and (p.interval_type in ('weekly', 'every_n_weeks') or p.interval_unit = 'week') then
      v_anchor := p.start_date + ((p.weekday - extract(isodow from p.start_date)::integer + 7) % 7);
    end if;
    v_k := greatest(0, floor((greatest(p_after, v_anchor) - v_anchor)::numeric / v_step)::integer - 1);
  else
    v_dom := coalesce(p.day_of_month, extract(day from p.start_date)::integer);
    v_anchor := date_trunc('month', p.start_date)::date;
    v_k := greatest(0, floor(((extract(year from greatest(p_after, p.start_date)) - extract(year from v_anchor)) * 12
                              + extract(month from greatest(p_after, p.start_date)) - extract(month from v_anchor)) / v_step)::integer - 1);
  end if;
  loop
    v_d := case when v_unit = 'day' then v_anchor + v_k * v_step
                else private.mt_month_date((v_anchor + make_interval(months => v_k * v_step))::date, v_dom) end;
    if p.end_date is not null and v_d > p.end_date then return null; end if;
    if v_d > p_after and v_d >= p.start_date and private.mt_in_season(p.season_start_month, p.season_end_month, v_d) then return v_d; end if;
    v_k := v_k + 1; v_i := v_i + 1;
    exit when v_i > 2000;
  end loop;
  return null;
end; $$;

-- Vorschau der nächsten Termine (Formular) – ohne Datenzugriff
create or replace function public.maintenance_preview(p_plan jsonb, p_count integer default 5)
returns table (local_date date, scheduled_for timestamptz)
language plpgsql stable set search_path = '' as $$
declare
  p public.maintenance := jsonb_populate_record(null::public.maintenance, coalesce(p_plan, '{}'::jsonb));
  v_d date := coalesce(p.start_date, current_date) - 1;
  v_n integer := 0;
begin
  p.start_date := coalesce(p.start_date, current_date);
  loop
    v_d := private.maintenance_next_date(p, v_d);
    exit when v_d is null or v_n >= least(greatest(coalesce(p_count, 5), 1), 24);
    local_date := v_d; scheduled_for := private.mt_local_ts(v_d, p.local_time, p.timezone);
    return next; v_n := v_n + 1;
  end loop;
end; $$;
revoke all on function public.maintenance_preview(jsonb, integer) from public, anon;
grant execute on function public.maintenance_preview(jsonb, integer) to authenticated;

-- -----------------------------------------------------------------------------
-- 9) Vertragsprüfung (maschinenlesbarer Grund)
-- -----------------------------------------------------------------------------
create or replace function private.validate_service_agreement(p_agreement_id uuid, p_property_id uuid, p_service_partner_id uuid,
                                                              p_title text, p_category text, p_date date, p_plan_budget numeric default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  a      public.service_agreements;
  sp     public.service_partners;
  v_price numeric;
  v_from date; v_to date; v_spent numeric;
  fail   text;
begin
  select * into a from public.service_agreements x where x.id = p_agreement_id;
  if a.id is null then return jsonb_build_object('ok', false, 'code', 'not_found', 'reason', 'Kein Dauerauftrag hinterlegt'); end if;
  if a.status = 'paused' then return jsonb_build_object('ok', false, 'code', 'paused', 'reason', 'Dauerauftrag ist pausiert'); end if;
  if a.status <> 'active' then return jsonb_build_object('ok', false, 'code', 'not_active', 'reason', 'Dauerauftrag ist nicht aktiv'); end if;
  if a.approval_mode <> 'auto_within_limits' then return jsonb_build_object('ok', false, 'code', 'approval_mode', 'reason', 'Vertrag erlaubt keine automatische Beauftragung'); end if;
  if p_date < a.starts_on or p_date > a.ends_on then return jsonb_build_object('ok', false, 'code', 'expired', 'reason', 'Termin liegt außerhalb der Vertragslaufzeit'); end if;
  if a.property_id is distinct from p_property_id then return jsonb_build_object('ok', false, 'code', 'wrong_property', 'reason', 'Vertrag gilt für ein anderes Objekt'); end if;
  if p_service_partner_id is not null and a.service_partner_id <> p_service_partner_id then
    return jsonb_build_object('ok', false, 'code', 'wrong_partner', 'reason', 'Vertrag gehört zu einem anderen Servicepartner');
  end if;
  select * into sp from public.service_partners x where x.id = a.service_partner_id;
  if sp.id is null or sp.partner_organization_id is null or sp.disconnected_at is not null then
    return jsonb_build_object('ok', false, 'code', 'partner_inactive', 'reason', 'Servicepartner ist nicht (mehr) verbunden');
  end if;
  if exists (select 1 from public.property_service_assignments x where x.property_id = p_property_id and x.status = 'active')
     and not exists (select 1 from public.property_service_assignments x where x.property_id = p_property_id and x.status = 'active' and x.service_partner_id = sp.id) then
    return jsonb_build_object('ok', false, 'code', 'partner_not_assigned', 'reason', 'Servicepartner ist dem Objekt nicht zugeordnet');
  end if;
  if not (coalesce(p_category, '') = any (a.categories) or private.agreement_covers(a.task_titles, coalesce(p_title, ''))) then
    return jsonb_build_object('ok', false, 'code', 'out_of_scope', 'reason', 'Leistung ist nicht im Vertragsumfang');
  end if;
  if a.window_months is not null and not (extract(month from p_date)::smallint = any (a.window_months)) then
    return jsonb_build_object('ok', false, 'code', 'outside_window', 'reason', 'Termin liegt außerhalb des vereinbarten Zeitfensters');
  end if;
  v_price := case a.pricing_type
               when 'per_visit' then a.unit_price
               when 'flat' then a.unit_price
               when 'annual' then case when a.annual_price is not null and a.visits_per_year > 0 then round(a.annual_price / a.visits_per_year, 2) end
               else null end;   -- hourly / quote_required: kein eindeutiger Preis vorab
  if v_price is null then return jsonb_build_object('ok', false, 'code', 'price_unclear', 'reason', 'Preis je Einsatz ist nicht eindeutig (Angebot oder Stundenpreis)'); end if;
  if a.max_price_per_visit is not null and v_price > a.max_price_per_visit then
    return jsonb_build_object('ok', false, 'code', 'over_max_per_visit', 'reason', 'Preis je Einsatz über dem vereinbarten Maximum', 'price', v_price);
  end if;
  if p_plan_budget is not null and v_price > p_plan_budget then
    return jsonb_build_object('ok', false, 'code', 'over_plan_budget', 'reason', 'Preis über der Budgetgrenze des Wartungsplans', 'price', v_price);
  end if;
  if a.budget_period_amount is not null then
    v_from := case a.budget_period when 'month' then date_trunc('month', p_date)::date when 'quarter' then date_trunc('quarter', p_date)::date
                                   when 'year' then date_trunc('year', p_date)::date else a.starts_on end;
    v_to := case a.budget_period when 'month' then (date_trunc('month', p_date) + interval '1 month')::date when 'quarter' then (date_trunc('quarter', p_date) + interval '3 months')::date
                                 when 'year' then (date_trunc('year', p_date) + interval '1 year')::date else a.ends_on + 1 end;
    select coalesce(sum(coalesce(o.actual_cost, o.estimated_cost, 0)), 0) into v_spent from public.service_orders o
    where o.agreement_id = a.id and o.status not in ('rejected', 'cancelled')
      and coalesce(o.scheduled_at, o.created_at)::date >= v_from and coalesce(o.scheduled_at, o.created_at)::date < v_to;
    if v_spent + v_price > a.budget_period_amount then
      return jsonb_build_object('ok', false, 'code', 'over_period_budget', 'reason', 'Budget des Abrechnungszeitraums würde überschritten', 'price', v_price, 'spent', v_spent);
    end if;
  end if;
  if exists (select 1 from public.service_partner_absences x where x.organization_id = sp.partner_organization_id and x.user_id is null
             and p_date between x.start_at::date and x.end_at::date) then
    return jsonb_build_object('ok', false, 'code', 'partner_absent', 'reason', 'Servicepartner ist an diesem Termin abwesend');
  end if;
  return jsonb_build_object('ok', true, 'code', 'ok', 'price', v_price, 'currency', a.currency, 'version', a.version);
end; $$;
-- öffentlich nur für Beteiligte
create or replace function public.validate_service_agreement(p_agreement_id uuid, p_property_id uuid, p_title text, p_category text, p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_a public.service_agreements;
begin
  select * into v_a from public.service_agreements a where a.id = p_agreement_id;
  if v_a.id is null or not (private.can_read_org(v_a.organization_id) or private.is_partner_member(v_a.service_partner_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  return private.validate_service_agreement(p_agreement_id, p_property_id, null, p_title, p_category, p_date, null);
end; $$;
revoke all on function public.validate_service_agreement(uuid, uuid, text, text, date) from public, anon;
grant execute on function public.validate_service_agreement(uuid, uuid, text, text, date) to authenticated;

-- -----------------------------------------------------------------------------
-- 10) Bestandspläne (interval_days) auf die neue Regel abbilden – nichts geht verloren
-- -----------------------------------------------------------------------------
update public.maintenance m
set interval_type = 'custom', interval_value = least(m.interval_days, 366), interval_unit = 'day',
    start_date = coalesce(m.start_date, m.next_due_at::date, current_date)
where m.interval_type is null and m.interval_days is not null;
-- alter Trigger rechnet nur noch für Pläne ohne neue Regel
create or replace function private.maintenance_next_due()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.interval_type is null and new.interval_days is not null and new.last_performed_at is not null
     and (tg_op = 'INSERT' or new.last_performed_at is distinct from old.last_performed_at or new.interval_days is distinct from old.interval_days) then
    new.next_due_at := new.last_performed_at + make_interval(days => new.interval_days);
    if new.status in ('due', 'overdue') then new.status := 'active'; end if;
  end if;
  return new;
end; $$;

-- -----------------------------------------------------------------------------
-- 11) Läufe des Schedulers
-- -----------------------------------------------------------------------------
create table if not exists public.maintenance_runs (
  id                   uuid primary key default gen_random_uuid(),
  started_at           timestamptz not null default now(),
  finished_at          timestamptz,
  trigger_source       text not null default 'cron' check (trigger_source in ('cron', 'manual', 'plan')),
  plan_id              uuid references public.maintenance(id) on delete set null,
  status               text not null default 'running' check (status in ('running', 'ok', 'partial', 'failed', 'skipped_locked')),
  plans_processed      integer not null default 0,
  plans_failed         integer not null default 0,
  occurrences_created  integer not null default 0,
  orders_created       integer not null default 0,
  blocked              integer not null default 0,
  owner_actions        integer not null default 0,
  reminders_sent       integer not null default 0,
  errors               jsonb not null default '[]'::jsonb check (jsonb_typeof(errors) = 'array')
);
comment on table public.maintenance_runs is 'Protokoll der Wartungs-Scheduler-Läufe (Zähler, Fehler je Plan). Nur Server/Plattform-Admins.';
create index if not exists maintenance_runs_started_idx on public.maintenance_runs (started_at desc);
create index if not exists maintenance_runs_plan_idx on public.maintenance_runs (plan_id) where plan_id is not null;
alter table public.maintenance_runs enable row level security;
drop policy if exists maintenance_runs_admin on public.maintenance_runs;
create policy maintenance_runs_admin on public.maintenance_runs for select to authenticated using (private.is_any_admin());
revoke all on public.maintenance_runs from anon, authenticated;
grant select on public.maintenance_runs to authenticated;

-- Auftragsereignisse: neue Typen
alter table public.service_order_events drop constraint if exists service_order_events_event_type_check;
alter table public.service_order_events add constraint service_order_events_event_type_check check (event_type in (
  'created', 'status_changed', 'reopened', 'scheduled', 'assigned', 'note', 'owner_confirmed', 'owner_disputed', 'item_updated', 'bundled', 'no_show'));

-- -----------------------------------------------------------------------------
-- 12) Hilfen: aktiver Auftrag einer Fälligkeit, nächste Fälligkeit eines Plans
-- -----------------------------------------------------------------------------
create or replace function private.mt_active_order(p_task_id uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select o.id from public.service_order_items i join public.service_orders o on o.id = i.service_order_id
  where i.occurrence_id = p_task_id and o.status not in ('rejected', 'cancelled', 'completed')
  order by o.created_at desc limit 1
$$;
create or replace function private.mt_refresh_plan_due(p_plan_id uuid)
returns void language sql security definer set search_path = '' as $$
  update public.maintenance m
  set next_due_at = (select min(t.scheduled_start) from public.service_tasks t
                     where t.maintenance_id = m.id and t.status not in ('completed', 'skipped', 'cancelled'))
  where m.id = p_plan_id
$$;
create or replace function private.mt_notify_partner(p_service_partner_id uuid, p_title text, p_message text, p_order uuid, p_dedupe text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id, dedupe_key)
  select sp.partner_organization_id, m.user_id, 'service_order', 'order', left(p_title, 200), left(p_message, 500), 'service_order', p_order, p_dedupe
  from public.service_partners sp join public.organization_members m on m.organization_id = sp.partner_organization_id
  where sp.id = p_service_partner_id and sp.partner_organization_id is not null and m.status = 'active'
    and m.role in ('admin', 'service_manager', 'dispatcher')
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
exception when others then raise warning 'Partnerhinweis nicht gespeichert: %', sqlerrm;
end; $$;

-- -----------------------------------------------------------------------------
-- 13) Hybrid-Beauftragung einer Fälligkeit (Regelwerk)
-- -----------------------------------------------------------------------------
create or replace function private.maintenance_process_task(t public.service_tasks, p public.maintenance)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_check   jsonb;
  v_a       public.service_agreements;
  v_order   uuid;
  v_label   text := to_char(coalesce(t.local_scheduled_date, t.scheduled_start::date), 'DD.MM.YYYY');
begin
  if private.mt_active_order(t.id) is not null then return 'has_order'; end if;
  case p.automation_mode
    when 'owner_self_service' then
      update public.service_tasks set owner_action = 'self_service', blocked_reason = null where id = t.id;
      return 'self_service';
    when 'unassigned' then
      update public.service_tasks set owner_action = 'assign_partner', blocked_reason = null where id = t.id;
      perform private.mt_notify_owner(p.organization_id, 'Zuständigkeit fehlt: ' || t.title,
        'Fällig am ' || v_label || ' – bitte selbst erledigen oder einen Servicepartner wählen.', 'service_task', t.id, 'mt:' || t.id || ':assign');
      return 'owner_action';
    when 'owner_approval' then
      update public.service_tasks set owner_action = 'approval_required', blocked_reason = null where id = t.id;
      perform private.mt_notify_owner(p.organization_id, 'Service erforderlich: ' || t.title,
        'Fällig am ' || v_label || ' – Freigabe nötig: Servicepartner beauftragen oder selbst erledigen.', 'service_task', t.id, 'mt:' || t.id || ':approval');
      return 'owner_action';
    else -- agreement_auto: nur nach vollständiger Vertragsprüfung
      v_check := private.validate_service_agreement(p.service_agreement_id, p.property_id, p.assigned_partner_id, t.title, p.category,
                                                    coalesce(t.local_scheduled_date, t.scheduled_start::date), p.budget_limit);
      if not coalesce((v_check ->> 'ok')::boolean, false) then
        update public.service_tasks set owner_action = 'blocked', blocked_reason = left(v_check ->> 'reason', 300) where id = t.id;
        perform private.mt_notify_owner(p.organization_id, 'Automatische Beauftragung gestoppt: ' || t.title,
          (v_check ->> 'reason') || ' (Termin ' || v_label || '). Es wurde kein Auftrag gesendet.', 'service_task', t.id,
          'mt:' || t.id || ':blocked:' || (v_check ->> 'code'));
        return 'blocked';
      end if;
      select * into v_a from public.service_agreements a where a.id = p.service_agreement_id;
      begin
        insert into public.service_orders (organization_id, property_id, service_partner_id, service_task_id, agreement_id, agreement_version,
                                           source_type, title, description, status, scheduled_at, scheduled_end, estimated_cost, currency,
                                           requires_approval, approval_status, priority, estimated_minutes, recurrence_key, response_note)
        values (p.organization_id, p.property_id, v_a.service_partner_id, t.id, v_a.id, v_a.version,
                'agreement_auto', t.title, t.description, 'offered', t.scheduled_start, t.scheduled_end, (v_check ->> 'price')::numeric, v_a.currency,
                false, 'approved', t.priority, p.estimated_duration_minutes, 'mt:' || t.generation_key,
                'Automatisch aus Dauerauftrag „' || v_a.title || '“ (Fassung ' || v_a.version || ')')
        on conflict (recurrence_key) where recurrence_key is not null do nothing
        returning id into v_order;
      exception when others then
        update public.service_tasks set owner_action = 'blocked', blocked_reason = left('Auftrag konnte nicht erstellt werden: ' || sqlerrm, 300) where id = t.id;
        perform private.mt_notify_owner(p.organization_id, 'Automatische Beauftragung gestoppt: ' || t.title, left(sqlerrm, 300), 'service_task', t.id, 'mt:' || t.id || ':blocked:error');
        return 'blocked';
      end;
      update public.service_tasks set owner_action = null, blocked_reason = null where id = t.id;
      return case when v_order is null then 'has_order' else 'order' end;
  end case;
end; $$;

-- -----------------------------------------------------------------------------
-- 14) Scheduler je Plan (idempotent: Erzeugungsschlüssel Plan:Datum, Sperre je Plan)
-- -----------------------------------------------------------------------------
create or replace function private.maintenance_schedule_plan(p_plan_id uuid, p_horizon_days integer default 60)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p          public.maintenance;
  t          public.service_tasks;
  v_today    date;
  v_last     date;
  v_from     date;
  v_d        date;
  v_id       uuid;
  v_n        integer := 0;
  v_created  integer := 0;
  v_orders   integer := 0;
  v_blocked  integer := 0;
  v_actions  integer := 0;
  v_rem      integer := 0;
  v_res      text;
  v_days     integer;
  v_horizon  integer;
begin
  perform pg_advisory_xact_lock(hashtext('husora-maintenance-plan'), hashtext(p_plan_id::text));
  select * into p from public.maintenance m where m.id = p_plan_id;
  if p.id is null or p.status <> 'active' or p.archived_at is not null or p.interval_type is null or p.start_date is null then
    return jsonb_build_object('skipped', true);
  end if;
  v_today := (now() at time zone p.timezone)::date;
  v_horizon := greatest(p.lead_days, least(coalesce(p_horizon_days, 60), 400));

  -- a) Fälligkeiten erzeugen (keine Rückwirkung: ab heute; Einmal-Termin auch rückwirkend)
  select max(x.local_scheduled_date) into v_last from public.service_tasks x where x.maintenance_id = p.id;
  v_from := case when p.interval_type = 'once' then coalesce(v_last, p.start_date - 1)
                 else greatest(coalesce(v_last, p.start_date - 1), v_today - 1) end;
  loop
    v_d := private.maintenance_next_date(p, v_from);
    exit when v_d is null or v_d > v_today + v_horizon or v_n >= 120;
    insert into public.service_tasks (organization_id, property_id, service_type_id, title, description, priority, status,
                                      scheduled_start, scheduled_end, maintenance_id, generation_key, local_scheduled_date, assigned_type)
    values (p.organization_id, p.property_id, p.service_type_id, p.title, p.description, p.priority, 'pending',
            private.mt_local_ts(v_d, p.local_time, p.timezone),
            private.mt_local_ts(v_d, p.local_time, p.timezone) + make_interval(mins => coalesce(p.estimated_duration_minutes, 60)),
            p.id, p.id::text || ':' || v_d::text, v_d, p.assigned_type)
    on conflict (generation_key) where generation_key is not null do nothing
    returning id into v_id;
    if v_id is not null then v_created := v_created + 1; end if;
    v_from := v_d; v_n := v_n + 1;
  end loop;

  -- b) Regelwerk für Fälligkeiten im Vorlauf (blockierte Vertragsfälligkeiten werden erneut geprüft)
  for t in
    select x.* from public.service_tasks x
    where x.maintenance_id = p.id and x.status = 'pending' and x.local_scheduled_date <= v_today + p.lead_days
      and x.local_scheduled_date >= v_today - 30
      and (x.owner_action is null or (x.owner_action = 'blocked' and p.automation_mode = 'agreement_auto'))
    order by x.local_scheduled_date limit 50
  loop
    v_res := private.maintenance_process_task(t, p);
    if v_res = 'order' then v_orders := v_orders + 1;
    elsif v_res = 'blocked' then v_blocked := v_blocked + 1;
    elsif v_res = 'owner_action' then v_actions := v_actions + 1; end if;
  end loop;

  -- c) Erinnerungen an den Eigentümer (7/1/0 Tage, einmalig je Fälligkeit und Stufe) + Überfälligkeit
  for t in
    select x.* from public.service_tasks x
    where x.maintenance_id = p.id and x.status = 'pending' and x.owner_action is not null
      and x.local_scheduled_date between v_today - 60 and v_today + 31
  loop
    v_days := (t.scheduled_start at time zone p.timezone)::date - v_today;
    if v_days = any (p.reminder_days) then
      perform private.mt_notify_owner(p.organization_id,
        case when v_days = 0 then 'Heute fällig: ' when v_days = 1 then 'Morgen fällig: ' else 'In ' || v_days || ' Tagen fällig: ' end || t.title,
        case t.owner_action when 'self_service' then 'Bitte erledigen und abhaken.' when 'blocked' then coalesce(t.blocked_reason, 'Automatische Beauftragung gestoppt.')
                            else 'Bitte entscheiden: Servicepartner beauftragen oder selbst erledigen.' end,
        'service_task', t.id, 'mt:' || t.id || ':r' || v_days);
      v_rem := v_rem + 1;
    elsif v_days < 0 then
      perform private.mt_notify_owner(p.organization_id, 'Überfällig: ' || t.title,
        'War fällig am ' || to_char(t.local_scheduled_date, 'DD.MM.YYYY') || '.', 'service_task', t.id, 'mt:' || t.id || ':overdue');
    end if;
  end loop;
  -- Partner: Erinnerung am Vortag für angenommene Einsätze
  for t in
    select x.* from public.service_tasks x
    where x.maintenance_id = p.id and x.status = 'accepted' and (x.scheduled_start at time zone p.timezone)::date = v_today + 1
  loop
    perform private.mt_notify_partner(t.assigned_partner_id, 'Morgen: ' || t.title,
      coalesce((select pr.name from public.properties pr where pr.id = t.property_id), '') || ' · ' || to_char(t.scheduled_start at time zone p.timezone, 'DD.MM.YYYY HH24:MI'),
      private.mt_active_order(t.id), 'mt:' || t.id || ':p1');
  end loop;

  perform private.mt_refresh_plan_due(p.id);
  return jsonb_build_object('created', v_created, 'orders', v_orders, 'blocked', v_blocked, 'owner_actions', v_actions, 'reminders', v_rem);
end; $$;

-- Gesamtlauf (pg_cron, täglich): globale Sperre gegen parallele Läufe, Fehler je Plan isoliert, Lauf protokolliert
create or replace function public.run_maintenance_scheduler(p_horizon_days integer default 60)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_run    uuid;
  v_plan   uuid;
  v_r      jsonb;
  v_ok     integer := 0;
  v_failed integer := 0;
  v_err    jsonb := '[]'::jsonb;
  v_sum    jsonb := '{"created":0,"orders":0,"blocked":0,"owner_actions":0,"reminders":0}'::jsonb;
  k        text;
begin
  if not pg_try_advisory_xact_lock(hashtext('husora-maintenance-scheduler')) then
    insert into public.maintenance_runs (status, finished_at) values ('skipped_locked', now()) returning id into v_run;
    return jsonb_build_object('run_id', v_run, 'status', 'skipped_locked');
  end if;
  insert into public.maintenance_runs (trigger_source) values (case when auth.uid() is null then 'cron' else 'manual' end) returning id into v_run;
  for v_plan in
    select m.id from public.maintenance m
    where m.status = 'active' and m.archived_at is null and m.interval_type is not null
    order by m.next_due_at nulls first, m.id limit 5000
  loop
    begin
      v_r := private.maintenance_schedule_plan(v_plan, p_horizon_days);
      if not coalesce((v_r ->> 'skipped')::boolean, false) then
        v_ok := v_ok + 1;
        foreach k in array array['created', 'orders', 'blocked', 'owner_actions', 'reminders'] loop
          v_sum := jsonb_set(v_sum, array[k], to_jsonb((v_sum ->> k)::integer + coalesce((v_r ->> k)::integer, 0)));
        end loop;
      end if;
    exception when others then
      v_failed := v_failed + 1;
      if jsonb_array_length(v_err) < 50 then v_err := v_err || jsonb_build_object('plan_id', v_plan, 'error', left(sqlerrm, 300)); end if;
    end;
  end loop;
  update public.maintenance_runs set finished_at = now(),
    status = case when v_failed = 0 then 'ok' when v_ok > 0 then 'partial' else 'failed' end,
    plans_processed = v_ok, plans_failed = v_failed, occurrences_created = (v_sum ->> 'created')::integer,
    orders_created = (v_sum ->> 'orders')::integer, blocked = (v_sum ->> 'blocked')::integer,
    owner_actions = (v_sum ->> 'owner_actions')::integer, reminders_sent = (v_sum ->> 'reminders')::integer, errors = v_err
  where id = v_run;
  return v_sum || jsonb_build_object('run_id', v_run, 'plans', v_ok, 'failed', v_failed);
end; $$;
revoke all on function public.run_maintenance_scheduler(integer) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 15) Wartungsplan anlegen/ändern (Validierung serverseitig, Organisation aus dem Objekt)
-- -----------------------------------------------------------------------------
create or replace function public.save_maintenance_plan(p_plan jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  j        jsonb := coalesce(p_plan, '{}'::jsonb);
  v_old    public.maintenance;
  v_prop   public.properties;
  v_tpl    public.maintenance_templates;
  v_sp     public.service_partners;
  v_a      public.service_agreements;
  v_id     uuid := nullif(j ->> 'id', '')::uuid;
  v_mode   text;
  v_type   text;
  v_tz     text;
  v_partner uuid := nullif(j ->> 'assigned_partner_id', '')::uuid;
  v_agree  uuid := nullif(j ->> 'service_agreement_id', '')::uuid;
  v_start  date;
  v_today  date;
begin
  if v_id is not null then
    select * into v_old from public.maintenance m where m.id = v_id for update;
    if v_old.id is null then raise exception 'Wartungsplan nicht gefunden' using errcode = 'P0002'; end if;
  end if;
  select * into v_prop from public.properties pr where pr.id = coalesce(v_old.property_id, nullif(j ->> 'property_id', '')::uuid);
  if v_prop.id is null then raise exception 'Bitte ein Objekt wählen' using errcode = '22023'; end if;
  if not (private.is_org_staff(v_prop.organization_id) or private.can_manage_property(v_prop.id)) then
    raise exception 'Keine Berechtigung für dieses Objekt' using errcode = '42501';
  end if;
  if v_old.id is not null and nullif(j ->> 'property_id', '')::uuid is distinct from null and (j ->> 'property_id')::uuid <> v_old.property_id then
    raise exception 'Das Objekt eines Plans kann nicht geändert werden – bitte einen neuen Plan anlegen' using errcode = '22023';
  end if;
  if nullif(j ->> 'template_key', '') is not null then
    select * into v_tpl from public.maintenance_templates x where x.key = j ->> 'template_key';
  end if;

  v_mode := coalesce(nullif(j ->> 'automation_mode', ''), v_old.automation_mode, 'owner_self_service');
  if v_mode not in ('owner_approval', 'agreement_auto', 'owner_self_service', 'unassigned') then
    raise exception 'Unbekannter Beauftragungsmodus' using errcode = '22023';
  end if;
  v_type := coalesce(nullif(j ->> 'interval_type', ''), v_old.interval_type, v_tpl.default_interval_type);
  if v_type is null then raise exception 'Bitte ein Intervall wählen' using errcode = '22023'; end if;
  v_tz := coalesce(nullif(j ->> 'timezone', ''), v_old.timezone, (select o.timezone from public.organizations o where o.id = v_prop.organization_id), 'Europe/Stockholm');
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
    raise exception 'Unbekannte Zeitzone %', v_tz using errcode = '22023';
  end if;
  v_today := (now() at time zone v_tz)::date;
  v_start := coalesce(nullif(j ->> 'start_date', '')::date, v_old.start_date, v_today);
  if not (j ? 'assigned_partner_id') then v_partner := v_old.assigned_partner_id; end if;
  if not (j ? 'service_agreement_id') then v_agree := v_old.service_agreement_id; end if;
  if v_mode in ('owner_self_service', 'unassigned') then v_partner := null; v_agree := null; end if;

  -- Vertrag (nur für agreement_auto; sonst optionaler Bezug)
  if v_mode = 'agreement_auto' then
    select * into v_a from public.service_agreements a where a.id = v_agree;
    if v_a.id is null or v_a.organization_id <> v_prop.organization_id or v_a.property_id is distinct from v_prop.id then
      raise exception 'Für die automatische Beauftragung bitte einen Dauerauftrag für dieses Objekt wählen' using errcode = '22023';
    end if;
    if v_a.status <> 'active' then raise exception 'Der Dauerauftrag ist nicht aktiv (Status: %)', v_a.status using errcode = '22023'; end if;
    if v_a.approval_mode <> 'auto_within_limits' then
      raise exception 'Der Dauerauftrag erlaubt keine automatische Beauftragung – Freigabeart im Vertrag anpassen oder „Freigabe je Einsatz“ wählen' using errcode = '22023';
    end if;
    if v_partner is not null and v_partner <> v_a.service_partner_id then
      raise exception 'Der gewählte Servicepartner passt nicht zum Dauerauftrag' using errcode = '22023';
    end if;
    v_partner := v_a.service_partner_id;
  elsif v_agree is not null then
    select * into v_a from public.service_agreements a where a.id = v_agree;
    if v_a.id is null or v_a.organization_id <> v_prop.organization_id then raise exception 'Dauerauftrag nicht gefunden' using errcode = '22023'; end if;
  end if;
  -- Partner: aus dem eigenen Partnerverzeichnis, aktiv, und dem Objekt zugeordnet (falls Zuordnungen bestehen)
  if v_partner is not null then
    select * into v_sp from public.service_partners sp where sp.id = v_partner;
    if v_sp.id is null or v_sp.organization_id <> v_prop.organization_id or v_sp.status <> 'active' then
      raise exception 'Servicepartner nicht gefunden oder nicht aktiv' using errcode = '22023';
    end if;
    if exists (select 1 from public.property_service_assignments x where x.property_id = v_prop.id and x.status = 'active')
       and not exists (select 1 from public.property_service_assignments x where x.property_id = v_prop.id and x.status = 'active' and x.service_partner_id = v_sp.id) then
      raise exception 'Der Servicepartner ist diesem Objekt nicht zugeordnet' using errcode = '22023';
    end if;
  end if;

  if v_old.id is null then
    insert into public.maintenance (organization_id, property_id, title, status, start_date, interval_type, automation_mode, assigned_type, timezone)
    values (v_prop.organization_id, v_prop.id, coalesce(nullif(trim(j ->> 'title'), ''), v_tpl.title, 'Wartung'), 'active', v_start, v_type, v_mode,
            case v_mode when 'owner_self_service' then 'owner' when 'unassigned' then 'unassigned' else 'partner' end, v_tz)
    returning * into v_old;
  end if;

  update public.maintenance m set
    template_id = coalesce(v_tpl.id, m.template_id),
    title = left(coalesce(nullif(trim(j ->> 'title'), ''), m.title), 200),
    description = case when j ? 'description' then left(nullif(trim(j ->> 'description'), ''), 4000) else m.description end,
    category = left(coalesce(nullif(j ->> 'category', ''), v_tpl.category, m.category), 80),
    task_type = coalesce(nullif(j ->> 'task_type', ''), v_tpl.task_type, m.task_type),
    interval_type = v_type,
    interval_value = case when j ? 'interval_value' then nullif(j ->> 'interval_value', '')::integer
                          when v_tpl.id is not null then v_tpl.default_interval_value else m.interval_value end,
    interval_unit = case when j ? 'interval_unit' then nullif(j ->> 'interval_unit', '') else m.interval_unit end,
    weekday = case when j ? 'weekday' then nullif(j ->> 'weekday', '')::smallint else m.weekday end,
    day_of_month = case when j ? 'day_of_month' then nullif(j ->> 'day_of_month', '')::smallint else m.day_of_month end,
    local_time = coalesce(nullif(j ->> 'local_time', '')::time, m.local_time),
    timezone = v_tz,
    start_date = v_start,
    end_date = case when j ? 'end_date' then nullif(j ->> 'end_date', '')::date else m.end_date end,
    automation_mode = v_mode,
    assigned_type = case v_mode when 'owner_self_service' then 'owner' when 'unassigned' then 'unassigned' else 'partner' end,
    assigned_partner_id = v_partner,
    service_agreement_id = v_agree,
    budget_limit = case when j ? 'budget_limit' then nullif(j ->> 'budget_limit', '')::numeric else m.budget_limit end,
    currency = coalesce(nullif(j ->> 'currency', ''), v_a.currency, m.currency),
    reminder_days = case when jsonb_typeof(j -> 'reminder_days') = 'array'
                         then array(select distinct least(greatest(x::integer, 0), 60) from jsonb_array_elements_text(j -> 'reminder_days') x limit 5)
                         else m.reminder_days end,
    season_start_month = case when j ? 'season_start_month' then nullif(j ->> 'season_start_month', '')::smallint
                              when v_tpl.id is not null then v_tpl.season_start_month else m.season_start_month end,
    season_end_month = case when j ? 'season_end_month' then nullif(j ->> 'season_end_month', '')::smallint
                            when v_tpl.id is not null then v_tpl.season_end_month else m.season_end_month end,
    checklist = case when jsonb_typeof(j -> 'checklist') = 'array' then j -> 'checklist'
                     when v_tpl.id is not null and m.checklist = '[]'::jsonb then v_tpl.checklist else m.checklist end,
    estimated_duration_minutes = case when j ? 'estimated_duration_minutes' then nullif(j ->> 'estimated_duration_minutes', '')::integer else m.estimated_duration_minutes end,
    lead_days = coalesce(nullif(j ->> 'lead_days', '')::integer, m.lead_days),
    priority = coalesce(nullif(j ->> 'priority', ''), v_tpl.priority, m.priority),
    estimated_cost = case when j ? 'estimated_cost' then nullif(j ->> 'estimated_cost', '')::numeric else m.estimated_cost end
  where m.id = v_old.id;

  -- geänderte Regel: noch nicht begonnene künftige Fälligkeiten ohne Auftrag neu berechnen (Historie bleibt)
  delete from public.service_tasks x
  where x.maintenance_id = v_old.id and x.status = 'pending' and x.local_scheduled_date >= v_today
    and not exists (select 1 from public.service_order_items i where i.occurrence_id = x.id);
  perform private.maintenance_schedule_plan(v_old.id, 60);
  return v_old.id;
end; $$;
revoke all on function public.save_maintenance_plan(jsonb) from public, anon;
grant execute on function public.save_maintenance_plan(jsonb) to authenticated;

create or replace function public.set_maintenance_plan_status(p_plan_id uuid, p_status text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_p public.maintenance;
begin
  select * into v_p from public.maintenance m where m.id = p_plan_id for update;
  if v_p.id is null or not (private.is_org_staff(v_p.organization_id) or private.can_manage_property(v_p.property_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if p_status not in ('active', 'paused', 'archived') then raise exception 'Unbekannter Status' using errcode = '22023'; end if;
  update public.maintenance set status = p_status, archived_at = case when p_status = 'archived' then now() end where id = v_p.id;
  if p_status <> 'active' then
    delete from public.service_tasks x
    where x.maintenance_id = v_p.id and x.status = 'pending' and x.local_scheduled_date >= (now() at time zone v_p.timezone)::date
      and not exists (select 1 from public.service_order_items i where i.occurrence_id = x.id);
    perform private.mt_refresh_plan_due(v_p.id);
  else
    perform private.maintenance_schedule_plan(v_p.id, 60);
  end if;
  return p_status;
end; $$;
revoke all on function public.set_maintenance_plan_status(uuid, text) from public, anon;
grant execute on function public.set_maintenance_plan_status(uuid, text) to authenticated;

-- einzelnen Plan sofort neu planen (z. B. nach Vertragsänderung)
create or replace function public.refresh_maintenance_plan(p_plan_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_p public.maintenance;
begin
  select * into v_p from public.maintenance m where m.id = p_plan_id;
  if v_p.id is null or not (private.is_org_staff(v_p.organization_id) or private.can_manage_property(v_p.property_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  return private.maintenance_schedule_plan(v_p.id, 60);
end; $$;
revoke all on function public.refresh_maintenance_plan(uuid) from public, anon;
grant execute on function public.refresh_maintenance_plan(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 16) Eigentümeraktionen an Fälligkeiten
-- -----------------------------------------------------------------------------
create or replace function private.mt_owner_task(p_task_id uuid)
returns public.service_tasks language plpgsql security definer set search_path = '' as $$
declare v_t public.service_tasks;
begin
  select * into v_t from public.service_tasks t where t.id = p_task_id for update;
  if v_t.id is null or not (private.is_org_staff(v_t.organization_id) or private.can_manage_property(v_t.property_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  return v_t;
end; $$;

create or replace function public.complete_maintenance_task(p_task_id uuid, p_note text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare v_t public.service_tasks := private.mt_owner_task(p_task_id);
begin
  if v_t.status = 'completed' then return 'completed'; end if;
  if v_t.status in ('skipped', 'cancelled') then raise exception 'Diese Fälligkeit ist bereits abgeschlossen' using errcode = '22023'; end if;
  if private.mt_active_order(v_t.id) is not null then
    raise exception 'Für diese Fälligkeit läuft ein Serviceauftrag – der Abschluss erfolgt über den Auftrag' using errcode = '22023';
  end if;
  update public.service_tasks set status = 'completed', completed_at = now(), assigned_type = 'owner', owner_action = 'self_service',
         completion_notes = left(nullif(trim(p_note), ''), 2000) where id = v_t.id;
  if v_t.maintenance_id is not null then
    update public.maintenance set last_performed_at = now() where id = v_t.maintenance_id;
    perform private.mt_refresh_plan_due(v_t.maintenance_id);
  end if;
  return 'completed';
end; $$;

create or replace function public.skip_maintenance_task(p_task_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_t public.service_tasks := private.mt_owner_task(p_task_id);
begin
  if nullif(trim(p_reason), '') is null then raise exception 'Bitte einen Grund angeben' using errcode = '22023'; end if;
  if v_t.status = 'skipped' then return 'skipped'; end if;
  if v_t.status not in ('pending', 'assigned') or private.mt_active_order(v_t.id) is not null then
    raise exception 'Nur offene Fälligkeiten ohne laufenden Auftrag können übersprungen werden' using errcode = '22023';
  end if;
  update public.service_tasks set status = 'skipped', skipped_at = now(), skip_reason = left(trim(p_reason), 500) where id = v_t.id;
  if v_t.maintenance_id is not null then perform private.mt_refresh_plan_due(v_t.maintenance_id); end if;
  return 'skipped';
end; $$;

-- Einzeltermin verschieben: Serie bleibt unverändert (kein Drift), lokales Erzeugungsdatum bleibt Schlüssel
create or replace function public.reschedule_maintenance_task(p_task_id uuid, p_date date)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  v_t public.service_tasks := private.mt_owner_task(p_task_id);
  v_p public.maintenance;
  v_at timestamptz;
begin
  if p_date is null then raise exception 'Bitte ein Datum wählen' using errcode = '22023'; end if;
  if v_t.status <> 'pending' or private.mt_active_order(v_t.id) is not null then
    raise exception 'Nur offene Fälligkeiten ohne laufenden Auftrag können verschoben werden – sonst Termin im Auftrag ändern' using errcode = '22023';
  end if;
  select * into v_p from public.maintenance m where m.id = v_t.maintenance_id;
  v_at := private.mt_local_ts(p_date, coalesce(v_p.local_time, '09:00'), coalesce(v_p.timezone, 'Europe/Stockholm'));
  update public.service_tasks set scheduled_start = v_at,
         scheduled_end = v_at + coalesce(scheduled_end - scheduled_start, interval '1 hour') where id = v_t.id;
  if v_t.maintenance_id is not null then perform private.mt_refresh_plan_due(v_t.maintenance_id); end if;
  return v_at;
end; $$;

-- Eigentümer beauftragt (Einzel-Freigabe), optional mehrere Fälligkeiten gebündelt in EINEM Auftrag
create or replace function public.request_maintenance_service(p_task_ids uuid[], p_service_partner_id uuid,
                                                              p_note text default null, p_estimated_cost numeric default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_ids    uuid[];
  v_first  public.service_tasks;
  v_t      public.service_tasks;
  v_sp     public.service_partners;
  v_order  uuid;
  v_n      integer;
  v_titles text;
  v_i      integer := 0;
begin
  select array_agg(distinct x) into v_ids from unnest(p_task_ids) x where x is not null;
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n = 0 or v_n > 10 then raise exception 'Bitte 1 bis 10 Fälligkeiten wählen' using errcode = '22023'; end if;
  select * into v_first from public.service_tasks t where t.id = any (v_ids) order by t.scheduled_start nulls last, t.id limit 1;
  perform private.mt_owner_task(v_first.id);
  if (select count(*) from public.service_tasks t where t.id = any (v_ids)) <> v_n
     or exists (select 1 from public.service_tasks t where t.id = any (v_ids)
                and (t.organization_id <> v_first.organization_id or t.property_id <> v_first.property_id)) then
    raise exception 'Gebündelt werden können nur Fälligkeiten desselben Objekts' using errcode = '22023';
  end if;
  if exists (select 1 from public.service_tasks t where t.id = any (v_ids) and t.status not in ('pending', 'assigned')) then
    raise exception 'Mindestens eine Fälligkeit ist bereits erledigt, übersprungen oder in Arbeit' using errcode = '22023';
  end if;
  if (select max(t.scheduled_start)::date - min(t.scheduled_start)::date from public.service_tasks t where t.id = any (v_ids)) > 14 then
    raise exception 'Gebündelte Fälligkeiten müssen innerhalb von 14 Tagen liegen' using errcode = '22023';
  end if;
  -- idempotent: alle Fälligkeiten liegen schon in einem aktiven Auftrag dieses Partners → diesen zurückgeben
  select o.id into v_order from public.service_orders o
  where o.service_partner_id = p_service_partner_id and o.status not in ('rejected', 'cancelled', 'completed')
    and (select count(*) from public.service_order_items i where i.service_order_id = o.id and i.occurrence_id = any (v_ids)) = v_n
  limit 1;
  if v_order is not null then return v_order; end if;
  if exists (select 1 from unnest(v_ids) x where private.mt_active_order(x) is not null
             and exists (select 1 from public.service_tasks t where t.id = x and t.maintenance_id is not null)) then
    raise exception 'Mindestens eine Fälligkeit ist bereits einem aktiven Auftrag zugeordnet' using errcode = '23505';
  end if;
  select * into v_sp from public.service_partners sp where sp.id = p_service_partner_id;
  if v_sp.id is null or v_sp.organization_id <> v_first.organization_id or v_sp.status <> 'active' then
    raise exception 'Servicepartner nicht gefunden oder nicht aktiv' using errcode = '22023';
  end if;
  if exists (select 1 from public.property_service_assignments x where x.property_id = v_first.property_id and x.status = 'active')
     and not exists (select 1 from public.property_service_assignments x where x.property_id = v_first.property_id and x.status = 'active' and x.service_partner_id = v_sp.id) then
    raise exception 'Der Servicepartner ist diesem Objekt nicht zugeordnet' using errcode = '22023';
  end if;
  if p_estimated_cost is not null and p_estimated_cost < 0 then raise exception 'Ungültiger Betrag' using errcode = '22023'; end if;
  select string_agg(t.title, ', ' order by t.scheduled_start) into v_titles from public.service_tasks t where t.id = any (v_ids);

  insert into public.service_orders (organization_id, property_id, service_partner_id, service_task_id, source_type, title, description,
                                     status, scheduled_at, scheduled_end, estimated_cost, currency, priority)
  values (v_first.organization_id, v_first.property_id, v_sp.id, v_first.id,
          case when v_first.maintenance_id is not null then 'maintenance' else 'manual' end,
          left(case when v_n = 1 then v_first.title else 'Wartungsbesuch: ' || v_n || ' Positionen' end, 200),
          left(concat_ws(E'\n', nullif(trim(p_note), ''), case when v_n > 1 then 'Positionen: ' || v_titles end, v_first.description), 4000),
          'offered', v_first.scheduled_start, v_first.scheduled_end, p_estimated_cost,
          (select o.currency from public.organizations o where o.id = v_first.organization_id), v_first.priority)
  returning id into v_order;
  -- weitere Positionen (die erste legt der Auftrags-Trigger an)
  for v_t in select t.* from public.service_tasks t where t.id = any (v_ids) and t.id <> v_first.id order by t.scheduled_start loop
    v_i := v_i + 1;
    insert into public.service_order_items (service_order_id, occurrence_id, title, description, category, checklist, sort_order)
    select v_order, v_t.id, v_t.title, v_t.description, m.category, coalesce(m.checklist, '[]'::jsonb), v_i
    from (select 1) one left join public.maintenance m on m.id = v_t.maintenance_id;
    update public.service_tasks set status = 'assigned', assigned_partner_id = v_sp.id where id = v_t.id;
  end loop;
  update public.service_tasks set owner_action = null, blocked_reason = null where id = any (v_ids);
  if v_n > 1 then
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, new_status, message, metadata)
    values (v_order, v_first.organization_id, private.current_user_id(), 'owner', 'bundled', 'offered', left('Gebündelt: ' || v_titles, 2000),
            jsonb_build_object('occurrences', to_jsonb(v_ids)));
  end if;
  return v_order;
end; $$;
revoke all on function public.complete_maintenance_task(uuid, text) from public, anon;
revoke all on function public.skip_maintenance_task(uuid, text) from public, anon;
revoke all on function public.reschedule_maintenance_task(uuid, date) from public, anon;
revoke all on function public.request_maintenance_service(uuid[], uuid, text, numeric) from public, anon;
grant execute on function public.complete_maintenance_task(uuid, text) to authenticated;
grant execute on function public.skip_maintenance_task(uuid, text) to authenticated;
grant execute on function public.reschedule_maintenance_task(uuid, date) to authenticated;
grant execute on function public.request_maintenance_service(uuid[], uuid, text, numeric) to authenticated;

-- -----------------------------------------------------------------------------
-- 17) Ausführung: Position/Checkliste (Partner) und Abschlussbestätigung (Eigentümer)
-- -----------------------------------------------------------------------------
create or replace function public.update_order_item(p_item_id uuid, p_status text default null, p_results jsonb default null, p_note text default null)
returns public.service_order_items language plpgsql security definer set search_path = '' as $$
declare
  v_i public.service_order_items;
  v_o public.service_orders;
begin
  select * into v_i from public.service_order_items i where i.id = p_item_id for update;
  select * into v_o from public.service_orders o where o.id = v_i.service_order_id;
  if v_i.id is null or not private.can_work_order(v_o.id)
     or (private.is_org_staff(v_o.organization_id) and not private.is_partner_member(v_o.service_partner_id)) then
    raise exception 'Nur der beauftragte Servicepartner kann Positionen dokumentieren' using errcode = '42501';
  end if;
  if v_o.status not in ('accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts') then
    raise exception 'Positionen können nur bei laufenden Aufträgen dokumentiert werden' using errcode = '22023';
  end if;
  if p_status is not null and p_status not in ('open', 'done', 'not_done', 'skipped') then raise exception 'Unbekannter Positionsstatus' using errcode = '22023'; end if;
  if p_results is not null and jsonb_typeof(p_results) <> 'object' then raise exception 'Ungültiges Checklisten-Ergebnis' using errcode = '22023'; end if;
  update public.service_order_items set
    status = coalesce(p_status, status),
    checklist_results = case when p_results is null then checklist_results else checklist_results || p_results end,
    partner_note = case when p_note is null then partner_note else left(nullif(trim(p_note), ''), 2000) end
  where id = v_i.id returning * into v_i;
  if p_status is not null then
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, message, metadata)
    values (v_o.id, v_o.organization_id, private.current_user_id(), 'partner', 'item_updated', v_o.status, v_o.status,
            left(v_i.title || ': ' || case p_status when 'done' then 'erledigt' when 'not_done' then 'nicht erledigt' when 'skipped' then 'übersprungen' else 'offen' end, 2000),
            jsonb_build_object('item_id', v_i.id, 'status', p_status));
  end if;
  return v_i;
end; $$;
revoke all on function public.update_order_item(uuid, text, jsonb, text) from public, anon;
grant execute on function public.update_order_item(uuid, text, jsonb, text) to authenticated;

create or replace function public.confirm_service_completion(p_order_id uuid, p_ok boolean, p_note text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare v_o public.service_orders;
begin
  select * into v_o from public.service_orders o where o.id = p_order_id for update;
  if v_o.id is null or not (private.is_org_staff(v_o.organization_id) or private.is_property_owner(v_o.property_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_o.status <> 'completed' then raise exception 'Der Auftrag ist noch nicht als erledigt gemeldet' using errcode = '22023'; end if;
  if p_ok then
    if v_o.owner_confirmed_at is not null then return 'confirmed'; end if;
    update public.service_orders set owner_confirmed_at = now(), owner_confirmed_by = private.current_user_id(), owner_dispute_note = null where id = v_o.id;
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, message)
    values (v_o.id, v_o.organization_id, private.current_user_id(), 'owner', 'owner_confirmed', 'completed', 'completed', left(nullif(trim(p_note), ''), 2000));
    perform private.mt_notify_partner(v_o.service_partner_id, 'Abschluss bestätigt: ' || v_o.title, coalesce(nullif(trim(p_note), ''), 'Der Eigentümer hat den Einsatz bestätigt.'),
                                      v_o.id, 'so:' || v_o.id || ':confirmed');
    return 'confirmed';
  end if;
  if nullif(trim(p_note), '') is null then raise exception 'Bitte beschreiben, was nicht passt' using errcode = '22023'; end if;
  update public.service_orders set owner_dispute_note = left(trim(p_note), 2000), owner_confirmed_at = null, owner_confirmed_by = null where id = v_o.id;
  insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, old_status, new_status, message)
  values (v_o.id, v_o.organization_id, private.current_user_id(), 'owner', 'owner_disputed', 'completed', 'completed', left(trim(p_note), 2000));
  perform private.mt_notify_partner(v_o.service_partner_id, 'Rückfrage zum Abschluss: ' || v_o.title, left(trim(p_note), 300), v_o.id,
                                    'so:' || v_o.id || ':disputed:' || md5(trim(p_note)));
  return 'disputed';
end; $$;
revoke all on function public.confirm_service_completion(uuid, boolean, text) from public, anon;
grant execute on function public.confirm_service_completion(uuid, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 18) Auftragsquelle automatisch bestimmen; Mangel → Auftrag als Finding
-- -----------------------------------------------------------------------------
create or replace function private.service_orders_source()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_t public.service_tasks;
begin
  if new.source_type is null or new.source_type = 'manual' then
    select * into v_t from public.service_tasks t where t.id = new.service_task_id;
    new.source_type := case when new.priority = 'emergency' or new.order_type = 'emergency' then 'emergency'
                            when v_t.maintenance_id is not null then 'maintenance'
                            when v_t.app_ref is not null then 'app_task'
                            else 'manual' end;
  end if;
  if new.agreement_id is not null and new.agreement_version is null then
    new.agreement_version := (select a.version from public.service_agreements a where a.id = new.agreement_id);
  end if;
  return new;
end; $$;
drop trigger if exists service_orders_source on public.service_orders;
create trigger service_orders_source before insert on public.service_orders for each row execute function private.service_orders_source();
update public.service_orders o set source_type = case when o.priority = 'emergency' or o.order_type = 'emergency' then 'emergency'
                                                      when t.app_ref is not null then 'app_task' else 'manual' end
from public.service_tasks t where t.id = o.service_task_id and o.source_type = 'manual';
update public.service_orders o set source_type = 'finding'
where o.source_type in ('manual', 'app_task') and exists (select 1 from public.repairs r where r.service_order_id = o.id);

create or replace function private.repairs_link_finding()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.service_order_id is not null and (tg_op = 'INSERT' or new.service_order_id is distinct from old.service_order_id) then
    update public.service_orders set source_type = 'finding' where id = new.service_order_id and source_type in ('manual', 'app_task');
    update public.service_order_items set source_repair_id = new.id where service_order_id = new.service_order_id and source_repair_id is null;
  end if;
  return null;
end; $$;
drop trigger if exists repairs_link_finding on public.repairs;
create trigger repairs_link_finding after insert or update of service_order_id on public.repairs for each row execute function private.repairs_link_finding();

-- -----------------------------------------------------------------------------
-- 19) Statusabgleich Auftrag → Positionen → Fälligkeiten → Plan (läuft nach sync_task_from_order)
-- -----------------------------------------------------------------------------
create or replace function private.sync_items_from_order()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_plan uuid;
begin
  if new.status is not distinct from old.status then return null; end if;
  if new.status in ('rejected', 'cancelled') then
    -- Fälligkeit bleibt offen, der Eigentümer entscheidet neu (keine automatische Neubeauftragung)
    update public.service_tasks t set status = 'pending', assigned_partner_id = null, owner_action = 'approval_required',
           blocked_reason = case when new.status = 'rejected' then 'Servicepartner hat abgelehnt – bitte neu beauftragen' else 'Auftrag storniert – bitte neu entscheiden' end
    from public.service_order_items i
    where i.service_order_id = new.id and i.occurrence_id = t.id and t.maintenance_id is not null
      and t.status not in ('completed', 'skipped', 'cancelled')
      and private.mt_active_order(t.id) is null;
  elsif new.status = 'completed' then
    update public.service_order_items set status = 'done' where service_order_id = new.id and status = 'open';
    update public.service_tasks t set status = 'completed', completed_at = coalesce(new.completed_at, now()),
           completion_notes = coalesce(nullif(i.partner_note, ''), t.completion_notes)
    from public.service_order_items i
    where i.service_order_id = new.id and i.occurrence_id = t.id and i.status = 'done' and t.status not in ('completed', 'cancelled', 'skipped');
    update public.service_tasks t set status = 'pending', assigned_partner_id = null, owner_action = 'approval_required',
           blocked_reason = 'Beim Einsatz nicht erledigt' || coalesce(': ' || nullif(i.partner_note, ''), '')
    from public.service_order_items i
    where i.service_order_id = new.id and i.occurrence_id = t.id and i.status = 'not_done' and t.maintenance_id is not null;
    update public.service_tasks t set status = 'skipped', skipped_at = now(), skip_reason = left('Beim Einsatz übersprungen' || coalesce(': ' || nullif(i.partner_note, ''), ''), 500)
    from public.service_order_items i
    where i.service_order_id = new.id and i.occurrence_id = t.id and i.status = 'skipped' and t.maintenance_id is not null;
    for v_plan in
      select distinct t.maintenance_id from public.service_order_items i join public.service_tasks t on t.id = i.occurrence_id
      where i.service_order_id = new.id and t.maintenance_id is not null
    loop
      update public.maintenance set last_performed_at = coalesce(new.completed_at, now()) where id = v_plan;
      perform private.mt_refresh_plan_due(v_plan);
    end loop;
  elsif old.status = 'completed' and new.status = 'in_progress' then
    update public.service_tasks t set status = 'in_progress', completed_at = null
    from public.service_order_items i where i.service_order_id = new.id and i.occurrence_id = t.id and t.status = 'completed';
    update public.service_orders set owner_confirmed_at = null, owner_confirmed_by = null where id = new.id and owner_confirmed_at is not null;
  elsif new.status in ('offered', 'accepted', 'scheduled', 'in_progress') then
    update public.service_tasks t set assigned_partner_id = new.service_partner_id,
           status = case new.status when 'offered' then 'assigned' when 'in_progress' then 'in_progress' else 'accepted' end,
           scheduled_start = coalesce(new.scheduled_at, t.scheduled_start)
    from public.service_order_items i
    where i.service_order_id = new.id and i.occurrence_id = t.id and t.status not in ('completed', 'cancelled', 'skipped');
  end if;
  return null;
end; $$;
drop trigger if exists service_orders_zy_sync_items on public.service_orders;
create trigger service_orders_zy_sync_items after update of status on public.service_orders for each row execute function private.sync_items_from_order();

-- -----------------------------------------------------------------------------
-- 20) Kostengrenze bei automatischen Vertragsaufträgen (Szenario D)
-- -----------------------------------------------------------------------------
create or replace function private.service_orders_budget_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.source_type = 'agreement_auto' and new.status = 'completed' and old.status is distinct from 'completed' then
    if new.approval_status = 'pending' or exists (select 1 from public.approval_requests r where r.service_order_id = new.id and r.status = 'pending') then
      raise exception 'Abschluss nicht möglich: eine Mehrkosten-Freigabe des Eigentümers steht noch aus' using errcode = '22023';
    end if;
    if new.actual_cost is not null and new.actual_cost > coalesce(new.estimated_cost, 0) + 0.004 then
      raise exception 'Ist-Kosten (% %) liegen über dem freigegebenen Rahmen (% %) – bitte Mehrkosten zur Freigabe anfragen',
        new.actual_cost, new.currency, coalesce(new.estimated_cost, 0), new.currency using errcode = '22023';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists service_orders_budget_guard on public.service_orders;
create trigger service_orders_budget_guard before update of status, actual_cost on public.service_orders for each row execute function private.service_orders_budget_guard();

-- Mehrkosten bei Vertragsaufträgen nie automatisch freigeben, wenn das Vertragsmaximum überschritten würde
create or replace function public.request_approval(p_service_order_id uuid, p_title text, p_amount numeric, p_description text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_o     public.service_orders;
  v_sp    public.service_partners;
  v_limit numeric;
  v_cur   text;
  v_id    uuid;
  v_auto  boolean;
  v_max   numeric;
begin
  select * into v_o from public.service_orders o where o.id = p_service_order_id;
  if v_o.id is null or not private.can_work_order(v_o.id) or private.is_org_staff(v_o.organization_id) then
    raise exception 'Nur der beauftragte Servicepartner kann Mehrkosten anfragen' using errcode = '42501';
  end if;
  if v_o.status not in ('accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts') then
    raise exception 'Mehrkosten nur für laufende Aufträge' using errcode = '22023';
  end if;
  if nullif(trim(p_title), '') is null then raise exception 'Bitte beschreiben, wofür die Mehrkosten anfallen' using errcode = '22023'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Bitte einen gültigen Betrag angeben' using errcode = '22023'; end if;
  select * into v_sp from public.service_partners sp where sp.id = v_o.service_partner_id;
  select o.auto_approval_limit, o.currency into v_limit, v_cur from public.organizations o where o.id = v_o.organization_id;
  v_auto := v_limit is not null and p_amount <= v_limit and coalesce(v_o.currency, v_cur) = v_cur;
  if v_auto and v_o.source_type = 'agreement_auto' then
    select a.max_price_per_visit into v_max from public.service_agreements a where a.id = v_o.agreement_id;
    if v_max is not null and coalesce(v_o.estimated_cost, 0) + p_amount > v_max then v_auto := false; end if;
  end if;

  insert into public.approval_requests (organization_id, service_order_id, service_partner_id, title, description, amount, currency,
                                        status, auto_approved, requested_by, decided_at)
  values (v_o.organization_id, v_o.id, v_o.service_partner_id, left(trim(p_title), 160), left(nullif(trim(p_description), ''), 2000), p_amount,
          coalesce(v_o.currency, v_cur, 'EUR'), case when v_auto then 'approved' else 'pending' end, v_auto, private.current_user_id(),
          case when v_auto then now() end)
  returning id into v_id;

  update public.service_orders o
  set requires_approval = not v_auto or o.requires_approval,
      approval_status = case when v_auto then coalesce(o.approval_status, 'approved') else 'pending' end,
      estimated_cost = case when v_auto then coalesce(o.estimated_cost, 0) + p_amount else o.estimated_cost end
  where o.id = v_o.id;

  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select v_o.organization_id, m.user_id, 'service_order',
         case when v_auto then 'Mehrkosten automatisch freigegeben: ' else 'Freigabe angefragt: ' end || left(trim(p_title), 120),
         left(concat_ws(' · ', coalesce(v_sp.company_name, 'Servicepartner'), v_o.title, p_amount::text || ' ' || coalesce(v_o.currency, v_cur)), 200),
         'service_order', v_o.id
  from public.organization_members m
  where m.organization_id = v_o.organization_id and m.status = 'active' and m.role in ('admin', 'property_manager', 'service_manager');
  return jsonb_build_object('id', v_id, 'status', case when v_auto then 'approved' else 'pending' end, 'auto_approved', v_auto);
end;
$$;

-- -----------------------------------------------------------------------------
-- 21) Bestehende Vertragsplanung: Verträge, die ein Wartungsplan automatisch bedient, nicht doppelt planen
-- -----------------------------------------------------------------------------
create or replace function public.run_recurring_agreements()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_a       public.service_agreements;
  v_day     date;
  v_window  integer;
  v_created integer := 0;
  v_tz      text;
  v_id      uuid;
begin
  for v_a in
    select a.* from public.service_agreements a
    join public.service_partners sp on sp.id = a.service_partner_id
    where a.status = 'active' and a.auto_schedule and sp.partner_organization_id is not null and sp.disconnected_at is null
      and a.property_id is not null
      and not exists (select 1 from public.maintenance m where m.service_agreement_id = a.id and m.automation_mode = 'agreement_auto'
                      and m.status = 'active' and m.archived_at is null)
  loop
    v_window := greatest(2, (365 / greatest(1, v_a.visits_per_year)) / 2);
    select coalesce(o.timezone, 'Europe/Stockholm') into v_tz from public.organizations o where o.id = v_a.organization_id;
    for v_day in
      select d from private.agreement_visit_dates(v_a.starts_on, v_a.ends_on, v_a.visits_per_year) d
      where d >= current_date and d <= current_date + v_a.lead_days
    loop
      continue when exists (
        select 1 from public.service_orders o
        where o.agreement_id = v_a.id and o.status not in ('cancelled', 'rejected')
          and o.scheduled_at is not null and abs(o.scheduled_at::date - v_day) <= v_window);
      insert into public.service_orders (organization_id, property_id, service_partner_id, agreement_id, title, description, status,
                                         scheduled_at, order_type, currency, recurrence_key, response_note)
      values (v_a.organization_id, v_a.property_id, v_a.service_partner_id, v_a.id, left(v_a.task_title, 200),
              'Geplanter Besuch aus dem Jahresvertrag „' || v_a.title || '“', 'scheduled',
              ((v_day + v_a.visit_time)::timestamp at time zone v_tz), 'maintenance', v_a.currency,
              v_a.id::text || ':' || v_day::text, 'Automatisch aus dem Jahresvertrag geplant')
      on conflict (recurrence_key) where recurrence_key is not null do nothing
      returning id into v_id;
      if v_id is not null then
        v_created := v_created + 1;
        insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
        select sp.partner_organization_id, m.user_id, 'service_order', 'order', 'Besuch geplant: ' || v_a.task_title,
               left(concat_ws(' · ', (select p.name from public.properties p where p.id = v_a.property_id), to_char(v_day, 'DD.MM.YYYY'), 'Jahresvertrag'), 200),
               'service_order', v_id
        from public.service_partners sp join public.organization_members m on m.organization_id = sp.partner_organization_id
        where sp.id = v_a.service_partner_id and m.status = 'active' and m.role in ('admin', 'service_manager', 'dispatcher');
      end if;
    end loop;
    update public.service_agreements set last_planned_on = current_date where id = v_a.id;
  end loop;
  return jsonb_build_object('created', v_created);
end;
$$;

-- -----------------------------------------------------------------------------
-- 22) Lesesicht Fälligkeiten (Statusmodell der Spezifikation; RLS der Basistabellen gilt)
-- -----------------------------------------------------------------------------
create or replace view public.maintenance_occurrences with (security_invoker = true) as
select t.id, t.organization_id, t.property_id, t.maintenance_id, t.generation_key, t.title, m.category, t.priority,
       t.local_scheduled_date, t.scheduled_start, t.scheduled_end,
       (t.scheduled_start at time zone m.timezone)::date as local_due_date,
       t.status as task_status,
       case
         when t.status in ('completed', 'skipped', 'cancelled') then t.status
         when t.status = 'in_progress' then 'in_progress'
         when t.status = 'accepted' then 'assigned'
         when t.status = 'assigned' then 'partner_requested'
         when (t.scheduled_start at time zone m.timezone)::date < (now() at time zone m.timezone)::date then 'overdue'
         when t.owner_action in ('approval_required', 'assign_partner', 'blocked') then 'owner_action_required'
         when (t.scheduled_start at time zone m.timezone)::date <= (now() at time zone m.timezone)::date + m.lead_days then 'due'
         else 'upcoming'
       end as occurrence_status,
       t.status not in ('completed', 'skipped', 'cancelled')
         and (t.scheduled_start at time zone m.timezone)::date < (now() at time zone m.timezone)::date as is_overdue,
       t.owner_action, t.blocked_reason, t.skip_reason, t.completed_at, t.completion_notes,
       coalesce(t.assigned_type, m.assigned_type) as assigned_type, m.automation_mode,
       coalesce(t.assigned_partner_id, m.assigned_partner_id) as service_partner_id,
       m.service_agreement_id, m.title as plan_title,
       o.id as service_order_id, o.order_number, o.status as order_status, o.owner_confirmed_at, o.owner_dispute_note
from public.service_tasks t
join public.maintenance m on m.id = t.maintenance_id
left join lateral (
  select so.id, so.order_number, so.status, so.owner_confirmed_at, so.owner_dispute_note
  from public.service_order_items i join public.service_orders so on so.id = i.service_order_id
  where i.occurrence_id = t.id order by (so.status in ('rejected', 'cancelled')), so.created_at desc limit 1
) o on true;
comment on view public.maintenance_occurrences is 'Fälligkeiten aus Wartungsplänen mit Status der Spezifikation (upcoming/due/owner_action_required/partner_requested/assigned/in_progress/completed/skipped/overdue/cancelled)';
revoke all on public.maintenance_occurrences from anon, authenticated;
grant select on public.maintenance_occurrences to authenticated;

-- -----------------------------------------------------------------------------
-- 23) Täglicher Lauf (pg_cron)
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'husora-maintenance') then perform cron.unschedule('husora-maintenance'); end if;
    perform cron.schedule('husora-maintenance', '29 3 * * *', 'select public.run_maintenance_scheduler()');
  end if;
exception when others then raise notice 'pg_cron nicht verfügbar: %', sqlerrm;
end $$;

-- interne Helfer nie direkt aufrufbar
revoke all on function private.maintenance_process_task(public.service_tasks, public.maintenance) from public, anon, authenticated;
revoke all on function private.maintenance_schedule_plan(uuid, integer) from public, anon, authenticated;
revoke all on function private.mt_notify_owner(uuid, text, text, text, uuid, text) from public, anon, authenticated;
revoke all on function private.mt_notify_partner(uuid, text, text, uuid, text) from public, anon, authenticated;
revoke all on function private.validate_service_agreement(uuid, uuid, uuid, text, text, date, numeric) from public, anon, authenticated;
