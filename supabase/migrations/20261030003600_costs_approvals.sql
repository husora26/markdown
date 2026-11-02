-- =============================================================================
-- HUSORA · Phase 8: Arbeitszeit, Material, Anfahrt und Freigaben
-- =============================================================================
-- Spezifikation §18–23:
--   * public.service_order_cost_items: Arbeitszeit (Start/Stopp oder Minuten), Material und
--     Anfahrt je Auftrag – eine Tabelle mit kind statt drei getrennten. Daten des Partnerbetriebs
--     (organization_id = Partner-Organisation), nur dort sichtbar; dienen als Grundlage der Rechnung.
--   * public.approval_requests: Mehrkosten, die der Partner beim Hausbesitzer zur Freigabe anfragt.
--   * organizations.auto_approval_limit (Hausbesitzer): Mehrkosten bis zu diesem Betrag werden
--     automatisch freigegeben und im Audit-Log/Verlauf festgehalten.
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Kostenpositionen des Partners
-- -----------------------------------------------------------------------------
create table if not exists public.service_order_cost_items (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  service_order_id  uuid not null references public.service_orders(id) on delete cascade,
  kind              text not null check (kind in ('work', 'material', 'travel')),
  user_id           uuid references public.users(id) on delete set null,
  description       text check (description is null or length(description) <= 300),
  started_at        timestamptz,
  ended_at          timestamptz,
  minutes           integer check (minutes is null or minutes between 0 and 100000),
  quantity          numeric(12, 2) check (quantity is null or quantity >= 0),
  unit              text check (unit is null or length(unit) <= 20),
  unit_price        numeric(12, 2) check (unit_price is null or unit_price >= 0),
  amount            numeric(12, 2) check (amount is null or amount >= 0),
  currency          text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  billable          boolean not null default true,
  created_by        uuid references public.users(id) on delete set null,
  updated_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (ended_at is null or started_at is null or ended_at >= started_at)
);
comment on table public.service_order_cost_items is 'Arbeitszeit, Material und Anfahrt je Auftrag (Daten des Partnerbetriebs, Grundlage der Rechnung)';
create index if not exists soci_order_idx on public.service_order_cost_items (service_order_id, created_at);
create index if not exists soci_org_idx on public.service_order_cost_items (organization_id);
create index if not exists soci_user_idx on public.service_order_cost_items (user_id) where user_id is not null;
create index if not exists soci_running_idx on public.service_order_cost_items (user_id) where kind = 'work' and ended_at is null and started_at is not null;
create index if not exists soci_created_by_idx on public.service_order_cost_items (created_by) where created_by is not null;
create index if not exists soci_updated_by_idx on public.service_order_cost_items (updated_by) where updated_by is not null;

-- organization_id = Partnerbetrieb, der am Auftrag arbeitet; Auftrag bleibt fest
create or replace function private.soci_check()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_partner uuid;
begin
  select sp.partner_organization_id into v_partner
  from public.service_orders o join public.service_partners sp on sp.id = o.service_partner_id
  where o.id = new.service_order_id;
  if v_partner is null then raise exception 'Auftrag ohne verbundenen Servicepartner' using errcode = '22023'; end if;
  if tg_op = 'UPDATE' then
    new.service_order_id := old.service_order_id;
    new.organization_id := old.organization_id;
  else
    new.organization_id := v_partner;
  end if;
  if new.kind = 'work' and new.started_at is not null and new.ended_at is not null and new.minutes is null then
    new.minutes := greatest(0, round(extract(epoch from (new.ended_at - new.started_at)) / 60)::integer);
  end if;
  return new;
end;
$$;
drop trigger if exists soci_check on public.service_order_cost_items;
create trigger soci_check before insert or update on public.service_order_cost_items
  for each row execute function private.soci_check();
drop trigger if exists soci_set_updated_at on public.service_order_cost_items;
create trigger soci_set_updated_at before update on public.service_order_cost_items
  for each row execute function private.set_updated_at();
drop trigger if exists soci_set_actor on public.service_order_cost_items;
create trigger soci_set_actor before insert or update on public.service_order_cost_items
  for each row execute function private.set_actor_columns();
