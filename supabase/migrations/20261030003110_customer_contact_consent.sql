-- =============================================================================
-- HUSORA · Kontaktdaten des Hausbesitzers an den Servicepartner
-- =============================================================================
-- * Bei der Verbindung erhält der Partner Name und E-Mail aus dem Benutzerkonto des Hausbesitzers.
-- * Telefonnummer und Adresse nur nach ausdrücklicher Freigabe (Rückfrage in der App).
-- * Die Freigabe gilt je Partner und kann jederzeit zurückgenommen werden (Daten werden beim Partner gelöscht).
-- Idempotent.

alter table public.service_partners
  add column if not exists share_phone        boolean not null default false,
  add column if not exists share_address      boolean not null default false,
  add column if not exists contact_decided_at timestamptz;
comment on column public.service_partners.share_phone is 'Hausbesitzer hat seine Telefonnummer für diesen Partner freigegeben';
comment on column public.service_partners.share_address is 'Hausbesitzer hat seine Adresse für diesen Partner freigegeben';
comment on column public.service_partners.contact_decided_at is 'Zeitpunkt der Entscheidung über die Kontaktfreigabe (null = Rückfrage offen)';

-- Freigabe darf nur die Verwaltung des Hausbesitzers ändern, nicht der Partner
create or replace function private.service_partners_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_system_context() and not private.is_org_staff(old.organization_id) then
    new.organization_id := old.organization_id;
    new.status := old.status;
    new.rating := old.rating;
    new.notes := old.notes;
    new.share_phone := old.share_phone;
    new.share_address := old.share_address;
    new.contact_decided_at := old.contact_decided_at;
  end if;
  return new;
end;
$$;

-- Verbindung annehmen: Kunde mit Name und E-Mail aus dem Benutzerkonto, ohne Telefon und Adresse
create or replace function public.accept_service_partner_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := private.current_user_id();
  v_invite   public.service_partner_invites;
  v_partner_org uuid;
  v_home     public.organizations;
  v_inviter  public.users;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id into v_partner_org
  from public.organization_members m join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both') and m.role in ('admin', 'dispatcher', 'service_manager')
  order by (m.role = 'admin') desc limit 1;
  if v_partner_org is null then
    raise exception 'Bitte zuerst deinen Servicebetrieb anlegen' using errcode = '42501';
  end if;

  select * into v_invite from public.service_partner_invites i where i.code = upper(trim(p_code)) for update;
  if v_invite.id is null or v_invite.expires_at < now() then
    raise exception 'Der Einladungscode ist ungültig oder abgelaufen' using errcode = 'P0002';
  end if;
  if v_invite.accepted_at is not null then
    raise exception 'Dieser Einladungscode wurde bereits verwendet' using errcode = '23505';
  end if;
  if v_invite.organization_id = v_partner_org then
    raise exception 'Das ist eine Einladung deiner eigenen Organisation' using errcode = '22023';
  end if;
  if exists (select 1 from public.service_partners sp where sp.organization_id = v_invite.organization_id and sp.partner_organization_id = v_partner_org) then
    raise exception 'Du bist mit diesem Kunden bereits verbunden' using errcode = '23505';
  end if;

  update public.service_partners sp set partner_organization_id = v_partner_org where sp.id = v_invite.service_partner_id;
  update public.service_partner_invites set accepted_at = now(), accepted_organization_id = v_partner_org where id = v_invite.id;

  select * into v_home from public.organizations o where o.id = v_invite.organization_id;
  select * into v_inviter from public.users u where u.id = v_invite.created_by;
  -- Nur Name und E-Mail aus dem Benutzerkonto; Telefon und Adresse erst nach Freigabe (share_contact_with_partner)
  insert into public.customers (organization_id, linked_organization_id, company_name, first_name, last_name, email, country)
  values (v_partner_org, v_home.id, v_home.name, v_inviter.first_name, v_inviter.last_name,
          coalesce(v_inviter.email, v_home.email), v_home.country)
  on conflict (organization_id, linked_organization_id) where linked_organization_id is not null do nothing;

  return jsonb_build_object('organization_id', v_home.id, 'organization_name', v_home.name, 'service_partner_id', v_invite.service_partner_id);
