-- =============================================================================
-- HUSORA · Migration 0900 · Automatisierung, Benachrichtigungen, Nachrichten,
--                           Audit-Log, Webhooks
-- =============================================================================

-- -----------------------------------------------------------------------------
-- automation_rules
-- Beispiele:  booking_created → create_cleaning_task
--             booking_checkout → create_inspection
--             inspection_item_defect → create_repair
-- -----------------------------------------------------------------------------
create table public.automation_rules (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  name              text not null check (length(trim(name)) > 0),
  description       text,
  trigger_type      text not null check (trigger_type in (
                      'booking_created', 'booking_checkout', 'booking_cancelled',
                      'inspection_completed', 'inspection_item_defect',
                      'service_order_rejected', 'maintenance_due')),
  trigger_config    jsonb not null default '{}'::jsonb,
  condition_config  jsonb not null default '{}'::jsonb,
  action_config     jsonb not null,
  active            boolean not null default true,
  sort_order        integer not null default 0,
  created_by        uuid references public.users(id) on delete set null,
  updated_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, id),
  check (jsonb_typeof(trigger_config) = 'object' and jsonb_typeof(condition_config) = 'object'),
  check (action_config ->> 'type' in (
           'create_task', 'create_cleaning_task', 'create_inspection', 'create_repair',
           'notify', 'cancel_booking_tasks', 'offer_next_partner'))
);
comment on column public.automation_rules.trigger_config is 'Zeitbezug, z. B. {"anchor": "check_out", "offset_hours": 1, "duration_hours": 3}';
comment on column public.automation_rules.condition_config is 'Bedingungen, z. B. {"sources": ["airbnb"], "min_nights": 2, "exclude_owner_stays": true, "item_statuses": ["defect"]}';
comment on column public.automation_rules.action_config is 'Aktion, z. B. {"type": "create_cleaning_task", "service_type_code": "cleaning", "title": "Endreinigung {property_name}", "auto_assign": true}';
create index automation_rules_org_trigger_idx on public.automation_rules (organization_id, trigger_type) where active;
create trigger automation_rules_set_updated_at before update on public.automation_rules
  for each row execute function private.set_updated_at();
create trigger automation_rules_set_actor before insert or update on public.automation_rules
  for each row execute function private.set_actor_columns();

-- -----------------------------------------------------------------------------
-- automation_runs: Protokoll jeder Ausführung (idempotent über idempotency_key)
-- -----------------------------------------------------------------------------
create table public.automation_runs (
  id                  uuid primary key default gen_random_uuid(),
  automation_rule_id  uuid not null,
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  trigger_type        text not null,
  entity_type         text not null,
  entity_id           uuid not null,
  idempotency_key     text not null,
  status              text not null default 'running' check (status in ('running', 'completed', 'failed', 'skipped')),
  input_data          jsonb,
  output_data         jsonb,
  error_message       text,
  started_at          timestamptz not null default now(),
  completed_at        timestamptz,
  foreign key (organization_id, automation_rule_id) references public.automation_rules (organization_id, id) on delete cascade,
  unique (automation_rule_id, idempotency_key)
);
create index automation_runs_org_started_idx on public.automation_runs (organization_id, started_at desc);
create index automation_runs_rule_idx on public.automation_runs (automation_rule_id, started_at desc);
create index automation_runs_entity_idx on public.automation_runs (entity_type, entity_id);
create index automation_runs_failed_idx on public.automation_runs (organization_id, started_at desc) where status = 'failed';

