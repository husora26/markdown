-- =============================================================================
-- HUSORA · Migration 2000 · Schnellere Partner-Prüfung in den RLS-Regeln
-- =============================================================================
-- private.is_partner_member wurde pro geprüfter Zeile über my_partner_ids()
-- ausgewertet, also über die komplette Liste aller Partner des Nutzers. Bei vielen
-- Zeilen (Aufträge, Fotos, Nachrichten) führte das zu Zeitüberschreitungen.
-- Gleiche Logik, aber als gezielte Prüfung genau eines Partners über die
-- vorhandenen Indizes (service_partners.id, organization_members(organization_id, user_id),
-- service_partner_users(service_partner_id, user_id)).

create or replace function private.is_partner_member(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_service_partner_id is not null and (
    -- Leitung des Partnerbetriebs (eigene Partner-Organisation)
    exists (
      select 1
      from public.service_partners sp
      join public.organization_members m on m.organization_id = sp.partner_organization_id
      where sp.id = p_service_partner_id
        and m.user_id = (select private.current_user_id())
        and m.status = 'active'
        and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting')
    )
    -- direkt dem Partner zugeordneter Nutzer, der selbst Mitglied der beauftragenden Organisation ist
    or exists (
      select 1
      from public.service_partner_users spu
      join public.service_partners sp on sp.id = spu.service_partner_id
      where spu.service_partner_id = p_service_partner_id
        and spu.user_id = (select private.current_user_id())
        and private.org_role(sp.organization_id) is not null
    )
  )
$$;
