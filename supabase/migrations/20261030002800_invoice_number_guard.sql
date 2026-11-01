-- =============================================================================
-- Rechnungsnummern: doppelte automatische Nummern serverseitig auflösen
-- Ältere App-Versionen schlugen „Anzahl + 1“ vor (z. B. R-2026-0003, obwohl schon vergeben).
-- Statt mit „duplicate key … invoices_partner_number_unique_idx“ abzubrechen, bekommt eine
-- automatische Nummer (R-JJJJ-NNNN) die nächste freie Nummer; eine selbst gewählte Nummer
-- wird mit einer verständlichen Meldung abgelehnt.
-- =============================================================================
create or replace function private.invoices_number_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_prefix text;
  v_max    integer;
begin
  if new.invoice_number is null or new.service_partner_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.invoice_number is not distinct from old.invoice_number then return new; end if;
  if not exists (select 1 from public.invoices i where i.organization_id = new.organization_id and i.service_partner_id = new.service_partner_id
                 and i.invoice_number = new.invoice_number and i.id <> new.id) then
    return new;
  end if;
  if new.invoice_number !~ '^R-\d{4}-\d+$' then
    raise exception 'Die Rechnungsnummer „%“ wurde diesem Kunden bereits gestellt – bitte eine andere Nummer verwenden.', new.invoice_number using errcode = '23505';
  end if;
  v_prefix := substring(new.invoice_number from '^(R-\d{4}-)');
  select coalesce(max((substring(i.invoice_number from '\d+$'))::integer), 0) into v_max
  from public.invoices i
  where i.organization_id = new.organization_id and i.service_partner_id = new.service_partner_id
    and i.invoice_number ~ ('^' || v_prefix || '\d+$');
  new.invoice_number := v_prefix || lpad((v_max + 1)::text, 4, '0');
  return new;
end;
$$;
create trigger invoices_number_guard before insert or update of invoice_number on public.invoices
  for each row execute function private.invoices_number_guard();