-- -----------------------------------------------------------------------------
-- notifications: persönliche Benachrichtigungen
-- -----------------------------------------------------------------------------
create table public.notifications (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid not null references public.users(id) on delete cascade,
  type             text not null default 'info',
  title            text not null,
  message          text,
  entity_type      text,
  entity_id        uuid,
  read_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;
create index notifications_org_idx on public.notifications (organization_id, created_at desc);
create index notifications_entity_idx on public.notifications (entity_type, entity_id);

-- -----------------------------------------------------------------------------
-- messages: Nachrichten zwischen Verwaltung und Partner (je Auftrag oder direkt)
-- -----------------------------------------------------------------------------
create table public.messages (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations(id) on delete cascade,
  sender_user_id     uuid references public.users(id) on delete set null,
  recipient_user_id  uuid references public.users(id) on delete set null,
  service_order_id   uuid,
  message            text not null check (length(trim(message)) between 1 and 10000),
  created_at         timestamptz not null default now(),
  read_at            timestamptz,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete cascade,
  check (recipient_user_id is not null or service_order_id is not null)
);
comment on table public.messages is 'Direktnachricht (recipient_user_id) oder Auftrags-Thread (service_order_id).';
create index messages_order_idx on public.messages (service_order_id, created_at) where service_order_id is not null;
create index messages_recipient_idx on public.messages (recipient_user_id, created_at desc) where recipient_user_id is not null;
create index messages_recipient_unread_idx on public.messages (recipient_user_id) where read_at is null;
create index messages_sender_idx on public.messages (sender_user_id, created_at desc);
create index messages_org_idx on public.messages (organization_id, created_at desc);

-- Absender immer der angemeldete Benutzer; danach darf nur der Empfänger read_at setzen
create or replace function private.messages_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_read timestamptz;
begin
  if private.is_system_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.sender_user_id := private.current_user_id();
    new.read_at := null;
    new.created_at := now();
  else
    v_read := new.read_at;
    new := old;
    new.read_at := v_read;
  end if;
  return new;
end;
$$;
create trigger messages_guard before insert or update on public.messages
  for each row execute function private.messages_guard();

-- Benachrichtigungen: Benutzer dürfen nur read_at ändern
create or replace function private.notifications_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_read timestamptz;
begin
  if not private.is_system_context() then
    v_read := new.read_at;
    new := old;
    new.read_at := v_read;
  end if;
  return new;
end;
$$;
create trigger notifications_guard before update on public.notifications
  for each row execute function private.notifications_guard();

-- -----------------------------------------------------------------------------
-- audit_logs: Änderungsprotokoll (wird ausschließlich per Trigger geschrieben)
-- -----------------------------------------------------------------------------
create table public.audit_logs (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid references public.organizations(id) on delete cascade,
  user_id          uuid references public.users(id) on delete set null,
  action           text not null check (action in ('insert', 'update', 'delete')),
  entity_type      text not null,
  entity_id        uuid,
  old_data         jsonb,
  new_data         jsonb,
  ip_address       inet,
  user_agent       text,
  created_at       timestamptz not null default now()
);
create index audit_logs_org_created_idx on public.audit_logs (organization_id, created_at desc);
create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id, created_at desc);
create index audit_logs_user_idx on public.audit_logs (user_id) where user_id is not null;
-- BRIN: sehr kleiner Index für zeitlich wachsende, große Tabellen
create index audit_logs_created_at_brin on public.audit_logs using brin (created_at);

-- -----------------------------------------------------------------------------
-- Webhooks: authentifiziert · idempotent · protokolliert · wiederholbar
-- -----------------------------------------------------------------------------
create table public.webhook_endpoints (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  endpoint          text not null check (endpoint in ('channel-manager', 'booking', 'payment', 'service-order', 'partner')),
  provider          text not null,
  secret_reference  text not null check (secret_reference ~ '^vault:[A-Za-z0-9_.-]+$'),
  active            boolean not null default true,
  last_received_at  timestamptz,
  created_by        uuid references public.users(id) on delete set null,
  updated_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, endpoint, provider)
);
comment on column public.webhook_endpoints.secret_reference is 'Signatur-Secret in Supabase Vault (vault:<name>). Niemals das Secret selbst speichern.';
create trigger webhook_endpoints_set_updated_at before update on public.webhook_endpoints
  for each row execute function private.set_updated_at();
create trigger webhook_endpoints_set_actor before insert or update on public.webhook_endpoints
  for each row execute function private.set_actor_columns();

