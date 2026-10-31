-- =============================================================================
-- HUSORA · Migration 1900 · Leistungsgruppen für Servicepartner
-- =============================================================================
-- Im Partner-Portal wählt ein Betrieb nur noch drei Leistungsgruppen:
-- Hauskontrolle (inspection, besteht bereits), Servicearbeiten und Sanierungen.
-- Preise je Arbeitspaket (price_unit = 'job') oder je Stunde ('hour').

insert into public.service_types (id, organization_id, code, name, description, category) values
  ('eeeeeeee-0000-4000-8000-000000000015', null, 'service_work', 'Servicearbeiten', 'Hausservice, Reinigung, Garten, Winterdienst, kleine Reparaturen', 'service'),
  ('eeeeeeee-0000-4000-8000-000000000016', null, 'renovation',   'Sanierungen',     'Sanierung und Renovierung: Dach, Fassade, Fenster, Bad, Technik',  'craft')
on conflict on constraint service_types_code_unique do nothing;

-- -----------------------------------------------------------------------------
-- Hausfotos für beauftragte Servicepartner
-- -----------------------------------------------------------------------------
-- Ein Partner sieht die allgemeinen Fotos eines Hauses (ohne Bezug zu Auftrag,
-- Kontrolle, Aufgabe oder Reparatur), solange er für genau dieses Haus einen
-- Auftrag hat (angefragt, angenommen, terminiert, in Arbeit oder erledigt).
-- Abgelehnte, stornierte und Entwurfsaufträge geben nichts frei.
create or replace function private.is_property_partner(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.property_id = p_property_id
      and o.status in ('offered', 'accepted', 'scheduled', 'in_progress', 'completed')
      and (private.is_partner_member(o.service_partner_id)
           or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id)))
  )
$$;
grant execute on function private.is_property_partner(uuid) to authenticated, service_role;

drop policy photos_select on public.photos;
create policy photos_select on public.photos for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or private.is_property_owner(property_id)
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id))
    or (repair_id is not null and private.can_read_repair(repair_id))
    or (property_id is not null and inspection_id is null and service_order_id is null and service_task_id is null and repair_id is null
        and private.is_property_partner(property_id))
  );
