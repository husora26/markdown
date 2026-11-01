-- =============================================================================
-- Jahresverträge mit Servicepartnern und Sammelrechnungen
--  * service_agreements: wiederkehrende Aufgabe (z. B. „Rasen mähen“) für ein Haus,
--    Jahrespreis, Laufzeit. Vorschlag durch Hausbesitzer ODER Partner, die andere
--    Seite nimmt an. Passende Aufträge werden automatisch dem Vertrag zugeordnet und
--    nicht einzeln abgerechnet – der Partner stellt einmal im Jahr eine Rechnung.
--  * invoice_orders: eine Rechnung für mehrere Aufträge desselben Kunden
--    (Positionen mit Betrag je Auftrag, damit der Kunde Kosten je Haus bucht).
-- Organisation und Partner werden immer serverseitig abgeleitet, nie aus dem Browser übernommen.
-- =============================================================================

create table public.service_agreements (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  service_partner_id  uuid not null,
  title               text not null check (length(trim(title)) between 1 and 160),
  task_title          text not null check (length(trim(task_title)) between 1 and 160),
  interval_label      text check (length(interval_label) <= 60),
  visits_per_year     integer check (visits_per_year between 1 and 366),
  annual_price        numeric(12, 2) not null check (annual_price >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  starts_on           date not null,
  ends_on             date not null,
  notes               text check (length(notes) <= 2000),
  status              text not null default 'proposed' check (status in ('proposed', 'active', 'declined', 'ended', 'cancelled')),
  proposed_by         text not null check (proposed_by in ('owner', 'partner')),
  proposed_by_user    uuid references public.users(id) on delete set null,
  responded_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete cascade,
  check (ends_on > starts_on and ends_on <= starts_on + interval '3 years')
);
comment on table public.service_agreements is 'Jahresverträge für wiederkehrende Aufgaben: Aufträge darin werden nicht einzeln, sondern einmal jährlich abgerechnet.';
create index service_agreements_org_idx on public.service_agreements (organization_id, status);
create index service_agreements_partner_idx on public.service_agreements (service_partner_id, status);
create index service_agreements_property_idx on public.service_agreements (property_id);
alter table public.service_agreements enable row level security;
create policy service_agreements_select on public.service_agreements for select to authenticated
  using (private.can_read_org(organization_id) or private.is_partner_member(service_partner_id));
-- Schreiben nur über die Funktionen unten
grant select on public.service_agreements to authenticated;
grant all on public.service_agreements to service_role;
create trigger service_agreements_set_updated_at before update on public.service_agreements
  for each row execute function private.set_updated_at();

alter table public.service_orders add column agreement_id uuid;
alter table public.service_orders add constraint service_orders_agreement_fk
  foreign key (organization_id, agreement_id) references public.service_agreements (organization_id, id) on delete set null (agreement_id);
create index service_orders_agreement_idx on public.service_orders (agreement_id) where agreement_id is not null;

alter table public.invoices add column agreement_id uuid;
alter table public.invoices add constraint invoices_agreement_fk
  foreign key (organization_id, agreement_id) references public.service_agreements (organization_id, id) on delete set null (agreement_id);
create index invoices_agreement_idx on public.invoices (agreement_id) where agreement_id is not null;

-- Rechnungspositionen: mehrere Aufträge auf einer Rechnung
create table public.invoice_orders (
  invoice_id        uuid not null,
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  service_order_id  uuid not null,
  amount_gross      numeric(12, 2) not null check (amount_gross >= 0),
  created_at        timestamptz not null default now(),
  primary key (invoice_id, service_order_id),
  foreign key (organization_id, invoice_id) references public.invoices (organization_id, id) on delete cascade,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete cascade
);
create unique index invoice_orders_order_unique_idx on public.invoice_orders (service_order_id);
create index invoice_orders_org_idx on public.invoice_orders (organization_id);
alter table public.invoice_orders enable row level security;
create policy invoice_orders_select on public.invoice_orders for select to authenticated
  using (private.can_read_org(organization_id)
         or exists (select 1 from public.invoices i where i.id = invoice_id and private.is_partner_member(i.service_partner_id)));
create policy invoice_orders_insert on public.invoice_orders for insert to authenticated
  with check (private.is_org_staff(organization_id)
              or exists (select 1 from public.invoices i where i.id = invoice_id and private.is_partner_member(i.service_partner_id)));
grant select, insert on public.invoice_orders to authenticated;
grant all on public.invoice_orders to service_role;

-- -----------------------------------------------------------------------------
-- Prüfungen
-- -----------------------------------------------------------------------------
-- Rechnungsposition: Auftrag gehört zum selben Kunden und Partner, ist nicht im Jahresvertrag
create or replace function private.invoice_orders_check()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_inv public.invoices;
  v_ord public.service_orders;
begin
  select * into v_inv from public.invoices where id = new.invoice_id;
  select * into v_ord from public.service_orders where id = new.service_order_id;
  if v_inv.id is null or v_ord.id is null or v_inv.organization_id <> new.organization_id or v_ord.organization_id <> new.organization_id
     or v_ord.service_partner_id is distinct from v_inv.service_partner_id then
    raise exception 'Auftrag passt nicht zu dieser Rechnung' using errcode = '22023';
  end if;
  if v_ord.agreement_id is not null then
    raise exception 'Auftrag % ist im Jahresvertrag enthalten und wird jährlich abgerechnet', v_ord.order_number using errcode = '22023';
  end if;
  if exists (select 1 from public.invoices i where i.service_order_id = v_ord.id and i.id <> v_inv.id and i.status <> 'cancelled') then
    raise exception 'Für Auftrag % gibt es bereits eine Rechnung', v_ord.order_number using errcode = '23505';
  end if;
  return new;
end;
$$;
create trigger invoice_orders_check before insert on public.invoice_orders
  for each row execute function private.invoice_orders_check();

-- Rechnung: Vertragsrechnung nur für eigenen, angenommenen Vertrag; Einzelrechnung nicht für Vertragsaufträge
create or replace function private.invoices_agreement_check()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
begin
  if new.agreement_id is not null and (tg_op = 'INSERT' or new.agreement_id is distinct from old.agreement_id) then
    select * into v_ag from public.service_agreements where id = new.agreement_id;
    if v_ag.id is null or v_ag.organization_id <> new.organization_id or v_ag.service_partner_id is distinct from new.service_partner_id
       or v_ag.status not in ('active', 'ended') then
      raise exception 'Jahresrechnung nur für einen angenommenen Vertrag dieses Partners' using errcode = '22023';
    end if;
    new.property_id := v_ag.property_id;
  end if;
  if new.service_order_id is not null and (tg_op = 'INSERT' or new.service_order_id is distinct from old.service_order_id)
     and exists (select 1 from public.service_orders o where o.id = new.service_order_id and o.agreement_id is not null) then
    raise exception 'Dieser Auftrag ist im Jahresvertrag enthalten und wird jährlich abgerechnet' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger invoices_agreement_check before insert or update of agreement_id, service_order_id on public.invoices
  for each row execute function private.invoices_agreement_check();

-- Aufträge automatisch dem passenden aktiven Vertrag zuordnen (gleiches Haus, gleicher Partner,
-- Titel beginnt mit der Vertragsaufgabe, Termin in der Laufzeit). Partner können die Zuordnung nicht ändern:
-- service_orders_guard setzt bei Partner-Updates alle Felder außer Status/Termin/Notiz/Kosten zurück.
create or replace function private.service_orders_agreement()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
  v_day date := coalesce(new.scheduled_at, now())::date;
begin
  if tg_op = 'INSERT' and new.agreement_id is null and new.service_partner_id is not null then
    select a.* into v_ag from public.service_agreements a
    where a.organization_id = new.organization_id and a.property_id = new.property_id
      and a.service_partner_id = new.service_partner_id and a.status = 'active'
      and v_day between a.starts_on and a.ends_on
      and lower(trim(new.title)) like lower(trim(a.task_title)) || '%'
    order by a.starts_on desc limit 1;
    new.agreement_id := v_ag.id;
  end if;
  if new.agreement_id is not null and (tg_op = 'INSERT' or new.agreement_id is distinct from old.agreement_id) then
    select * into v_ag from public.service_agreements where id = new.agreement_id;
    if v_ag.id is null or v_ag.organization_id <> new.organization_id or v_ag.property_id <> new.property_id
       or v_ag.service_partner_id is distinct from new.service_partner_id or v_ag.status <> 'active' then
      raise exception 'Auftrag passt nicht zum Jahresvertrag' using errcode = '22023';
    end if;
    new.actual_cost := null;
  end if;
  return new;
end;
$$;
create trigger service_orders_agreement before insert or update of agreement_id on public.service_orders
  for each row execute function private.service_orders_agreement();

-- -----------------------------------------------------------------------------
-- Funktionen: vorschlagen, annehmen/ablehnen, beenden
-- -----------------------------------------------------------------------------
create or replace function private.agreement_notify(p_ag public.service_agreements, p_to_partner boolean, p_title text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select m.organization_id, m.user_id, 'agreement', p_title,
         left(concat_ws(' · ', p_ag.title, to_char(p_ag.annual_price, 'FM999G999G990D00') || ' ' || p_ag.currency || '/Jahr'), 200), 'service_agreement', p_ag.id
  from public.organization_members m
  where m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting')
    and m.organization_id = case when p_to_partner
      then (select sp.partner_organization_id from public.service_partners sp where sp.id = p_ag.service_partner_id)
      else p_ag.organization_id end;
end;
$$;

create or replace function public.propose_service_agreement(
  p_service_partner_id uuid, p_property_id uuid, p_task_title text, p_annual_price numeric,
  p_starts_on date default current_date, p_ends_on date default null, p_interval_label text default null,
  p_visits_per_year integer default null, p_notes text default null, p_title text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_sp   public.service_partners;
  v_side text;
  v_ag   public.service_agreements;
begin
  select * into v_sp from public.service_partners where id = p_service_partner_id;
  if v_sp.id is null then raise exception 'Servicepartner nicht gefunden' using errcode = 'P0002'; end if;
  if private.is_org_staff(v_sp.organization_id) then v_side := 'owner';
  elsif private.is_partner_member(v_sp.id) then v_side := 'partner';
  else raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if not exists (select 1 from public.properties p where p.id = p_property_id and p.organization_id = v_sp.organization_id) then
    raise exception 'Haus gehört nicht zu diesem Kunden' using errcode = '22023';
  end if;
  insert into public.service_agreements (organization_id, property_id, service_partner_id, title, task_title, interval_label,
    visits_per_year, annual_price, currency, starts_on, ends_on, notes, status, proposed_by, proposed_by_user, responded_at)
  values (v_sp.organization_id, p_property_id, v_sp.id,
    coalesce(nullif(trim(p_title), ''), trim(p_task_title) || ' – Jahresvertrag ' || to_char(coalesce(p_starts_on, current_date), 'YYYY')),
    trim(p_task_title), nullif(trim(p_interval_label), ''), p_visits_per_year, round(p_annual_price, 2),
    (select o.currency from public.organizations o where o.id = v_sp.organization_id),
    coalesce(p_starts_on, current_date), coalesce(p_ends_on, (coalesce(p_starts_on, current_date) + interval '1 year' - interval '1 day')::date),
    nullif(trim(p_notes), ''),
    -- eigener Kunde eines Partners (ohne Husora-Konto): sofort gültig
    case when v_sp.partner_organization_id = v_sp.organization_id then 'active' else 'proposed' end,
    v_side, private.current_user_id(),
    case when v_sp.partner_organization_id = v_sp.organization_id then now() end)
  returning * into v_ag;
  if v_ag.status = 'proposed' then
    perform private.agreement_notify(v_ag, v_side = 'owner', 'Neuer Jahresvertrag vorgeschlagen');
  end if;
  return v_ag.id;
end;
$$;

create or replace function public.respond_service_agreement(p_agreement_id uuid, p_accept boolean)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
  v_side text;
begin
  select * into v_ag from public.service_agreements where id = p_agreement_id for update;
  if v_ag.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  if private.is_org_staff(v_ag.organization_id) then v_side := 'owner';
  elsif private.is_partner_member(v_ag.service_partner_id) then v_side := 'partner';
  else raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_ag.status <> 'proposed' then raise exception 'Der Vertrag ist nicht mehr offen' using errcode = '22023'; end if;
  if v_ag.proposed_by = v_side then raise exception 'Den eigenen Vorschlag nimmt die andere Seite an' using errcode = '42501'; end if;
  update public.service_agreements set status = case when p_accept then 'active' else 'declined' end, responded_at = now()
  where id = v_ag.id returning * into v_ag;
  perform private.agreement_notify(v_ag, v_side = 'owner', case when p_accept then 'Jahresvertrag angenommen' else 'Jahresvertrag abgelehnt' end);
  -- offene, passende Aufträge gleich mit in den Vertrag nehmen
  if p_accept then
    update public.service_orders o set agreement_id = v_ag.id
    where o.organization_id = v_ag.organization_id and o.property_id = v_ag.property_id
      and o.service_partner_id = v_ag.service_partner_id and o.agreement_id is null
      and o.status in ('offered', 'accepted', 'scheduled', 'in_progress')
      and coalesce(o.scheduled_at, now())::date between v_ag.starts_on and v_ag.ends_on
      and lower(trim(o.title)) like lower(trim(v_ag.task_title)) || '%'
      and not exists (select 1 from public.invoices i where i.service_order_id = o.id);
  end if;
  return v_ag.status;
end;
$$;

create or replace function public.end_service_agreement(p_agreement_id uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
begin
  select * into v_ag from public.service_agreements where id = p_agreement_id for update;
  if v_ag.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  if not (private.is_org_staff(v_ag.organization_id) or private.is_partner_member(v_ag.service_partner_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_ag.status not in ('proposed', 'active') then raise exception 'Der Vertrag ist bereits beendet' using errcode = '22023'; end if;
  update public.service_agreements set status = case when status = 'proposed' then 'cancelled' else 'ended' end,
    ends_on = case when status = 'active' then least(ends_on, greatest(starts_on + 1, current_date)) else ends_on end
  where id = v_ag.id returning * into v_ag;
  return v_ag.status;
end;
$$;

revoke all on function public.propose_service_agreement(uuid, uuid, text, numeric, date, date, text, integer, text, text) from public, anon;
revoke all on function public.respond_service_agreement(uuid, boolean) from public, anon;
revoke all on function public.end_service_agreement(uuid) from public, anon;
revoke all on function private.agreement_notify(public.service_agreements, boolean, text) from public, anon, authenticated;
grant execute on function public.propose_service_agreement(uuid, uuid, text, numeric, date, date, text, integer, text, text) to authenticated;
grant execute on function public.respond_service_agreement(uuid, boolean) to authenticated;
grant execute on function public.end_service_agreement(uuid) to authenticated;

-- Änderungsprotokoll
create trigger service_agreements_audit after insert or update or delete on public.service_agreements
  for each row execute function private.audit_row_change();
