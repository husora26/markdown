-- =============================================================================
-- HUSORA · Migration 1100 · Audit-Log für Kerntabellen
-- =============================================================================
-- Schreibt jede Änderung nach public.audit_logs (wer, was, alt/neu, IP).
-- Personenbezogene Gästedaten werden im Log maskiert.

create or replace function private.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_org     uuid;
  v_ip      inet;
  v_headers jsonb;
  v_mask    text[] := array['guest_email', 'guest_phone', 'credentials_reference', 'secret_reference'];
  v_key     text;
begin
  if tg_op = 'UPDATE' and v_old - 'updated_at' - 'updated_by' = v_new - 'updated_at' - 'updated_by' then
    return null;  -- keine fachliche Änderung
  end if;

  v_org := case when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid
                else (v_row ->> 'organization_id')::uuid end;
  if tg_table_name = 'organizations' and tg_op = 'DELETE' then
    v_org := null;
  elsif v_org is not null and not exists (select 1 from public.organizations o where o.id = v_org) then
    return null;  -- Organisation wird gerade gelöscht (cascade); protokolliert wird nur die Organisation
  end if;

  foreach v_key in array v_mask loop
    if v_old ? v_key and v_old ->> v_key is not null then v_old := jsonb_set(v_old, array[v_key], '"***"'); end if;
    if v_new ? v_key and v_new ->> v_key is not null then v_new := jsonb_set(v_new, array[v_key], '"***"'); end if;
  end loop;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
    v_ip := split_part(coalesce(v_headers ->> 'x-forwarded-for', v_headers ->> 'x-real-ip'), ',', 1)::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, old_data, new_data, ip_address, user_agent)
  values (v_org, private.current_user_id(), lower(tg_op), tg_table_name, (v_row ->> 'id')::uuid, v_old, v_new, v_ip,
          left(v_headers ->> 'user-agent', 500));
  return null;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'organizations', 'organization_members', 'properties', 'property_users', 'service_partners',
    'booking_sources', 'bookings', 'inspection_templates', 'inspections', 'service_tasks', 'service_orders',
    'maintenance', 'repairs', 'documents', 'quotes', 'invoices', 'automation_rules', 'webhook_endpoints'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function private.audit_row_change()',
      t || '_audit', t);
  end loop;
end;
$$;
