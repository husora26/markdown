-- =============================================================================
-- HUSORA · Migration 2400 · Zugangsdaten zeitlich begrenzt für einen Auftrag freigeben
-- =============================================================================
-- Der Hausbesitzer gibt Schlüsselort, Schlüsselbox-Code oder Alarmhinweis gezielt
-- für EINEN Auftrag frei – mit Ablaufzeit. Der Partner liest die Freigabe nur über
-- die Funktion order_access() (kein Tabellenzugriff), nur solange sie gültig ist und
-- der Auftrag angenommen/terminiert/in Arbeit ist. Jeder Abruf wird protokolliert.

create table public.order_access_shares (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  service_order_id uuid not null,
  access_text      text not null check (length(trim(access_text)) between 1 and 2000),
  valid_until      timestamptz not null,
  revoked_at       timestamptz,
  created_by       uuid references public.users(id) on delete set null default private.current_user_id(),
  created_at       timestamptz not null default now(),
  last_viewed_at   timestamptz,
  view_count       integer not null default 0,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete cascade,
  check (valid_until > created_at),
  check (valid_until <= created_at + interval '31 days')
);
comment on table public.order_access_shares is 'Zeitlich begrenzte Freigabe von Zugangsdaten für einen Auftrag. Partner lesen nur über order_access().';
create index order_access_shares_order_idx on public.order_access_shares (service_order_id, valid_until desc);

alter table public.order_access_shares enable row level security;
-- Nur die Verwaltung des Hausbesitzers sieht und verwaltet Freigaben (nicht „Nur lesen“, nicht Partner)
create policy order_access_shares_select on public.order_access_shares for select to authenticated using (private.is_org_staff(organization_id));
create policy order_access_shares_insert on public.order_access_shares for insert to authenticated with check (private.is_org_staff(organization_id));
create policy order_access_shares_update on public.order_access_shares for update to authenticated using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy order_access_shares_delete on public.order_access_shares for delete to authenticated using (private.is_org_staff(organization_id));
grant select, insert, update, delete on public.order_access_shares to authenticated;
grant all on public.order_access_shares to service_role;

-- Partner (oder zugewiesener Mitarbeiter) ruft die gültige Freigabe für seinen Auftrag ab
create or replace function public.order_access(p_service_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.service_orders;
  v_share public.order_access_shares;
begin
  select * into v_order from public.service_orders o where o.id = p_service_order_id;
  if v_order.id is null then return null; end if;
  if not (private.is_org_staff(v_order.organization_id)
          or private.is_partner_member(v_order.service_partner_id)
          or (v_order.assigned_user_id = private.current_user_id() and private.is_partner_employee(v_order.service_partner_id))) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_order.status not in ('accepted', 'scheduled', 'in_progress') and not private.is_org_staff(v_order.organization_id) then
    return null;
  end if;
  select * into v_share from public.order_access_shares s
  where s.service_order_id = v_order.id and s.revoked_at is null and s.valid_until > now()
  order by s.created_at desc limit 1;
  if v_share.id is null then return null; end if;
  if not private.is_org_staff(v_order.organization_id) then
    update public.order_access_shares set last_viewed_at = now(), view_count = view_count + 1 where id = v_share.id;
  end if;
  return jsonb_build_object('access_text', v_share.access_text, 'valid_until', v_share.valid_until, 'created_at', v_share.created_at);
end;
$$;
revoke all on function public.order_access(uuid) from public, anon;
grant execute on function public.order_access(uuid) to authenticated;

-- Freigaben enden automatisch mit dem Auftrag
create or replace function private.revoke_access_on_order_end()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status in ('completed', 'cancelled', 'rejected') and old.status is distinct from new.status then
    update public.order_access_shares set revoked_at = now() where service_order_id = new.id and revoked_at is null;
  end if;
  return new;
end;
$$;
create trigger service_orders_revoke_access after update of status on public.service_orders
  for each row execute function private.revoke_access_on_order_end();