drop trigger if exists service_order_cost_items_audit on public.service_order_cost_items;
create trigger service_order_cost_items_audit after insert or update or delete on public.service_order_cost_items
  for each row execute function private.audit_row_change();

alter table public.service_order_cost_items enable row level security;
-- Lesen: Leitung/Buchhaltung des Betriebs alles, Mitarbeiter ihre Aufträge
drop policy if exists soci_select on public.service_order_cost_items;
create policy soci_select on public.service_order_cost_items for select to authenticated
  using (private.can_read_org(organization_id) or (private.is_org_member(organization_id) and private.can_work_order(service_order_id)));
-- Schreiben: nur Mitglieder des Partnerbetriebs, die am Auftrag arbeiten dürfen; Mitarbeiter nur eigene Einträge
-- (can_work_order gilt auch für den Hausbesitzer – deshalb zusätzlich is_org_member)
drop policy if exists soci_insert on public.service_order_cost_items;
create policy soci_insert on public.service_order_cost_items for insert to authenticated
  with check (private.is_org_member(organization_id) and private.can_work_order(service_order_id)
              and (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher', 'accounting']) or user_id = (select private.current_user_id())));
drop policy if exists soci_update on public.service_order_cost_items;
create policy soci_update on public.service_order_cost_items for update to authenticated
  using (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher', 'accounting']) or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id) and private.can_work_order(service_order_id)))
  with check (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher', 'accounting']) or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id) and private.can_work_order(service_order_id)));
drop policy if exists soci_delete on public.service_order_cost_items;
create policy soci_delete on public.service_order_cost_items for delete to authenticated
  using (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher', 'accounting']) or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id) and private.can_work_order(service_order_id)));
revoke all on public.service_order_cost_items from anon;
grant select, insert, update, delete on public.service_order_cost_items to authenticated;

-- -----------------------------------------------------------------------------
-- 2) Automatisches Freigabelimit des Hausbesitzers
-- -----------------------------------------------------------------------------
alter table public.organizations add column if not exists auto_approval_limit numeric(12, 2);
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'organizations_auto_approval_limit_check') then
    alter table public.organizations add constraint organizations_auto_approval_limit_check check (auto_approval_limit is null or auto_approval_limit >= 0);
  end if;
end $$;
comment on column public.organizations.auto_approval_limit is 'Mehrkosten bis zu diesem Betrag (Organisationswährung) werden automatisch freigegeben; null = immer nachfragen';

-- -----------------------------------------------------------------------------
-- 3) Freigabeanfragen (Mehrkosten)
-- -----------------------------------------------------------------------------
create table if not exists public.approval_requests (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  service_order_id    uuid not null references public.service_orders(id) on delete cascade,
  service_partner_id  uuid not null references public.service_partners(id) on delete cascade,
  kind                text not null default 'extra_cost' check (kind in ('extra_cost', 'repair', 'quote')),
  title               text not null check (length(trim(title)) between 1 and 160),
  description         text check (description is null or length(description) <= 2000),
  amount              numeric(12, 2) not null check (amount >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  status              text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  auto_approved       boolean not null default false,
  response_note       text check (response_note is null or length(response_note) <= 1000),
  requested_by        uuid references public.users(id) on delete set null,
  decided_by          uuid references public.users(id) on delete set null,
  decided_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.approval_requests is 'Mehrkosten/Freigaben, die der Servicepartner beim Hausbesitzer anfragt (Spezifikation §22–23)';
create index if not exists approval_requests_org_idx on public.approval_requests (organization_id, status);
create index if not exists approval_requests_order_idx on public.approval_requests (service_order_id);
create index if not exists approval_requests_partner_idx on public.approval_requests (service_partner_id, status);
create index if not exists approval_requests_requested_by_idx on public.approval_requests (requested_by) where requested_by is not null;
create index if not exists approval_requests_decided_by_idx on public.approval_requests (decided_by) where decided_by is not null;
drop trigger if exists approval_requests_set_updated_at on public.approval_requests;
create trigger approval_requests_set_updated_at before update on public.approval_requests
  for each row execute function private.set_updated_at();
drop trigger if exists approval_requests_audit on public.approval_requests;
create trigger approval_requests_audit after insert or update or delete on public.approval_requests
  for each row execute function private.audit_row_change();

alter table public.approval_requests enable row level security;
drop policy if exists approval_requests_select on public.approval_requests;
create policy approval_requests_select on public.approval_requests for select to authenticated
  using (private.can_read_org(organization_id) or private.is_partner_member(service_partner_id)
         or private.can_work_order(service_order_id));
-- Schreiben nur über die RPCs
revoke all on public.approval_requests from anon;
revoke insert, update, delete on public.approval_requests from authenticated;
grant select on public.approval_requests to authenticated;

-- Partner fragt Mehrkosten an (oder werden bis zum Limit automatisch freigegeben)
create or replace function public.request_approval(p_service_order_id uuid, p_title text, p_amount numeric, p_description text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_o     public.service_orders;
  v_sp    public.service_partners;
  v_limit numeric;
  v_cur   text;
  v_id    uuid;
  v_auto  boolean;
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
revoke all on function public.request_approval(uuid, text, numeric, text) from public, anon;
grant execute on function public.request_approval(uuid, text, numeric, text) to authenticated;

-- Hausbesitzer entscheidet
create or replace function public.respond_approval(p_request_id uuid, p_approve boolean, p_note text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.approval_requests;
  v_sp public.service_partners;
begin
  select * into v_r from public.approval_requests r where r.id = p_request_id for update;
  if v_r.id is null or not private.is_org_staff(v_r.organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_r.status <> 'pending' then raise exception 'Diese Anfrage ist bereits entschieden' using errcode = '22023'; end if;
  update public.approval_requests
  set status = case when p_approve then 'approved' else 'rejected' end, decided_by = private.current_user_id(), decided_at = now(),
      response_note = left(nullif(trim(p_note), ''), 1000)
  where id = v_r.id;
  update public.service_orders o
  set approval_status = case when exists (select 1 from public.approval_requests x where x.service_order_id = o.id and x.status = 'pending') then 'pending'
                             when p_approve then 'approved' else 'rejected' end,
      estimated_cost = case when p_approve then coalesce(o.estimated_cost, 0) + v_r.amount else o.estimated_cost end
  where o.id = v_r.service_order_id;
  select * into v_sp from public.service_partners sp where sp.id = v_r.service_partner_id;
  if v_sp.partner_organization_id is not null then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select v_sp.partner_organization_id, m.user_id, 'service_order',
           case when p_approve then 'Mehrkosten freigegeben: ' else 'Mehrkosten abgelehnt: ' end || v_r.title,
           left(coalesce(nullif(trim(p_note), ''), v_r.amount::text || ' ' || v_r.currency), 200), 'service_order', v_r.service_order_id
    from public.organization_members m
    where m.organization_id = v_sp.partner_organization_id and m.status = 'active' and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  end if;
  return case when p_approve then 'approved' else 'rejected' end;
end;
$$;
revoke all on function public.respond_approval(uuid, boolean, text) from public, anon;
grant execute on function public.respond_approval(uuid, boolean, text) to authenticated;

-- Freigabeanfragen erscheinen im Auftragsverlauf
create or replace function private.approval_to_events()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.service_order_events (service_order_id, organization_id, user_id, actor_side, event_type, message, metadata)
    values (new.service_order_id, new.organization_id, private.current_user_id(),
            case when tg_op = 'INSERT' and not new.auto_approved then 'partner' when new.auto_approved then 'system' else 'owner' end, 'note',
            left(case when tg_op = 'INSERT' and new.auto_approved then 'Mehrkosten automatisch freigegeben (Limit): '
                      when tg_op = 'INSERT' then 'Freigabe angefragt: '
                      when new.status = 'approved' then 'Mehrkosten freigegeben: '
                      when new.status = 'rejected' then 'Mehrkosten abgelehnt: '
                      else 'Freigabe zurückgezogen: ' end || new.title || ' (' || new.amount::text || ' ' || new.currency || ')', 2000),
            jsonb_build_object('approval_id', new.id, 'status', new.status, 'amount', new.amount));
  end if;
  return null;
end;
$$;
drop trigger if exists approval_requests_events on public.approval_requests;
create trigger approval_requests_events after insert or update of status on public.approval_requests
  for each row execute function private.approval_to_events();
