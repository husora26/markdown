-- =============================================================================
-- HUSORA · Mangel vom Servicepartner → Anfrage beim Hausbesitzer → Reparaturauftrag
-- =============================================================================
-- Ablauf (wie bei Serviceaufgaben):
--   1. Der Servicepartner meldet einen Mangel (aus einer Kontrolle oder während eines Auftrags)
--      und fragt beim Hausbesitzer die Beseitigung an: public.partner_offer_repair()
--      → repairs-Zeile mit status 'reported', service_partner_id = Verbindung zum Partner.
--   2. Der Hausbesitzer sieht die Anfrage unter „Mängel & Reparaturen“ und nimmt sie an oder
--      lehnt ab: public.respond_repair_offer(). Annahme erzeugt einen Auftrag (status 'accepted',
--      Art 'repair') beim selben Partner; der Mangel steht auf 'approved' (in Bearbeitung).
--   3. Der Partner plant, beseitigt und rechnet über den Auftrag ab (bestehender Ablauf);
--      der Status des Auftrags wird auf den Mangel übertragen.
-- Idempotent.

alter table public.repairs
  add column if not exists service_partner_id uuid references public.service_partners(id) on delete set null,
  add column if not exists source            text not null default 'owner',
  add column if not exists offered_at        timestamptz,
  add column if not exists response_note     text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'repairs_source_check') then
    alter table public.repairs add constraint repairs_source_check check (source in ('owner', 'partner', 'inspection'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'repairs_response_note_check') then
    alter table public.repairs add constraint repairs_response_note_check check (response_note is null or length(response_note) <= 1000);
  end if;
end $$;
create index if not exists repairs_service_partner_idx on public.repairs (service_partner_id, status) where service_partner_id is not null;
create index if not exists repairs_service_order_idx on public.repairs (service_order_id) where service_order_id is not null;
comment on column public.repairs.service_partner_id is 'Servicepartner (Verbindung beim Hausbesitzer), der den Mangel gemeldet und die Beseitigung angefragt hat';

-- Partner sieht die von ihm gemeldeten Mängel
drop policy if exists repairs_select on public.repairs;
create policy repairs_select on public.repairs for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
    or (service_partner_id is not null and private.is_partner_member(service_partner_id))
  );

