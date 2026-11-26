-- =============================================================================
-- HUSORA · Migration 2026-11-26 · Push-Schlüssel aus dem Vault
-- =============================================================================
-- notify-dispatch liest Geheimnis und VAPID-Schlüssel jetzt wahlweise aus dem
-- Supabase Vault statt aus Edge-Function-Secrets. So liegen alle Push-Werte an
-- einer Stelle (der Trigger private.notification_dispatch liest dort schon
-- 'notify_dispatch_url' und 'notify_dispatch_secret').
-- Vault-Namen: notify_dispatch_secret, vapid_public_key, vapid_private_key, vapid_subject
-- Nur service_role darf die Funktion aufrufen (die Edge Function), nie die App.

create or replace function public.notify_dispatch_keys()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'secret',        (select decrypted_secret from vault.decrypted_secrets where name = 'notify_dispatch_secret'),
    'vapid_public',  (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_public_key'),
    'vapid_private', (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_private_key'),
    'vapid_subject', (select decrypted_secret from vault.decrypted_secrets where name = 'vapid_subject'))
$$;
revoke all on function public.notify_dispatch_keys() from public, anon, authenticated;
grant execute on function public.notify_dispatch_keys() to service_role;

