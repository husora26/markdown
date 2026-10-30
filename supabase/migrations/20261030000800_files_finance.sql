-- =============================================================================
-- HUSORA · Migration 0800 · Dokumente, Fotos, Angebote, Rechnungen
-- =============================================================================
-- Dateien liegen in Supabase Storage. Die Tabellen speichern nur Metadaten und
-- den Pfad. Pfadkonvention (wird per CHECK erzwungen):
--   organization/{organization_id}/property/{property_id}/{photos|documents|inspections|repairs}/…
--   organization/{organization_id}/documents/…   (Dokumente ohne Hausbezug)

-- -----------------------------------------------------------------------------
-- documents
-- -----------------------------------------------------------------------------
create table public.documents (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  property_id       uuid,
  service_order_id  uuid,
  repair_id         uuid,
  inspection_id     uuid,
  uploaded_by       uuid references public.users(id) on delete set null,
  file_name         text not null check (length(trim(file_name)) > 0),
  file_type         text,
  file_size         bigint check (file_size >= 0),
  storage_bucket    text not null default 'husora-documents' check (storage_bucket in ('husora-documents', 'husora-private', 'husora-public')),
  storage_path      text not null,
  document_type     text not null default 'other' check (document_type in (
                      'contract', 'invoice', 'quote', 'inspection_report', 'repair_report', 'manual',
                      'insurance', 'permit', 'floor_plan', 'energy_certificate', 'other')),
  description       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, id),
  unique (storage_bucket, storage_path),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, repair_id) references public.repairs (organization_id, id) on delete set null (repair_id),
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  constraint documents_storage_path_check check (
    storage_path not like '%..%' and (
      (property_id is not null and storage_path like 'organization/' || organization_id::text || '/property/' || property_id::text || '/%')
      or (property_id is null and storage_path like 'organization/' || organization_id::text || '/documents/%')
    )
  )
);
create index documents_org_type_idx on public.documents (organization_id, document_type);
create index documents_property_idx on public.documents (property_id, created_at desc) where property_id is not null;
create index documents_order_idx on public.documents (service_order_id) where service_order_id is not null;
create index documents_repair_idx on public.documents (repair_id) where repair_id is not null;
create index documents_inspection_idx on public.documents (inspection_id) where inspection_id is not null;
create index documents_uploaded_by_idx on public.documents (uploaded_by);
create index documents_created_at_idx on public.documents (created_at);
create trigger documents_set_updated_at before update on public.documents
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- photos
-- -----------------------------------------------------------------------------
create table public.photos (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  inspection_id       uuid,
  inspection_item_id  uuid references public.inspection_items(id) on delete set null,
  repair_id           uuid,
  service_order_id    uuid,
  service_task_id     uuid,
  uploaded_by         uuid references public.users(id) on delete set null,
  storage_bucket      text not null default 'husora-property-photos' check (storage_bucket in ('husora-property-photos', 'husora-private', 'husora-public')),
  storage_path        text not null,
  caption             text,
  taken_at            timestamptz,
  created_at          timestamptz not null default now(),
  unique (storage_bucket, storage_path),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  foreign key (organization_id, repair_id) references public.repairs (organization_id, id) on delete set null (repair_id),
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, service_task_id) references public.service_tasks (organization_id, id) on delete set null (service_task_id),
  constraint photos_storage_path_check check (
    storage_path not like '%..%'
    and storage_path like 'organization/' || organization_id::text || '/property/' || property_id::text || '/%'
  )
);
create index photos_property_idx on public.photos (property_id, created_at desc);
create index photos_org_idx on public.photos (organization_id);
create index photos_inspection_idx on public.photos (inspection_id) where inspection_id is not null;
create index photos_inspection_item_idx on public.photos (inspection_item_id) where inspection_item_id is not null;
create index photos_repair_idx on public.photos (repair_id) where repair_id is not null;
create index photos_order_idx on public.photos (service_order_id) where service_order_id is not null;
create index photos_task_idx on public.photos (service_task_id) where service_task_id is not null;
create index photos_uploaded_by_idx on public.photos (uploaded_by);
create index photos_created_at_idx on public.photos (created_at);
create trigger photos_check_item before insert or update of inspection_item_id, inspection_id on public.photos
  for each row execute function private.check_inspection_item_scope();

-- Hochladende Person automatisch eintragen
create or replace function private.set_uploaded_by()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.uploaded_by := coalesce(private.current_user_id(), new.uploaded_by);
  return new;
end;
$$;
create trigger documents_set_uploaded_by before insert on public.documents
  for each row execute function private.set_uploaded_by();
create trigger photos_set_uploaded_by before insert on public.photos
  for each row execute function private.set_uploaded_by();

-- -----------------------------------------------------------------------------
-- quotes: Angebote von Servicepartnern
-- -----------------------------------------------------------------------------
create table public.quotes (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  repair_id           uuid,
  service_order_id    uuid,
  service_partner_id  uuid,
  document_id         uuid,
  quote_number        text,
  description         text,
  amount_net          numeric(12, 2) check (amount_net >= 0),
  tax_amount          numeric(12, 2) check (tax_amount >= 0),
  amount_gross        numeric(12, 2) check (amount_gross >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  status              text not null default 'requested' check (status in ('requested', 'received', 'approved', 'rejected', 'expired')),
  valid_until         date,
  received_at         timestamptz,
  decided_at          timestamptz,
  decided_by          uuid references public.users(id) on delete set null,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, repair_id) references public.repairs (organization_id, id) on delete set null (repair_id),
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  foreign key (organization_id, document_id) references public.documents (organization_id, id) on delete set null (document_id),
  check (amount_gross is null or amount_net is null or tax_amount is null or amount_gross = amount_net + tax_amount)
);
create unique index quotes_partner_number_unique_idx on public.quotes (organization_id, service_partner_id, quote_number)
  where quote_number is not null;
