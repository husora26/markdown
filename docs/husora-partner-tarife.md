# Tarife für Servicepartner (Free / Plus / Pro / Ultra)

Umsetzung der „Husora Service Partner App – Tarif- und Berechtigungsspezifikation“ v1.0.

**Verbindlich:** Es gibt keine Vermittlungsprovision. Husora verdient bei Servicepartnern nur über
Abos und Zusatzmodule. Ein SQL-Test prüft, dass es keine Provisionsspalte oder -funktion gibt.

## Produktentscheidungen (Alex, 18. und 22.11.2026)

- Gesperrte Funktionen bleiben im Partner-Portal **sichtbar** und sind gekennzeichnet (Schloss + „ab Plus/Pro“).
  Ein Tipp öffnet eine kurze Erklärung mit dem passenden Tarif. (Hausbesitzer-App: ausblenden.)
- Das Auftragslimit zählt nur **selbst angelegte** Aufträge, je **Kalendermonat** (Europe/Stockholm).
  Aufträge, die Hausbesitzer schicken, zählen nicht und werden nie blockiert.
- Ist das Kundenlimit voll, wird auch das Annehmen einer Hausbesitzer-Einladung abgelehnt (mit Upgrade-Hinweis).
- Ein Betrieb, der auch Hausbesitzer ist, hat zwei getrennte Abos (Hausbesitzer-Tarif und Partner-Tarif).

## Datenmodell (Migration `20261122000100_partner_plans.sql`)

| Tabelle | Zweck |
|---|---|
| `partner_plans` | Tarife: Preis, `limits` (jsonb), `features` (jsonb-Array), Texte, Stripe-Preis |
| `partner_addon_catalog` | Zusatzmodule mit Preis und Wirkung (`effect.limits` je Menge, `effect.features`) |
| `partner_subscriptions` | Abo je Betrieb (Tenant = Organisation), Status, Periode, Kündigung |
| `partner_addons` | gebuchte Module: `requested` (Preis bestätigt) → `active` (nach Freigabe/Zahlung) → `canceled` |
| `partner_entitlements` | individuelle, befristete Freischaltungen durch Husora-Admins |
| `partner_subscription_events` | Protokoll aller Abo-/Modul-Änderungen (keine Zahlungsdaten) |
| `usage_counters` (vorhanden) | neuer Zähler `partner_orders_month` |

Eigene Tabellen statt `plans`/`subscriptions`: installierte Hausbesitzer-Apps lesen `plans` komplett
und würden Partner-Tarife sonst auf ihrer Tarifseite zeigen.

Limit-Schlüssel: `customers`, `properties`, `orders_month`, `users`, `storage_bytes`, `locations`
(`null` = unbegrenzt). Startwerte laut Spezifikation, änderbar im Adminbereich.

## Zentrale Funktionen

- `private.partner_entitlements(org)` / RPC `partner_entitlements(p_organization_id)` = *getTenantEntitlements*:
  Tarif, Status, Periode, Funktionen, effektive Limits, Nutzung, Restkapazität, Module, Freischaltungen.
- RPC `check_partner_limit(org, key, amount)` = *checkTenantLimit* (Vorabprüfung für die App).
- `private.partner_enforce_limit(org, key, amount)`: Advisory-Lock je Betrieb und Ressource, dann Prüfung.
  Parallele Anlagen warten aufeinander, das Limit kann nicht überschritten werden.
- Trigger vor dem Anlegen: Kunden, Objekte (reiner Partner: alle; Doppelrolle: nur Objekte von Kunden),
  eigene Aufträge, aktive Mitglieder, Dokumente (Speicher). `create_member_invite` zählt offene Einladungen mit.
- `partner_plan_change_preview(org, plan)`: was beim Wechsel über dem Limit läge (nichts wird gelöscht).
- `request_partner_addon(org, code, bestätigter_preis)` / `cancel_partner_addon`.
- `admin_partner_plan_overview()` für den Adminbereich.

**Prioritätsregel:** aktive individuelle Freischaltung > Tarif + aktive Zusatzmodule.

