-- =============================================================================
-- HUSORA · Migration 1800 · Messenger zwischen Hausbesitzer und Servicepartner
-- =============================================================================
-- Neben Nachrichten zu einzelnen Aufträgen gibt es je Servicepartner einen
-- durchgehenden Gesprächsverlauf (messages.service_partner_id). Sichtbar nur für
-- die Verwaltung des Hausbesitzers und die Leitung des Partnerbetriebs.
-- Lesebestätigung: die jeweils andere Seite setzt read_at.

alter table public.messages add column service_partner_id uuid;
alter table public.messages add constraint messages_service_partner_fkey
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete cascade;
comment on column public.messages.service_partner_id is 'Gespräch mit einem Servicepartner (unabhängig von einzelnen Aufträgen).';
create index messages_partner_thread_idx on public.messages (service_partner_id, created_at) where service_partner_id is not null;
create index messages_unread_thread_idx on public.messages (organization_id, service_partner_id) where read_at is null;

alter table public.messages drop constraint messages_check;
alter table public.messages add constraint messages_check
  check (recipient_user_id is not null or service_order_id is not null or service_partner_id is not null);

-- Gesprächsverlauf mit einem Partner sehen/führen: Hausbesitzer-Verwaltung oder Partnerleitung
create or replace function private.can_access_partner_thread(p_organization_id uuid, p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_service_partner_id is not null
     and (private.can_read_org(p_organization_id) or private.is_partner_member(p_service_partner_id))
$$;

drop policy messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    sender_user_id = (select private.current_user_id())
    or recipient_user_id = (select private.current_user_id())
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or private.can_access_partner_thread(organization_id, service_partner_id)
  );

drop policy messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    (service_order_id is null or private.can_read_service_order(service_order_id))
    and (recipient_user_id is null or private.is_user_in_org(recipient_user_id, organization_id))
    and (
      (service_partner_id is not null and private.can_access_partner_thread(organization_id, service_partner_id))
      or (service_partner_id is null and (private.is_org_member(organization_id)
                                          or (service_order_id is not null and private.can_work_order(service_order_id))))
    )
  );

-- Gelesen markieren: Empfänger oder die andere Seite eines Gesprächs (Spaltenschutz: nur read_at)
create policy messages_mark_read on public.messages for update to authenticated
  using (
    sender_user_id is distinct from (select private.current_user_id())
    and (private.can_access_partner_thread(organization_id, service_partner_id)
         or (service_order_id is not null and private.can_read_service_order(service_order_id)))
  )
  with check (
    private.can_access_partner_thread(organization_id, service_partner_id)
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
  );

-- Benachrichtigung für die Verwaltung, wenn ein Partner schreibt
create or replace function private.notify_partner_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_partner text;
begin
  if new.service_partner_id is null or private.is_org_member(new.organization_id) then
    return new;  -- nur Nachrichten der Partnerseite melden
  end if;
  select sp.company_name into v_partner from public.service_partners sp where sp.id = new.service_partner_id;
  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select new.organization_id, m.user_id, 'message', 'Neue Nachricht von ' || coalesce(v_partner, 'Servicepartner'),
         left(new.message, 200), 'service_partner', new.service_partner_id
  from public.organization_members m
  where m.organization_id = new.organization_id and m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  return new;
end;
$$;
create trigger messages_notify_partner after insert on public.messages
  for each row execute function private.notify_partner_message();

grant execute on function private.can_access_partner_thread(uuid, uuid), private.notify_partner_message() to authenticated, service_role;
