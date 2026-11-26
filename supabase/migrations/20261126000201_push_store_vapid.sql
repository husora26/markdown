-- =============================================================================
-- HUSORA · Migration 2026-11-26 · VAPID-Schlüssel beim ersten Start erzeugen
-- =============================================================================
-- Erster Start: die Edge Function erzeugt das VAPID-Schlüsselpaar selbst und legt es hier ab.
-- So sieht niemand den privaten Schlüssel. Bereits vorhandene Schlüssel werden nie überschrieben.
create or replace function public.notify_dispatch_store_vapid(p_public text, p_private text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_public !~ '^[A-Za-z0-9_-]{80,100}$' or p_private !~ '^[A-Za-z0-9_-]{40,50}$' then
    raise exception 'Ungültige VAPID-Schlüssel' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('husora-vapid'));
  if not exists (select 1 from vault.secrets where name = 'vapid_public_key') then
    perform vault.create_secret(p_public, 'vapid_public_key');
    perform vault.create_secret(p_private, 'vapid_private_key');
  end if;
  if not exists (select 1 from vault.secrets where name = 'vapid_subject') then
    perform vault.create_secret('mailto:info@husora.de', 'vapid_subject');
  end if;
  update public.app_config
     set value = coalesce(value, '{}'::jsonb) || jsonb_build_object('vapid_public_key', (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_public_key'))
   where key = 'push';
  return public.notify_dispatch_keys();
end; $$;
revoke all on function public.notify_dispatch_store_vapid(text, text) from public, anon, authenticated;
grant execute on function public.notify_dispatch_store_vapid(text, text) to service_role;