-- -----------------------------------------------------------------------------
-- 1) Partner fragt die Beseitigung an
-- -----------------------------------------------------------------------------
create or replace function public.partner_offer_repair(
  p_property_id uuid,
  p_title text,
  p_description text default null,
  p_estimated_cost numeric default null,
  p_inspection_item_id uuid default null,
  p_service_order_id uuid default null,
  p_priority text default 'normal'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org     uuid := private.property_org(p_property_id);
  v_sp      public.service_partners;
  v_item    public.inspection_items;
  v_insp    uuid;
  v_id      uuid;
  v_title   text := left(nullif(trim(p_title), ''), 160);
  v_prio    text := case when p_priority in ('low', 'normal', 'high', 'urgent') then p_priority else 'normal' end;
begin
  if v_org is null then raise exception 'Haus nicht gefunden' using errcode = 'P0002'; end if;
  if v_title is null then raise exception 'Bitte den Mangel kurz beschreiben' using errcode = '22023'; end if;
  if p_estimated_cost is not null and p_estimated_cost < 0 then raise exception 'Die Kosten dürfen nicht negativ sein' using errcode = '22023'; end if;
  -- verbundener Partnerbetrieb des angemeldeten Nutzers für diesen Kunden
  select sp.* into v_sp from public.service_partners sp
  where sp.organization_id = v_org and sp.partner_organization_id is not null
    and sp.partner_organization_id <> v_org and private.is_partner_member(sp.id)
  limit 1;
  if v_sp.id is null then
    raise exception 'Nur verbundene Servicepartner können Mängel beim Kunden melden' using errcode = '42501';
  end if;
  if not (private.can_read_property(p_property_id) or private.partner_property_level(p_property_id) is not null) then
    raise exception 'Keine Berechtigung für dieses Haus' using errcode = '42501';
  end if;
  if p_inspection_item_id is not null then
    select ii.* into v_item from public.inspection_items ii join public.inspections i on i.id = ii.inspection_id
    where ii.id = p_inspection_item_id and i.property_id = p_property_id;
    if v_item.id is null then raise exception 'Prüfpunkt gehört nicht zu diesem Haus' using errcode = '22023'; end if;
    v_insp := v_item.inspection_id;
    if exists (select 1 from public.repairs r where r.inspection_item_id = p_inspection_item_id and r.status in ('reported', 'approved', 'assigned', 'in_progress')) then
      raise exception 'Für diesen Mangel läuft bereits eine Anfrage' using errcode = '23505';
    end if;
  end if;
  if p_service_order_id is not null and not exists (
       select 1 from public.service_orders o where o.id = p_service_order_id and o.property_id = p_property_id and o.service_partner_id = v_sp.id) then
    raise exception 'Auftrag gehört nicht zu diesem Haus' using errcode = '22023';
  end if;

  insert into public.repairs (organization_id, property_id, inspection_id, inspection_item_id, title, description, priority, status,
                              estimated_cost, service_partner_id, source, offered_at, created_by)
  values (v_org, p_property_id, v_insp, p_inspection_item_id, v_title, left(nullif(trim(p_description), ''), 2000), v_prio, 'reported',
          p_estimated_cost, v_sp.id, case when p_inspection_item_id is not null then 'inspection' else 'partner' end, now(), private.current_user_id())
  returning id into v_id;

  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select v_org, m.user_id, 'service_order',
         coalesce(v_sp.company_name, 'Servicepartner') || ' meldet einen Mangel: ' || v_title,
         left(concat_ws(' · ', (select p.name from public.properties p where p.id = p_property_id),
                        case when p_estimated_cost is not null then 'ca. ' || p_estimated_cost::text end,
                        'Beseitigung anfragen unter Mängel & Reparaturen'), 200),
         'repair', v_id
  from public.organization_members m
  where m.organization_id = v_org and m.status = 'active' and m.role in ('admin', 'property_manager', 'service_manager');
  return v_id;
end;
$$;
revoke all on function public.partner_offer_repair(uuid, text, text, numeric, uuid, uuid, text) from public, anon;
grant execute on function public.partner_offer_repair(uuid, text, text, numeric, uuid, uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2) Hausbesitzer nimmt an (→ Auftrag) oder lehnt ab
-- -----------------------------------------------------------------------------
create or replace function public.respond_repair_offer(p_repair_id uuid, p_accept boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r     public.repairs;
  v_sp    public.service_partners;
  v_order uuid;
  v_note  text := left(nullif(trim(p_note), ''), 1000);
begin
  select * into v_r from public.repairs r where r.id = p_repair_id for update;
  if v_r.id is null or not private.is_org_staff(v_r.organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_r.status <> 'reported' or v_r.service_partner_id is null then
    raise exception 'Diese Anfrage ist nicht mehr offen' using errcode = '22023';
  end if;
  select * into v_sp from public.service_partners sp where sp.id = v_r.service_partner_id;

  if not p_accept then
    update public.repairs set status = 'cancelled', response_note = v_note where id = v_r.id;
    if v_sp.partner_organization_id is not null then
      insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
      select v_sp.partner_organization_id, m.user_id, 'service_order', 'Mangelbeseitigung abgelehnt: ' || v_r.title, left(coalesce(v_note, ''), 200), 'repair', v_r.id
      from public.organization_members m
      where m.organization_id = v_sp.partner_organization_id and m.status = 'active' and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
    end if;
    return jsonb_build_object('status', 'cancelled');
  end if;

  if v_sp.partner_organization_id is null then
    raise exception 'Der Servicepartner ist nicht mehr verbunden' using errcode = '22023';
  end if;
  insert into public.service_orders (organization_id, property_id, service_partner_id, title, description, status,
                                     estimated_cost, currency, priority, order_type, response_note, created_by)
  values (v_r.organization_id, v_r.property_id, v_sp.id, left('Mangelbeseitigung: ' || v_r.title, 200), v_r.description, 'accepted',
          v_r.estimated_cost, (select o.currency from public.organizations o where o.id = v_r.organization_id),
          case v_r.priority when 'urgent' then 'urgent' when 'high' then 'high' else 'normal' end, 'repair', v_note, private.current_user_id())
  returning id into v_order;
  update public.repairs set status = 'approved', approved_at = now(), approved_by = private.current_user_id(),
                            service_order_id = v_order, response_note = v_note
  where id = v_r.id;

  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select v_sp.partner_organization_id, m.user_id, 'service_order', 'Mangelbeseitigung beauftragt: ' || v_r.title,
         left(concat_ws(' · ', (select p.name from public.properties p where p.id = v_r.property_id), 'Termin festlegen unter Mängel'), 200), 'service_order', v_order
  from public.organization_members m
  where m.organization_id = v_sp.partner_organization_id and m.status = 'active' and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  return jsonb_build_object('status', 'approved', 'service_order_id', v_order);
end;
$$;
revoke all on function public.respond_repair_offer(uuid, boolean, text) from public, anon;
grant execute on function public.respond_repair_offer(uuid, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 3) Status des Reparaturauftrags auf den Mangel übertragen
-- -----------------------------------------------------------------------------
create or replace function private.sync_repair_from_order()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status is not distinct from old.status then return null; end if;
  update public.repairs r
  set status = case
                 when new.status in ('in_progress', 'waiting_customer', 'waiting_parts', 'scheduled') then 'in_progress'
                 when new.status = 'completed' then 'completed'
                 when new.status in ('cancelled', 'rejected') then 'cancelled'
                 else r.status end,
      completed_at = case when new.status = 'completed' then coalesce(r.completed_at, now()) else r.completed_at end,
      actual_cost = case when new.status = 'completed' then coalesce(new.actual_cost, r.actual_cost) else r.actual_cost end
  where r.service_order_id = new.id and r.status not in ('completed', 'cancelled');
  return null;
end;
$$;
drop trigger if exists service_orders_sync_repair on public.service_orders;
create trigger service_orders_sync_repair after update of status on public.service_orders
  for each row execute function private.sync_repair_from_order();