create table public.webhook_events (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid references public.organizations(id) on delete cascade,
  webhook_endpoint_id  uuid references public.webhook_endpoints(id) on delete set null,
  endpoint             text not null check (endpoint in ('channel-manager', 'booking', 'payment', 'service-order', 'partner')),
  provider             text not null,
  event_id             text not null,
  event_type           text,
  payload              jsonb not null,
  headers              jsonb,
  status               text not null default 'received' check (status in ('received', 'processing', 'processed', 'failed', 'ignored')),
  attempts             integer not null default 0 check (attempts >= 0),
  max_attempts         integer not null default 8 check (max_attempts > 0),
  next_attempt_at      timestamptz default now(),
  locked_until         timestamptz,
  last_error           text,
  received_at          timestamptz not null default now(),
  processed_at         timestamptz,
  -- Idempotenz: dieselbe Zustellung wird nie doppelt verarbeitet
  constraint webhook_events_idempotency unique (endpoint, provider, event_id)
);
comment on column public.webhook_events.headers is 'Nur unkritische Header (ohne Authorization/Signatur).';
create index webhook_events_queue_idx on public.webhook_events (next_attempt_at)
  where status in ('received', 'failed');
create index webhook_events_processing_idx on public.webhook_events (locked_until) where status = 'processing';
create index webhook_events_org_idx on public.webhook_events (organization_id, received_at desc);