end;
$$;

-- Hausbesitzer entscheidet über die Freigabe; Name und E-Mail werden dabei aus dem Konto aktualisiert.
-- p_contact: {first_name, last_name, phone, street, postal_code, city, country} aus dem Benutzerprofil der App.
-- Die E-Mail kommt immer aus dem angemeldeten Konto (nicht vom Gerät).
create or replace function public.share_contact_with_partner(
  p_service_partner_id uuid,
  p_share_phone boolean,
  p_share_address boolean,
  p_contact jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sp      public.service_partners;
  v_me      public.users;
  v_first   text;
  v_last    text;
  v_phone   text;
  v_street  text;
  v_zip     text;
  v_city    text;
  v_country text;
  v_rows    integer;
begin
  select * into v_sp from public.service_partners sp where sp.id = p_service_partner_id;
  if v_sp.id is null or not private.is_org_staff(v_sp.organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_sp.partner_organization_id is null then
    raise exception 'Der Servicepartner ist noch nicht verbunden' using errcode = '22023';
  end if;
  select * into v_me from public.users u where u.id = private.current_user_id();

  v_first   := left(nullif(trim(coalesce(p_contact ->> 'first_name', v_me.first_name, '')), ''), 80);
  v_last    := left(nullif(trim(coalesce(p_contact ->> 'last_name', v_me.last_name, '')), ''), 80);
  v_phone   := case when p_share_phone then left(nullif(trim(coalesce(p_contact ->> 'phone', v_me.phone, '')), ''), 40) end;
  v_street  := case when p_share_address then left(nullif(trim(p_contact ->> 'street'), ''), 160) end;
  v_zip     := case when p_share_address then left(nullif(trim(p_contact ->> 'postal_code'), ''), 20) end;
  v_city    := case when p_share_address then left(nullif(trim(p_contact ->> 'city'), ''), 80) end;
  v_country := case when p_share_address then
                 case when upper(trim(coalesce(p_contact ->> 'country', ''))) ~ '^[A-Z]{2}$' then upper(trim(p_contact ->> 'country'))
                      else private.app_country(p_contact ->> 'country') end end;

  update public.service_partners sp
  set share_phone = coalesce(p_share_phone, false),
      share_address = coalesce(p_share_address, false),
      contact_decided_at = now()
  where sp.id = v_sp.id;

  update public.customers c
  set first_name = coalesce(v_first, c.first_name),
      last_name = coalesce(v_last, c.last_name),
      email = coalesce(v_me.email, c.email),
      phone = v_phone,
      street = v_street,
      postal_code = v_zip,
      city = v_city,
      country = coalesce(v_country, case when p_share_address then c.country end, c.country)
  where c.organization_id = v_sp.partner_organization_id and c.linked_organization_id = v_sp.organization_id;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    insert into public.customers (organization_id, linked_organization_id, company_name, first_name, last_name, email, phone, street, postal_code, city, country)
    select v_sp.partner_organization_id, o.id, o.name, v_first, v_last, coalesce(v_me.email, o.email), v_phone, v_street, v_zip, v_city, coalesce(v_country, o.country)
    from public.organizations o where o.id = v_sp.organization_id;
  end if;

  return jsonb_build_object('share_phone', coalesce(p_share_phone, false), 'share_address', coalesce(p_share_address, false),
                            'phone_shared', v_phone is not null, 'address_shared', v_street is not null or v_city is not null);
end;
$$;
revoke all on function public.share_contact_with_partner(uuid, boolean, boolean, jsonb) from public, anon;
grant execute on function public.share_contact_with_partner(uuid, boolean, boolean, jsonb) to authenticated;
