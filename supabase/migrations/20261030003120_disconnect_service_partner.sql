-- =============================================================================
-- HUSORA · Verbindung zu einem Servicepartner trennen (Hausbesitzer)
-- =============================================================================
-- Nach dem Trennen sieht der Partnerbetrieb keine Aufträge, Häuser, Nachrichten oder Rechnungen
-- dieses Kunden mehr (alle Policies hängen an service_partners.partner_organization_id).
-- * offene und laufende Aufträge werden zurückgezogen, Zugangsfreigaben widerrufen
-- * laufende oder vorgeschlagene Jahresverträge enden
-- * freigegebene Telefonnummer/Adresse werden beim Partner gelöscht; die Kontaktkarte bleibt als eigener Kunde
-- * der Partner wird benachrichtigt; ein erneutes Verbinden ist mit einem neuen Einladungscode möglich
-- Idempotent.

alter table public.service_partners add column if not exists disconnected_at timestamptz;
comment on column public.service_partners.disconnected_at is 'Zeitpunkt, zu dem der Hausbesitzer die Verbindung getrennt hat';

create or replace function public.disconnect_service_partner(p_service_partner_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sp      public.service_partners;
  v_partner uuid;
  v_orders  integer := 0;
  v_reason  text := left(nullif(trim(p_reason), ''), 300);
begin
  select * into v_sp from public.service_partners sp where sp.id = p_service_partner_id for update;
  if v_sp.id is null or not private.is_org_staff(v_sp.organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  v_partner := v_sp.partner_organization_id;
  if v_partner is null then
    raise exception 'Dieser Servicepartner ist nicht verbunden' using errcode = '22023';
  end if;
  if v_partner = v_sp.organization_id then
    raise exception 'Der eigene Betrieb kann nicht getrennt werden' using errcode = '22023';
  end if;

  -- offene und laufende Aufträge zurückziehen (Zugänge werden per Trigger widerrufen)
  update public.service_orders o
  set status = 'cancelled',
      response_note = 'Zurückgezogen: Verbindung zum Servicepartner getrennt' || coalesce(' – ' || v_reason, '') || '.'
  where o.service_partner_id = v_sp.id
    and o.status in ('draft', 'offered', 'accepted', 'scheduled', 'in_progress', 'waiting_customer', 'waiting_parts');
  get diagnostics v_orders = row_count;
  update public.order_access_shares s set revoked_at = now()
  where s.revoked_at is null and s.service_order_id in (select o.id from public.service_orders o where o.service_partner_id = v_sp.id);

  update public.service_agreements a set status = case when a.status = 'proposed' then 'cancelled' else 'ended' end
  where a.service_partner_id = v_sp.id and a.status in ('proposed', 'active');

  -- offene Einladungen verwerfen
  delete from public.service_partner_invites i where i.service_partner_id = v_sp.id and i.accepted_at is null;

  -- Kontaktkarte beim Partner: freigegebene Daten löschen, Karte wird eigener Kunde ohne Zugriff
  update public.customers c
  set phone = case when v_sp.share_phone then null else c.phone end,
      street = case when v_sp.share_address then null else c.street end,
      postal_code = case when v_sp.share_address then null else c.postal_code end,
      city = case when v_sp.share_address then null else c.city end,
      linked_organization_id = null,
      notes = left(concat_ws(E'\n', nullif(c.notes, ''), 'Verbindung am ' || to_char(now(), 'DD.MM.YYYY') || ' vom Kunden getrennt.'), 4000)
  where c.organization_id = v_partner and c.linked_organization_id = v_sp.organization_id;

  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select v_partner, m.user_id, 'service_order',
         (select o.name from public.organizations o where o.id = v_sp.organization_id) || ' hat die Verbindung getrennt',
         left(concat_ws(' · ', case when v_orders > 0 then v_orders || ' offene Aufträge zurückgezogen' end, v_reason), 200),
         'organization', v_sp.organization_id
  from public.organization_members m
  where m.organization_id = v_partner and m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');

  update public.service_partners sp
  set partner_organization_id = null, share_phone = false, share_address = false, contact_decided_at = null, disconnected_at = now()
  where sp.id = v_sp.id;

  return jsonb_build_object('cancelled_orders', v_orders);
end;
$$;
revoke all on function public.disconnect_service_partner(uuid, text) from public, anon;
grant execute on function public.disconnect_service_partner(uuid, text) to authenticated;