-- Signatur prüfen (HMAC-SHA256, Secret aus Supabase Vault)
create or replace function public.webhook_verify_signature(p_webhook_endpoint_id uuid, p_body text, p_signature text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref      text;
  v_secret   text;
  v_expected text;
  v_given    text := lower(regexp_replace(coalesce(p_signature, ''), '^sha256=', ''));
begin
  select e.secret_reference into v_ref from public.webhook_endpoints e where e.id = p_webhook_endpoint_id and e.active;
  if v_ref is null then
    return false;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into v_secret using substr(v_ref, 7);
  if v_secret is null then
    return false;
  end if;
  v_expected := encode(extensions.hmac(convert_to(p_body, 'UTF8'), convert_to(v_secret, 'UTF8'), 'sha256'), 'hex');
  return length(v_given) = length(v_expected) and v_given = v_expected;
end;
$$;

-- Eingang speichern. Doppelte Zustellung → vorhandenes Ereignis, is_duplicate = true.
create or replace function public.webhook_receive(
  p_endpoint text,
  p_provider text,
  p_event_id text,
  p_payload jsonb,
  p_signature_valid boolean,
  p_event_type text default null,
  p_headers jsonb default null,
  p_webhook_endpoint_id uuid default null
)
returns table (webhook_event_id uuid, is_duplicate boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id  uuid;
  v_org uuid;
begin
  if not coalesce(p_signature_valid, false) then
    raise exception 'Webhook-Signatur ungültig' using errcode = '28000';
  end if;
  if p_webhook_endpoint_id is not null then
    select e.organization_id into v_org from public.webhook_endpoints e where e.id = p_webhook_endpoint_id;
    update public.webhook_endpoints set last_received_at = now() where id = p_webhook_endpoint_id;
  end if;

  insert into public.webhook_events (organization_id, webhook_endpoint_id, endpoint, provider, event_id, event_type, payload, headers)
  values (v_org, p_webhook_endpoint_id, p_endpoint, p_provider, p_event_id, p_event_type, p_payload,
          coalesce(p_headers, '{}'::jsonb) - 'authorization' - 'Authorization' - 'x-signature' - 'x-hub-signature-256')
  on conflict on constraint webhook_events_idempotency do nothing
  returning id into v_id;

  if v_id is not null then
    return query select v_id, false;
  else
    return query
      select we.id, true from public.webhook_events we
      where we.endpoint = p_endpoint and we.provider = p_provider and we.event_id = p_event_id;
  end if;
end;
$$;

-- Nächste fällige Ereignisse sperren und zur Verarbeitung ausgeben (parallel sicher)
create or replace function public.webhook_claim(p_limit integer default 10, p_lock_seconds integer default 300)
returns setof public.webhook_events
language sql
security definer
set search_path = ''
as $$
  update public.webhook_events we
  set status = 'processing',
      attempts = we.attempts + 1,
      locked_until = now() + make_interval(secs => p_lock_seconds)
  where we.id in (
    select q.id from public.webhook_events q
    where (q.status in ('received', 'failed') and q.next_attempt_at <= now() and q.attempts < q.max_attempts)
       or (q.status = 'processing' and q.locked_until < now() and q.attempts < q.max_attempts)
    order by q.next_attempt_at nulls last
    limit p_limit
    for update skip locked
  )
  returning we.*
$$;

-- Ergebnis zurückmelden. Fehler → erneuter Versuch mit exponentiellem Backoff (max. 6 h).
create or replace function public.webhook_complete(p_webhook_event_id uuid, p_success boolean, p_error text default null, p_organization_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.webhook_events we
  set status = case when p_success then 'processed' else 'failed' end,
      processed_at = case when p_success then now() else null end,
      last_error = case when p_success then null else left(p_error, 4000) end,
      locked_until = null,
      organization_id = coalesce(we.organization_id, p_organization_id),
      next_attempt_at = case
        when p_success or we.attempts >= we.max_attempts then null
        else now() + least(interval '6 hours', make_interval(mins => power(2, we.attempts)::integer))
      end
  where we.id = p_webhook_event_id;
end;
$$;

-- Manuell wiederholen (service_role oder Admin der Organisation)
create or replace function public.webhook_retry(p_webhook_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.webhook_events we
  set status = 'received', next_attempt_at = now(), locked_until = null,
      max_attempts = greatest(we.max_attempts, we.attempts + 1)
  where we.id = p_webhook_event_id
    and we.status in ('failed', 'ignored', 'processed')
    and (private.is_system_context() or (we.organization_id is not null and private.is_org_admin(we.organization_id)));
  if not found then
    raise exception 'Webhook-Ereignis nicht gefunden oder keine Berechtigung' using errcode = '42501';
  end if;
end;
$$;

-- Buchung aus Channel Manager / Airbnb / Booking.com idempotent übernehmen
create or replace function public.upsert_external_booking(
  p_organization_id uuid,
  p_property_id uuid,
  p_source text,
  p_external_booking_id text,
  p_check_in timestamptz,
  p_check_out timestamptz,
  p_status text default 'confirmed',
  p_guest_first_name text default null,
  p_guest_last_name text default null,
  p_guest_email text default null,
  p_guest_phone text default null,
  p_guest_count integer default null,
  p_booking_source_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.bookings (organization_id, property_id, booking_source_id, source, external_booking_id,
                               guest_first_name, guest_last_name, guest_email, guest_phone, guest_count,
                               check_in, check_out, status)
  values (p_organization_id, p_property_id, p_booking_source_id, p_source, p_external_booking_id,
          p_guest_first_name, p_guest_last_name, p_guest_email, p_guest_phone, p_guest_count,
          p_check_in, p_check_out, p_status)
  on conflict (organization_id, source, external_booking_id) where external_booking_id is not null
  do update set
    check_in = excluded.check_in,
    check_out = excluded.check_out,
    status = excluded.status,
    guest_first_name = coalesce(excluded.guest_first_name, public.bookings.guest_first_name),
    guest_last_name = coalesce(excluded.guest_last_name, public.bookings.guest_last_name),
    guest_email = coalesce(excluded.guest_email, public.bookings.guest_email),
    guest_phone = coalesce(excluded.guest_phone, public.bookings.guest_phone),
    guest_count = coalesce(excluded.guest_count, public.bookings.guest_count)
  returning id into v_id;
  if p_booking_source_id is not null then
    update public.booking_sources set last_synced_at = now() where id = p_booking_source_id;
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Automation Engine
-- -----------------------------------------------------------------------------
-- Bedingungen prüfen
create or replace function private.automation_conditions_met(p_condition jsonb, p_context jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_condition ? 'sources'
     and not coalesce(p_context ->> 'source', '') in (select jsonb_array_elements_text(p_condition -> 'sources')) then
    return false;
  end if;
  if coalesce((p_condition ->> 'exclude_owner_stays')::boolean, false) and p_context ->> 'source' = 'owner' then
    return false;
  end if;
  if p_condition ? 'min_nights' and coalesce((p_context ->> 'nights')::numeric, 0) < (p_condition ->> 'min_nights')::numeric then
    return false;
  end if;
  if p_condition ? 'property_ids'
     and not coalesce(p_context ->> 'property_id', '') in (select jsonb_array_elements_text(p_condition -> 'property_ids')) then
    return false;
  end if;
  if p_context ? 'item_status'
     and not coalesce(p_context ->> 'item_status', '') in (
       select jsonb_array_elements_text(coalesce(p_condition -> 'item_statuses', '["defect"]'::jsonb))) then
    return false;
  end if;
  if p_condition ? 'overall_statuses' and p_context ? 'overall_status'
     and not coalesce(p_context ->> 'overall_status', '') in (select jsonb_array_elements_text(p_condition -> 'overall_statuses')) then
    return false;
  end if;
  return true;
end;
$$;

-- Platzhalter {property_name}, {guest_name}, {item_name}, {order_number} ersetzen
create or replace function private.automation_text(p_template text, p_context jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(coalesce(p_template, ''),
    '{property_name}', coalesce(p_context ->> 'property_name', '')),
    '{guest_name}', coalesce(p_context ->> 'guest_name', '')),
    '{item_name}', coalesce(p_context ->> 'item_name', '')),
    '{order_number}', coalesce(p_context ->> 'order_number', ''))
$$;

-- Serviceart über Code finden (eigene der Organisation vor globaler)
create or replace function private.service_type_by_code(p_organization_id uuid, p_code text)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select st.id from public.service_types st
  where st.code = p_code and st.active and (st.organization_id = p_organization_id or st.organization_id is null)
  order by st.organization_id nulls last
  limit 1
$$;

-- Aktion ausführen
create or replace function private.execute_automation_action(p_rule public.automation_rules, p_context jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_action    jsonb := p_rule.action_config;
  v_trigger   jsonb := p_rule.trigger_config;
  v_type      text := p_rule.action_config ->> 'type';
  v_org       uuid := p_rule.organization_id;
  v_property  uuid := (p_context ->> 'property_id')::uuid;
  v_anchor    timestamptz;
  v_start     timestamptz;
  v_end       timestamptz;
  v_id        uuid;
  v_type_id   uuid;
  v_partner   record;
  v_order     uuid;
  v_template  uuid;
  v_count     integer := 0;
  v_exclude   uuid[];
begin
  v_anchor := coalesce((p_context ->> coalesce(v_trigger ->> 'anchor', 'check_out'))::timestamptz, now());
  v_start := v_anchor + make_interval(hours => coalesce((v_trigger ->> 'offset_hours')::integer, 0));
  v_end := case when v_trigger ? 'duration_hours'
                then v_start + make_interval(hours => (v_trigger ->> 'duration_hours')::integer) end;

  if v_type in ('create_task', 'create_cleaning_task') then
    v_type_id := private.service_type_by_code(v_org, coalesce(v_action ->> 'service_type_code',
                   case when v_type = 'create_cleaning_task' then 'cleaning' end));
    insert into public.service_tasks (organization_id, property_id, booking_id, inspection_id, service_type_id,
                                      title, description, priority, scheduled_start, scheduled_end)
    values (v_org, v_property, (p_context ->> 'booking_id')::uuid, (p_context ->> 'inspection_id')::uuid, v_type_id,
            coalesce(nullif(private.automation_text(v_action ->> 'title', p_context), ''),
                     case when v_type = 'create_cleaning_task' then 'Endreinigung' else p_rule.name end),
            nullif(private.automation_text(v_action ->> 'description', p_context), ''),
            coalesce(v_action ->> 'priority', 'normal'), v_start, v_end)
    returning id into v_id;

    if coalesce((v_action ->> 'auto_assign')::boolean, false) and v_type_id is not null then
      select * into v_partner from public.match_service_partners(v_property, v_type_id, 1, null, v_start) limit 1;
      if v_partner.service_partner_id is not null then
        insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                           description, status, scheduled_at, estimated_cost, match_score)
        values (v_org, v_id, v_property, v_partner.service_partner_id,
                (select t.title from public.service_tasks t where t.id = v_id),
                nullif(private.automation_text(v_action ->> 'description', p_context), ''),
                'offered', v_start, v_partner.price_from, v_partner.score)
        returning id into v_order;
      end if;
    end if;
    return jsonb_build_object('service_task_id', v_id, 'service_order_id', v_order);

  elsif v_type = 'create_inspection' then
    v_template := coalesce((v_action ->> 'template_id')::uuid,
      (select t.id from public.inspection_templates t where t.organization_id = v_org and t.active order by t.created_at limit 1));
    insert into public.inspections (organization_id, property_id, template_id, booking_id, scheduled_at, notes)
    values (v_org, v_property, v_template, (p_context ->> 'booking_id')::uuid, v_start,
            nullif(private.automation_text(v_action ->> 'notes', p_context), ''))
    returning id into v_id;
    return jsonb_build_object('inspection_id', v_id);

  elsif v_type = 'create_repair' then
    insert into public.repairs (organization_id, property_id, inspection_id, inspection_item_id, title, description,
                                priority, estimated_cost)
    values (v_org, v_property, (p_context ->> 'inspection_id')::uuid, (p_context ->> 'inspection_item_id')::uuid,
            coalesce(v_action ->> 'title_prefix', 'Mangel: ') || coalesce(p_context ->> 'item_name', 'Kontrollpunkt'),
            p_context ->> 'item_notes',
            coalesce(v_action ->> 'priority', case when p_context ->> 'item_status' = 'defect' then 'high' else 'normal' end),
            (p_context ->> 'estimated_cost')::numeric)
    on conflict (inspection_item_id) where inspection_item_id is not null and status <> 'cancelled' do nothing
    returning id into v_id;
    return jsonb_build_object('repair_id', v_id);

  elsif v_type = 'notify' then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select v_org, u.user_id, coalesce(v_action ->> 'notification_type', 'automation'),
           coalesce(nullif(private.automation_text(v_action ->> 'title', p_context), ''), p_rule.name),
           nullif(private.automation_text(v_action ->> 'message', p_context), ''),
           p_context ->> 'entity_type', (p_context ->> 'entity_id')::uuid
    from (
      select m.user_id from public.organization_members m
      where m.organization_id = v_org and m.status = 'active'
        and m.role in (select jsonb_array_elements_text(coalesce(v_action -> 'roles', '["admin"]'::jsonb)))
      union
      select p.owner_user_id from public.properties p
      where coalesce((v_action ->> 'include_owner')::boolean, false) and p.id = v_property and p.owner_user_id is not null
    ) u;
    get diagnostics v_count = row_count;
    return jsonb_build_object('notifications', v_count);

  elsif v_type = 'cancel_booking_tasks' then
    update public.service_tasks set status = 'cancelled'
    where booking_id = (p_context ->> 'booking_id')::uuid and status in ('pending', 'assigned');
    get diagnostics v_count = row_count;
    update public.service_orders set status = 'cancelled'
    where service_task_id in (select t.id from public.service_tasks t where t.booking_id = (p_context ->> 'booking_id')::uuid)
      and status in ('draft', 'offered');
    update public.inspections set status = 'cancelled'
    where booking_id = (p_context ->> 'booking_id')::uuid and status = 'scheduled';
    return jsonb_build_object('cancelled_tasks', v_count);

  elsif v_type = 'offer_next_partner' then
    select array_agg(o.service_partner_id) into v_exclude from public.service_orders o
    where o.service_task_id = (p_context ->> 'service_task_id')::uuid and o.status = 'rejected';
    select * into v_partner from public.match_service_partners(
      v_property, (select t.service_type_id from public.service_tasks t where t.id = (p_context ->> 'service_task_id')::uuid),
      1, v_exclude, (p_context ->> 'scheduled_at')::timestamptz) limit 1;
    if v_partner.service_partner_id is null then
      return jsonb_build_object('service_order_id', null, 'reason', 'kein weiterer Partner verfügbar');
    end if;
    insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title, description,
                                       status, scheduled_at, estimated_cost, match_score)
    select o.organization_id, o.service_task_id, o.property_id, v_partner.service_partner_id, o.title, o.description,
           'offered', o.scheduled_at, coalesce(v_partner.price_from, o.estimated_cost), v_partner.score
    from public.service_orders o where o.id = (p_context ->> 'service_order_id')::uuid
    returning id into v_order;
    return jsonb_build_object('service_order_id', v_order);
  end if;

  raise exception 'Unbekannte Aktion %', v_type;
end;
$$;

-- Alle aktiven Regeln eines Auslösers ausführen. Jede Regel läuft höchstens einmal
-- je Auslöser und Objekt (idempotency_key); Fehler einer Regel stoppen die anderen nicht.
create or replace function private.run_automations(
  p_organization_id uuid,
  p_trigger_type text,
  p_entity_type text,
  p_entity_id uuid,
  p_context jsonb,
  p_idempotency_suffix text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule  public.automation_rules;
  v_run   uuid;
  v_out   jsonb;
  v_count integer := 0;
  v_ctx   jsonb := p_context || jsonb_build_object('entity_type', p_entity_type, 'entity_id', p_entity_id);
begin
  for v_rule in
    select * from public.automation_rules r
    where r.organization_id = p_organization_id and r.trigger_type = p_trigger_type and r.active
    order by r.sort_order, r.created_at
  loop
    v_run := null;
    insert into public.automation_runs (automation_rule_id, organization_id, trigger_type, entity_type, entity_id,
                                        idempotency_key, input_data)
    values (v_rule.id, p_organization_id, p_trigger_type, p_entity_type, p_entity_id,
            p_trigger_type || ':' || p_entity_id || coalesce(':' || p_idempotency_suffix, ''), v_ctx)
    on conflict (automation_rule_id, idempotency_key) do nothing
    returning id into v_run;
    continue when v_run is null;

    begin
      if not private.automation_conditions_met(v_rule.condition_config, v_ctx) then
        update public.automation_runs set status = 'skipped', completed_at = now(),
               output_data = '{"reason": "Bedingungen nicht erfüllt"}' where id = v_run;
        continue;
      end if;
      v_out := private.execute_automation_action(v_rule, v_ctx);
      update public.automation_runs set status = 'completed', output_data = v_out, completed_at = now() where id = v_run;
      v_count := v_count + 1;
    exception when others then
      update public.automation_runs set status = 'failed', error_message = sqlerrm, completed_at = now() where id = v_run;
    end;
  end loop;
  return v_count;
end;
$$;

-- Auslöser: Buchungen
create or replace function private.automation_on_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ctx jsonb;
begin
  v_ctx := jsonb_build_object(
    'booking_id', new.id,
    'property_id', new.property_id,
    'property_name', (select p.name from public.properties p where p.id = new.property_id),
    'source', new.source,
    'check_in', new.check_in,
    'check_out', new.check_out,
    'nights', ceil(extract(epoch from (new.check_out - new.check_in)) / 86400),
    'guest_count', new.guest_count,
    'guest_name', nullif(trim(coalesce(new.guest_first_name, '') || ' ' || coalesce(new.guest_last_name, '')), ''));

  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from 'confirmed') then
    perform private.run_automations(new.organization_id, 'booking_created', 'booking', new.id, v_ctx);
    perform private.run_automations(new.organization_id, 'booking_checkout', 'booking', new.id, v_ctx);
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    perform private.run_automations(new.organization_id, 'booking_cancelled', 'booking', new.id, v_ctx);
  end if;

  -- Verschobener Check-out: offene, automatisch erzeugte Termine mitziehen
  if tg_op = 'UPDATE' and new.status = 'confirmed' and new.check_out is distinct from old.check_out then
    update public.service_tasks t
    set scheduled_start = t.scheduled_start + (new.check_out - old.check_out),
        scheduled_end = t.scheduled_end + (new.check_out - old.check_out)
    where t.booking_id = new.id and t.status in ('pending', 'assigned', 'accepted') and t.scheduled_start is not null;
    update public.inspections i
    set scheduled_at = i.scheduled_at + (new.check_out - old.check_out)
    where i.booking_id = new.id and i.status = 'scheduled' and i.scheduled_at is not null;
  end if;
  return new;
end;
$$;

create trigger bookings_automation after insert or update of status, check_out on public.bookings
  for each row execute function private.automation_on_booking();

-- Auslöser: Mangel an einem Prüfpunkt
create or replace function private.automation_on_inspection_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_insp public.inspections;
begin
  if new.status not in ('warning', 'defect') or (tg_op = 'UPDATE' and old.status = new.status) then
    return new;
  end if;
  select * into v_insp from public.inspections i where i.id = new.inspection_id;
  perform private.run_automations(v_insp.organization_id, 'inspection_item_defect', 'inspection_item', new.id,
    jsonb_build_object(
      'inspection_id', v_insp.id,
      'inspection_item_id', new.id,
      'property_id', v_insp.property_id,
      'property_name', (select p.name from public.properties p where p.id = v_insp.property_id),
      'item_name', new.name,
      'item_notes', new.notes,
      'item_status', new.status,
      'estimated_cost', new.estimated_cost),
    new.status);
  return new;
end;
$$;

create trigger inspection_items_automation after insert or update of status on public.inspection_items
  for each row execute function private.automation_on_inspection_item();

-- Auslöser: Kontrolle abgeschlossen
create or replace function private.automation_on_inspection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform private.run_automations(new.organization_id, 'inspection_completed', 'inspection', new.id,
      jsonb_build_object(
        'inspection_id', new.id,
        'property_id', new.property_id,
        'property_name', (select p.name from public.properties p where p.id = new.property_id),
        'overall_status', new.overall_status,
        'defects', (select count(*) from public.inspection_items ii where ii.inspection_id = new.id and ii.status in ('warning', 'defect'))));
  end if;
  return new;
end;
$$;

create trigger inspections_automation after update of status on public.inspections
  for each row execute function private.automation_on_inspection();

-- Auslöser: Partner lehnt Auftrag ab
create or replace function private.automation_on_service_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'rejected' and old.status is distinct from 'rejected' then
    perform private.run_automations(new.organization_id, 'service_order_rejected', 'service_order', new.id,
      jsonb_build_object(
        'service_order_id', new.id,
        'service_task_id', new.service_task_id,
        'property_id', new.property_id,
        'property_name', (select p.name from public.properties p where p.id = new.property_id),
        'order_number', new.order_number,
        'scheduled_at', new.scheduled_at));
  end if;
  return new;
end;
$$;

create trigger service_orders_automation after update of status on public.service_orders
  for each row execute function private.automation_on_service_order();

-- Zeitgesteuert (pg_cron, z. B. stündlich): fällige Wartung, überfällige Rechnungen, alte Sperren
create or replace function public.run_scheduled_automations()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m        record;
  v_due      integer := 0;
  v_overdue  integer := 0;
begin
  for v_m in
    update public.maintenance m
    set status = case when m.next_due_at < now() then 'overdue' else 'due' end
    where m.status in ('active', 'due') and m.next_due_at is not null
      and m.next_due_at <= now() + interval '14 days'
      and m.status is distinct from (case when m.next_due_at < now() then 'overdue' else 'due' end)
    returning m.*
  loop
    v_due := v_due + 1;
    perform private.run_automations(v_m.organization_id, 'maintenance_due', 'maintenance', v_m.id,
      jsonb_build_object(
        'maintenance_id', v_m.id,
        'property_id', v_m.property_id,
        'property_name', (select p.name from public.properties p where p.id = v_m.property_id),
        'item_name', v_m.title,
        'check_out', v_m.next_due_at,
        'next_due_at', v_m.next_due_at),
      to_char(v_m.next_due_at, 'YYYY-MM-DD'));
  end loop;

  update public.invoices set status = 'overdue'
  where status in ('received', 'approved') and due_date < current_date;
  get diagnostics v_overdue = row_count;

  return jsonb_build_object('maintenance_due', v_due, 'invoices_overdue', v_overdue);
end;
$$;
