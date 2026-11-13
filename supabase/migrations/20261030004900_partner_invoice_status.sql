-- =============================================================================
-- HUSORA · Partner-Portal: Zahlungseingang und Storno von Rechnungen
-- =============================================================================
-- Die RLS-Policy invoices_update lässt Partner nur Rechnungen im Status draft/received ändern.
-- Den Zahlungseingang vermerkt der Partner aber meist erst, nachdem der Hausbesitzer freigegeben hat.
-- Diese Funktion erlaubt dem Partnerbetrieb (Leitung oder Buchhaltung) genau drei Statuswechsel –
-- ohne Beträge oder andere Felder anfassen zu können:
--   paid       received/approved/overdue → paid (paid_at = jetzt)
--   unpaid     paid → approved (wenn freigegeben) bzw. received
--   cancelled  draft/received → cancelled (freigegebene Rechnungen storniert nur der Kunde)

create or replace function public.partner_set_invoice_status(p_invoice_id uuid, p_status text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_inv public.invoices;
  v_partner_org uuid;
  v_me uuid := private.current_user_id();
  v_new text;
begin
  select * into v_inv from public.invoices where id = p_invoice_id for update;
  if v_inv.id is null then raise exception 'Rechnung nicht gefunden.' using errcode = 'P0002'; end if;
  select sp.partner_organization_id into v_partner_org from public.service_partners sp where sp.id = v_inv.service_partner_id;
  if not (private.is_org_staff(v_inv.organization_id)
          or (private.is_partner_member(v_inv.service_partner_id) and v_partner_org is not null
              and private.has_org_role(v_partner_org, array['admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting']))) then
    raise exception 'Keine Berechtigung für diese Rechnung.' using errcode = '42501';
  end if;
  if p_status = 'paid' then
    if v_inv.status not in ('received', 'approved', 'overdue') then raise exception 'Diese Rechnung kann nicht als bezahlt markiert werden.' using errcode = '22023'; end if;
    update public.invoices set status = 'paid', paid_at = now(), updated_by = v_me where id = v_inv.id returning status into v_new;
  elsif p_status = 'unpaid' then
    if v_inv.status <> 'paid' then raise exception 'Diese Rechnung ist nicht als bezahlt markiert.' using errcode = '22023'; end if;
    update public.invoices set status = case when v_inv.approved_at is not null then 'approved' else 'received' end, paid_at = null, updated_by = v_me
      where id = v_inv.id returning status into v_new;
  elsif p_status = 'cancelled' then
    if v_inv.status not in ('draft', 'received') and not private.is_org_staff(v_inv.organization_id) then
      raise exception 'Freigegebene Rechnungen kann nur der Kunde stornieren.' using errcode = '22023';
    end if;
    update public.invoices set status = 'cancelled', updated_by = v_me where id = v_inv.id returning status into v_new;
  else
    raise exception 'Unbekannter Status: %', p_status using errcode = '22023';
  end if;
  return v_new;
end;
$$;

revoke all on function public.partner_set_invoice_status(uuid, text) from public, anon;
grant execute on function public.partner_set_invoice_status(uuid, text) to authenticated;
