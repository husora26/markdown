-- =============================================================================
-- HUSORA · Migration 2500 · Monatszähler und serverseitige Tarifgrenzen
-- =============================================================================
-- 1) Monatszähler für Inseratimporte und Rechnungsanalysen (atomar, je Organisation)
-- 2) Häuser- und Dokumentengrenze je Tarif auch in der Datenbank
--    (bestehende Daten bleiben bei einem Downgrade unangetastet – nur neue Einträge
--     über dem Limit werden abgelehnt; Partner-Uploads zählen nicht gegen den Kunden)

create table public.usage_counters (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  metric          text not null check (metric in ('listing_imports_month', 'invoice_analyses_month')),
  period          date not null,
  count           integer not null default 0 check (count >= 0),
  updated_at      timestamptz not null default now(),
  primary key (organization_id, metric, period)
);
comment on table public.usage_counters is 'Verbrauch je Monat (Inseratimporte, Rechnungsanalysen). Schreiben nur über consume_usage().';
alter table public.usage_counters enable row level security;
create policy usage_counters_select on public.usage_counters for select to authenticated using (private.can_read_org(organization_id));
grant select on public.usage_counters to authenticated;
grant all on public.usage_counters to service_role;

-- Verbraucht eine Einheit, wenn das Monatslimit des Tarifs es zulässt
create or replace function public.consume_usage(p_organization_id uuid, p_metric text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_limit integer;
  v_used integer;
  v_period date := date_trunc('month', now())::date;
begin
  if not private.is_org_staff(p_organization_id) then
    raise exception 'Keine Berechtigung für diese Organisation' using errcode = '42501';
  end if;
  if p_metric not in ('listing_imports_month', 'invoice_analyses_month') then
    raise exception 'Unbekannter Zähler' using errcode = '22023';
  end if;
  select nullif(p.limits ->> p_metric, '')::integer into v_limit from public.plans p where p.id = private.org_plan(p_organization_id);
  insert into public.usage_counters (organization_id, metric, period, count) values (p_organization_id, p_metric, v_period, 0)
  on conflict do nothing;
  select count into v_used from public.usage_counters where organization_id = p_organization_id and metric = p_metric and period = v_period for update;
  if v_limit is not null and v_used >= v_limit then
    return jsonb_build_object('ok', false, 'used', v_used, 'limit', v_limit);
  end if;
  update public.usage_counters set count = count + 1, updated_at = now()
  where organization_id = p_organization_id and metric = p_metric and period = v_period;
  return jsonb_build_object('ok', true, 'used', v_used + 1, 'limit', v_limit);
end;
$$;
revoke all on function public.consume_usage(uuid, text) from public, anon;
grant execute on function public.consume_usage(uuid, text) to authenticated;

-- Tarifgrenze für neue Häuser und Dokumente
create or replace function private.enforce_plan_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_key text := case tg_table_name when 'properties' then 'properties' else 'documents' end;
  v_limit integer;
  v_used integer;
begin
  if auth.uid() is null or coalesce(auth.role(), '') = 'service_role' then return new; end if;
  if exists (select 1 from public.organizations o where o.id = new.organization_id and o.org_type = 'service_partner') then return new; end if;
  -- Uploads von Servicepartnern (z. B. Rechnungen, Fotos zum Auftrag) zählen nicht gegen den Kunden
  if not private.is_org_member(new.organization_id) then return new; end if;
  select nullif(p.limits ->> v_key, '')::integer into v_limit from public.plans p where p.id = private.org_plan(new.organization_id);
  if v_limit is null then return new; end if;
  if tg_table_name = 'properties' then
    select count(*) into v_used from public.properties where organization_id = new.organization_id;
  else
    select count(*) into v_used from public.documents where organization_id = new.organization_id;
  end if;
  if v_used >= v_limit then
    raise exception 'Tariflimit erreicht: höchstens % % in deinem Tarif.', v_limit, case when v_key = 'properties' and v_limit = 1 then 'Haus' when v_key = 'properties' then 'Häuser' when v_limit = 1 then 'Dokument' else 'Dokumente' end using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger properties_plan_limit before insert on public.properties
  for each row execute function private.enforce_plan_limit();
create trigger documents_plan_limit before insert on public.documents
  for each row execute function private.enforce_plan_limit();