**Tarif-Auflösung:** `trialing`/`active` bis Periodenende; `past_due` mit 3 Tagen Kulanz; `canceled`
bis Periodenende (bezahlte Rechte bleiben), danach Free; `incomplete` (Zahlung nicht bestätigt) = Free.

**Cache/Aktualisierung:** keiner in der Datenbank. Jede Prüfung rechnet live, Admin-Änderungen wirken sofort.
Die App lädt die Rechte beim Öffnen des Portals, beim Aktualisieren und nach jeder Anlage.

**Fehlermeldung bei Limit:** z. B. „Du hast dein Kundenlimit von 20 Kunden im Plus-Tarif erreicht.
Wechsle zu Pro, um bis zu 100 Kunden zu verwalten.“ (`errcode P0001`, `hint husora_plan_limit`,
`detail` = JSON mit used/limit/upgrade). Die App zeigt dazu „Tarife ansehen“.

## Startschalter

`app_config.partner_plans = {"enforce": false}` – ausgeliefert **aus**. Dann zeigt die App Tarif und
Nutzung, sperrt aber nichts. Einschalten: Adminbereich → Partner-Tarife → „Limits und Funktionssperren aktiv“
(Super-Admin mit zweitem Faktor) oder per SQL. Grund: Beta-Betriebe sollen nicht plötzlich gesperrt
werden, solange Tarifwechsel noch nicht online bezahlt werden können.

## Oberfläche

- Partner-Portal → Mehr → **Mein Tarif**: Tarif, Status, Preis, nächste Abrechnung/Kündigungsdatum,
  Nutzungsbalken (ab 80 % gelb, bei 100 % rot und gesperrt), Tarifvergleich mit Upgrade/Wechsel inkl.
  Vorschau, Zusatzmodule mit Preisbestätigung, Rechnungen/Zahlungsart/Kündigung über das Stripe-Kundenportal.
- Während der Beta (Zahlungen aus) geht ein Wechsel per E-Mail-Anfrage an das Husora-Team.
- Gesperrte Bereiche (konfigurierbar über `features`): Kalender (`calendar`), Mängel (`repairs`),
  Angebote & Rechnungen (`quotes_basic`), Jahresverträge (`recurring_basic`), Mitarbeiter (`employee_management`).
- Adminbereich → **Partner-Tarife**: Startschalter, Preise/Limits/aktiv je Tarif, Zusatzmodule, je Betrieb
  Tarif manuell setzen, Module freigeben, individuelle Freischaltungen.

## Zahlung (Stripe)

`stripe-checkout` mit `{"audience":"partner", "plan_id":"partner_pro", …}` bzw. `{"audience":"partner","portal":true}`.
`stripe-webhook` erkennt Partner-Abos an `metadata.audience = partner` und schreibt in `partner_subscriptions`.
Benötigt (wie bisher): `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`; Preise in `partner_plans.stripe_price_id`
(je Tarif in Stripe anlegen und eintragen). Zahlungen bleiben aus, bis `app_config.payments.enabled = true`.

## Tests

- `supabase/tests/partner_plans_test.sql`: Akzeptanztests 1–5 und 7–17.
- `tests/e2e/partnerplans.js`: Akzeptanztest 6 (8 parallele API-Anlagen, genau 3 kommen durch) und Oberfläche.

## Deployment

1. Migration `20261122000100_partner_plans.sql` einspielen (idempotent).
2. Edge Functions `stripe-checkout` und `stripe-webhook` neu deployen (erst wenn Stripe genutzt wird).
3. Startschalter einschalten, wenn die Limits gelten sollen.

## Offen

- Speicher zählt nur Dokumente im eigenen Betrieb; Fotos und Uploads zu Aufträgen von Hausbesitzern liegen bei diesen.
- Mehrere Standorte (`locations`) und Subunternehmer sind nur als Funktion/Limit hinterlegt; es gibt noch keine Standortverwaltung.
- Funktionssperren wirken in der Oberfläche; serverseitig durchgesetzt sind die Limits (nicht jede einzelne Funktion).
- Offene Produktfragen der Spezifikation (§12): Einführungspreise, Jahresabos, Preis weiterer Ultra-Benutzer,
  Speicherwerte, Free dauerhaft, Zahlungsanbieter.