create index quotes_org_status_idx on public.quotes (organization_id, status);
create index quotes_property_idx on public.quotes (property_id);
create index quotes_repair_idx on public.quotes (repair_id) where repair_id is not null;
create index quotes_order_idx on public.quotes (service_order_id) where service_order_id is not null;
create index quotes_partner_status_idx on public.quotes (service_partner_id, status);
create index quotes_created_at_idx on public.quotes (created_at);

-- -----------------------------------------------------------------------------
-- invoices: Rechnungen von Servicepartnern
-- -----------------------------------------------------------------------------
create table public.invoices (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  service_order_id    uuid,
  service_partner_id  uuid,
  document_id         uuid,
  invoice_number      text,
  amount_net          numeric(12, 2) check (amount_net >= 0),
  tax_amount          numeric(12, 2) check (tax_amount >= 0),
  amount_gross        numeric(12, 2) check (amount_gross >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  invoice_date        date,
  due_date            date,
  status              text not null default 'received' check (status in ('draft', 'received', 'approved', 'paid', 'overdue', 'cancelled')),
  approved_at         timestamptz,
  approved_by         uuid references public.users(id) on delete set null,
  paid_at             timestamptz,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  foreign key (organization_id, document_id) references public.documents (organization_id, id) on delete set null (document_id),
  check (amount_gross is null or amount_net is null or tax_amount is null or amount_gross = amount_net + tax_amount),
  check (due_date is null or invoice_date is null or due_date >= invoice_date),
  check (status <> 'paid' or paid_at is not null)
);
create unique index invoices_partner_number_unique_idx on public.invoices (organization_id, service_partner_id, invoice_number)
  where invoice_number is not null;
create index invoices_org_status_idx on public.invoices (organization_id, status);
create index invoices_property_date_idx on public.invoices (property_id, invoice_date);
create index invoices_order_idx on public.invoices (service_order_id) where service_order_id is not null;
create index invoices_partner_status_idx on public.invoices (service_partner_id, status);
create index invoices_due_idx on public.invoices (due_date) where status in ('received', 'approved', 'overdue');
create index invoices_created_at_idx on public.invoices (created_at);

-- Partner dürfen Angebote/Rechnungen nur einreichen, nicht freigeben oder bezahlen
create or replace function private.finance_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_system_context() or private.is_org_staff(new.organization_id) then
    null;
  elsif private.is_partner_member(coalesce(new.service_partner_id, old.service_partner_id)) then
    if tg_op = 'UPDATE' and (new.service_partner_id is distinct from old.service_partner_id
                             or new.property_id is distinct from old.property_id
                             or new.organization_id is distinct from old.organization_id) then
      raise exception 'Zuordnung darf vom Partner nicht geändert werden' using errcode = '42501';
    end if;
    if new.status not in ('requested', 'received', 'draft') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
  end if;

  if tg_table_name = 'quotes' then
    if new.status = 'received' and (tg_op = 'INSERT' or old.status <> 'received') then
      new.received_at := coalesce(new.received_at, now());
    elsif new.status in ('approved', 'rejected') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      new.decided_at := now();
      new.decided_by := private.current_user_id();
    end if;
  else
    if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
      new.approved_at := coalesce(new.approved_at, now());
      new.approved_by := coalesce(new.approved_by, private.current_user_id());
    elsif new.status = 'paid' then
      new.paid_at := coalesce(new.paid_at, now());
    end if;
  end if;
  return new;
end;
$$;

create trigger quotes_guard before insert or update on public.quotes
  for each row execute function private.finance_guard();
create trigger quotes_set_actor before insert or update on public.quotes
  for each row execute function private.set_actor_columns();
create trigger quotes_set_updated_at before update on public.quotes
  for each row execute function private.set_updated_at();
create trigger invoices_guard before insert or update on public.invoices
  for each row execute function private.finance_guard();
create trigger invoices_set_actor before insert or update on public.invoices
  for each row execute function private.set_actor_columns();
create trigger invoices_set_updated_at before update on public.invoices
  for each row execute function private.set_updated_at();

-- Freigegebene Rechnung schreibt die Ist-Kosten in den Auftrag
create or replace function private.sync_order_cost_from_invoice()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.service_order_id is not null and new.status in ('approved', 'paid') and new.amount_gross is not null then
    update public.service_orders o
    set actual_cost = (
      select sum(i.amount_gross) from public.invoices i
      where i.service_order_id = new.service_order_id and i.status in ('approved', 'paid')
    )
    where o.id = new.service_order_id;
  end if;
  return new;
end;
$$;
create trigger invoices_sync_order_cost after insert or update of status, amount_gross on public.invoices
  for each row execute function private.sync_order_cost_from_invoice();
