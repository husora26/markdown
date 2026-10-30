-- =============================================================================
-- HUSORA · Migration 0600 · Hauskontrollen: Vorlagen, Kontrollen, Prüfpunkte
-- =============================================================================

create table public.inspection_templates (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  name             text not null,
  description      text,
  property_type    text,
  active           boolean not null default true,
  version          integer not null default 1 check (version >= 1),
  created_by       uuid references public.users(id) on delete set null,
  updated_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, id)
);
create index inspection_templates_org_idx on public.inspection_templates (organization_id) where active;
create trigger inspection_templates_set_updated_at before update on public.inspection_templates
  for each row execute function private.set_updated_at();
create trigger inspection_templates_set_actor before insert or update on public.inspection_templates
  for each row execute function private.set_actor_columns();

create table public.inspection_template_items (
  id              uuid primary key default gen_random_uuid(),
  template_id     uuid not null references public.inspection_templates(id) on delete cascade,
  category        text,
  name            text not null,
  description     text,
  sort_order      integer not null default 0,
  required        boolean not null default false,
  default_status  text not null default 'not_checked' check (default_status in ('ok', 'warning', 'defect', 'not_checked', 'not_applicable')),
  frequency       text check (frequency is null or frequency in ('weekly', 'biweekly', 'monthly', 'quarterly', 'semiannual', 'yearly')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on column public.inspection_template_items.frequency is 'Prüftaktung der Position (z. B. monthly); NULL = bei jeder Kontrolle.';
create index inspection_template_items_template_idx on public.inspection_template_items (template_id, sort_order);
create trigger inspection_template_items_set_updated_at before update on public.inspection_template_items
  for each row execute function private.set_updated_at();

create table public.inspections (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  template_id         uuid,
  inspector_user_id   uuid references public.users(id) on delete set null,
  service_partner_id  uuid,
  booking_id          uuid,
  scheduled_at        timestamptz,
  started_at          timestamptz,
  completed_at        timestamptz,
  status              text not null default 'scheduled' check (status in ('scheduled', 'in_progress', 'completed', 'cancelled')),
  overall_status      text check (overall_status in ('ok', 'warning', 'critical')),
  notes               text,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, template_id) references public.inspection_templates (organization_id, id) on delete set null (template_id),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  foreign key (organization_id, booking_id) references public.bookings (organization_id, id) on delete set null (booking_id),
  check (completed_at is null or started_at is null or completed_at >= started_at),
  check (status <> 'completed' or completed_at is not null)
);
comment on column public.inspections.service_partner_id is 'Partnerbetrieb, der die Kontrolle durchführt (alternativ zu inspector_user_id).';
create index inspections_property_scheduled_idx on public.inspections (property_id, scheduled_at);
create index inspections_org_status_idx on public.inspections (organization_id, status);
create index inspections_inspector_idx on public.inspections (inspector_user_id) where inspector_user_id is not null;
create index inspections_partner_idx on public.inspections (service_partner_id) where service_partner_id is not null;
create index inspections_booking_idx on public.inspections (booking_id) where booking_id is not null;
create index inspections_template_idx on public.inspections (template_id) where template_id is not null;
create index inspections_created_at_idx on public.inspections (created_at);
create trigger inspections_set_updated_at before update on public.inspections
  for each row execute function private.set_updated_at();
create trigger inspections_set_actor before insert or update on public.inspections
  for each row execute function private.set_actor_columns();

create table public.inspection_items (
  id                uuid primary key default gen_random_uuid(),
  inspection_id     uuid not null references public.inspections(id) on delete cascade,
  template_item_id  uuid references public.inspection_template_items(id) on delete set null,
  category          text,
  name              text not null,
  status            text not null default 'not_checked' check (status in ('ok', 'warning', 'defect', 'not_checked', 'not_applicable')),
  notes             text,
  estimated_cost    numeric(12, 2) check (estimated_cost >= 0),
  photo_required    boolean not null default false,
  checked_at        timestamptz,
  checked_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (inspection_id, template_item_id)
);
comment on column public.inspection_items.name is 'Kopie des Positionsnamens zum Zeitpunkt der Kontrolle – bleibt erhalten, wenn die Vorlage geändert wird.';
create index inspection_items_inspection_status_idx on public.inspection_items (inspection_id, status);
create index inspection_items_template_item_idx on public.inspection_items (template_item_id) where template_item_id is not null;
create index inspection_items_defects_idx on public.inspection_items (inspection_id) where status in ('warning', 'defect');
create trigger inspection_items_set_updated_at before update on public.inspection_items
  for each row execute function private.set_updated_at();

-- Prüfpunkte beim Anlegen einer Kontrolle aus der Vorlage übernehmen
create or replace function private.create_items_from_template()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.template_id is not null then
    insert into public.inspection_items (inspection_id, template_item_id, category, name, status, photo_required)
    select new.id, ti.id, ti.category, ti.name, ti.default_status, false
    from public.inspection_template_items ti
    where ti.template_id = new.template_id
    order by ti.sort_order
    on conflict (inspection_id, template_item_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger inspections_create_items after insert on public.inspections
  for each row execute function private.create_items_from_template();

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer Kontrolle
-- -----------------------------------------------------------------------------
create or replace function private.can_read_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (
        private.can_read_org(i.organization_id)
        or private.is_property_owner(i.property_id)
        or (i.inspector_user_id = private.current_user_id() and private.is_org_member(i.organization_id))
        or private.is_partner_member(i.service_partner_id)
      )
  )
$$;

-- Prüfpunkte bearbeiten: Verwaltung, eingeteilter Prüfer oder beauftragter Partner
create or replace function private.can_work_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and i.status in ('scheduled', 'in_progress')
      and (
        private.is_org_staff(i.organization_id)
        or (i.inspector_user_id = private.current_user_id() and private.is_org_member(i.organization_id))
        or private.is_partner_member(i.service_partner_id)
      )
  ) or exists (
    select 1 from public.inspections i where i.id = p_inspection_id and private.is_org_staff(i.organization_id)
  )
$$;
