# Husora – Datenbank (Supabase / PostgreSQL)

Die Migrationen setzen das Husora-Datenbankschema v1.0 vollständig um:

- 32 Tabellen, alle mit UUID-Primärschlüsseln und `timestamptz`-Zeitstempeln
- Geldbeträge als `numeric(12,2)`, nie als Gleitkommazahl
- Fremdschlüssel für alle Beziehungen
- Row Level Security auf jeder Tabelle
- Storage-Buckets mit Zugriffsregeln
- Automation Engine, Partner-Ranking und Webhook-Warteschlange
- Seed-Daten und ein RLS-Test

## Inhalt

| Datei | Inhalt |
|---|---|
| `migrations/…0100_extensions_and_utilities.sql` | Erweiterungen pgcrypto und btree_gist, Schema `private`, `updated_at`-Trigger, Auftragsnummern |
| `…0200_tenancy.sql` | `users` (Profil je Auth-Benutzer), `organizations`, `organization_members`, Rollen-Helfer |
| `…0300_properties.sql` | `properties`, `property_users`, `property_features` |
| `…0400_service_partners.sql` | `service_types`, `service_partners`, `service_partner_users`, `service_partner_services`, `service_partner_areas` |
| `…0500_bookings.sql` | `booking_sources`, `bookings` (Doppelbuchungen per Exclusion Constraint ausgeschlossen) |
| `…0600_inspections.sql` | `inspection_templates`, `inspection_template_items`, `inspections`, `inspection_items` |
| `…0700_tasks_orders_repairs.sql` | `service_tasks`, `service_orders`, `maintenance`, `repairs` |
| `…0800_files_finance.sql` | `documents`, `photos`, `quotes`, `invoices` |
| `…0900_automation_communication.sql` | `automation_rules`, `automation_runs`, `notifications`, `messages`, `audit_logs`, `webhook_endpoints`, `webhook_events`, Automation Engine |
| `…1000_rls_policies.sql` | RLS und Policies für alle Tabellen, Spaltenschutz-Trigger, Rechte |
| `…1100_audit_triggers.sql` | Audit-Log für die Kerntabellen |
| `…1200_storage.sql` | Buckets und Policies auf `storage.objects` |
| `…1300_partner_matching.sql` | `match_service_partners`, `offer_service_order`, `respond_service_order` |
| `…1400_foreign_key_indexes.sql` | Indizes auf den übrigen Fremdschlüsseln (`created_by`, `updated_by` …) |
| `…1500_app_sync.sql` | `app_data` (komplette App-Daten), Übernahme von Häusern, Buchungen und Aufgaben, `ensure_my_organization` |
| `…1600_app_files.sql` | Fotos/Dokumente aus Storage in `documents`/`photos`, `my_cloud_usage` (Speicheranzeige) |
| `…1800_partner_messenger.sql` | Messenger: Gespräch je Servicepartner (`messages.service_partner_id`), Lesebestätigung, Benachrichtigung bei Partner-Nachrichten |
| `…1900_partner_service_groups.sql` | Leistungsgruppen Servicearbeiten und Sanierungen (neben Hauskontrolle); Hausfotos lesbar für Partner mit Auftrag zum Haus |
| `…2000_partner_member_fast.sql` | Schnellere Partner-Prüfung in den RLS-Regeln (gleiche Logik, gezielte Index-Abfrage statt Liste je Zeile) |
| `…2100_plans_subscriptions.sql` | Tarife FREE/PLUS/PRO/ULTIMATE (`plans`: Preise, Grenzwerte, Funktionen), `subscriptions` je Organisation (Stripe vorbereitet, Schreiben nur service_role), `my_plan()`, Server-Sperre für Partner-Portal ab PRO |
| `…2200_launch_ops.sql` | Launch: `app_feedback` (Feedback/Fehlerberichte, nur schreibbar, Rate-Limit), Benachrichtigungen bei Auftragsstatus und Rechnungen, `delete_my_account()` / `my_deletion_preview()`, `stripe_events` (Webhook-Idempotenz), Aufbewahrungsfristen per pg_cron |
| `…2300_owner_members.sql` | Mitglieder für Hausbesitzer: `my_organizations()`, `org_members()`, Benutzer-Limit je Tarif bei Einladungen |
| `…2400_order_access.sql` | Zugangsdaten je Auftrag zeitlich begrenzt freigeben (`order_access_shares`, `order_access()` mit Abrufprotokoll) |
| `…2500_usage_limits.sql` | Monatszähler (`usage_counters`, `consume_usage()`), Häuser-/Dokumentgrenze serverseitig |
| `…2600_property_archive.sql` | Häuser archivieren (`status = archived`, `set_property_archived()`), archivierte zählen nicht ins Limit |
| `…2700_agreements_batch_invoices.sql` | Jahresverträge (`service_agreements`, `propose/respond/end_service_agreement()`), automatische Zuordnung passender Aufträge, Sammelrechnungen (`invoice_orders`), keine Einzelrechnung für Vertragsaufträge |
| `…2800_invoice_number_guard.sql` | Doppelte automatische Rechnungsnummer → nächste freie Nummer; doppelte eigene Nummer → verständliche Meldung |
| `…1700_partner_portal.sql` | Zugang für Servicepartner: Partner-Organisationen, Einladungen, Mitarbeiterrollen, Kunden, Kontrollvorlagen, 14 Servicearten |
| `husora_komplett.sql` | alle Migrationen in einer Datei für den SQL Editor |
| `seed.sql` | Testdaten |
| `tests/rls_test.sql` | 84 automatische Prüfungen der Rechte je Rolle |
| `tests/partner_portal_test.sql` | 53 Prüfungen (inkl. Messenger) für den Partnerzugang (Einladung, Techniker, Abschottung fremder Firmen) |

### Architektur-Entscheidungen

- **Mandantentrennung doppelt abgesichert:**
  - Jede Kindtabelle verweist mit einem zusammengesetzten Fremdschlüssel `(organization_id, …_id)` auf ihr Elternobjekt. Ein Datensatz kann also nie auf ein Haus, einen Partner oder eine Buchung einer anderen Organisation zeigen, auch nicht per service_role.
  - Zusätzlich filtert RLS jede Abfrage auf die Organisationen des Benutzers.
- **RLS-Helfer im Schema `private`:**
  - Die Helfer sind `security definer`-Funktionen wie `private.is_org_staff(org)` oder `private.can_read_property(id)`.
  - Das Schema wird nicht über die API veröffentlicht.
  - So werden Policies nicht rekursiv und bleiben kurz.
- **Spaltenschutz per Trigger:**
  - Reinigungskräfte und Partner dürfen ihre Aufgabe bzw. ihren Auftrag bearbeiten, aber nur Status, Notiz, Termin und Ist-Kosten.
  - Preise, Titel, Zuordnung und Freigaben bleiben der Verwaltung vorbehalten.
- **Keine Secrets in Tabellen:**
  - Zugangsdaten von Buchungskanälen und Webhook-Secrets stehen nur als Verweis `vault:<name>` in der Datenbank. Die Secrets selbst liegen in Supabase Vault.
  - Ein CHECK-Constraint erzwingt das Format.
- **Skalierung:**
  - Indizes auf allen Fremdschlüsseln, Status- und Datumsfeldern.
  - Zusammengesetzte Indizes laut Schema, z. B. `bookings(property_id, check_in)` und `service_orders(service_partner_id, status)`.
  - Teilindizes für offene Vorgänge.
  - BRIN-Index für das wachsende Audit-Log.
  - Die Struktur trägt mehrere Organisationen, tausende Häuser und Millionen Aufträge ohne Umbau.

### Rollen

| Rolle (`organization_members.role`) | Sieht | Darf |
|---|---|---|
| `admin` | alle Daten der eigenen Organisation | alles, inkl. Mitglieder, Buchungsquellen, Webhooks |
| `property_manager`, `service_manager` | alle Daten der eigenen Organisation | operative Verwaltung (Häuser, Aufgaben, Aufträge, Partner, Kontrollen, Finanzen) |
| `viewer` | alle Daten der eigenen Organisation | nur lesen |
| `owner` (Eigentümer) | nur eigene Häuser (`properties.owner_user_id` bzw. `property_users`) mit Buchungen, Kontrollen, Aufgaben, Aufträgen, Reparaturen, Angeboten, Rechnungen und Dateien | Hausdaten pflegen, Aufgaben, Kontrollen, Reparaturen und Eigennutzung anlegen, Angebote freigeben |
| `service_partner` | nur Aufträge, Aufgaben und Kontrollen des eigenen Betriebs (`service_partner_users`) und die betroffenen Häuser; keine Gästedaten | Aufträge annehmen, ablehnen, terminieren und abschließen; Kontrollen durchführen; Angebote und Rechnungen einreichen; eigenes Profil, Leistungen und Gebiete pflegen |
| `cleaner` | nur eigene Aufgaben (`service_tasks.assigned_user_id`) und das Haus dazu; keine Gästedaten | Aufgabe starten und abschließen, Fotos hochladen |
| Super-Admin (`users.is_super_admin`) | alle Organisationen (interne Husora-Verwaltung) | alles; setzbar nur per service_role |

## Husora-Projekt in Supabase

| | |
|---|---|
| Projekt | „husora26's Project“, Ref `ggsoygxmcsmrsrbmplrz`, Region eu-west-2 (London), PostgreSQL 17 |
| API-URL | `https://ggsoygxmcsmrsrbmplrz.supabase.co` |
| Stand | alle 16 Migrationen eingespielt, ohne Testdaten |

Die App ist mit diesem Projekt vorkonfiguriert. Hinterlegt ist nur der öffentliche Publishable Key, den Schutz übernimmt RLS.

### Cloud-Speicher in der App

Unter **Einstellungen → Daten & App → Cloud-Speicher (Supabase)** gehen Sie so vor:

1. **Neues Konto erstellen** bzw. **Anmelden**. Beim ersten Anmelden legt `ensure_my_organization()` eine eigene Organisation an und macht Sie zu deren Admin.
2. **Alles hochladen**:
   - Alle App-Bereiche (`stugliv-…`) landen 1:1 in `public.app_data`.
   - Fotos und PDFs kommen als echte Dateien in Supabase Storage:
     - Fotos nach `husora-property-photos/organization/{org}/property/{haus}/photos/…`
     - PDFs nach `husora-documents/…/documents/…`
   - In der Datenbank stehen dann nur noch Verweise.
   - Ferienhäuser, Buchungen, Aufgaben, Dokumente und Hausfotos erscheinen zusätzlich in den Fachtabellen. Sie sind dort über `app_ref` zugeordnet.
3. **Automatisch synchronisieren** lädt jede Änderung nach wenigen Sekunden hoch. Wurde auf einem anderen Gerät etwas geändert, pausiert der Upload, bis die Cloud-Daten geladen sind.
4. **Aus der Cloud laden** holt alle Daten samt Dateien auf ein anderes Gerät.

Die Karte zeigt außerdem den belegten und freien Speicher:
- auf dem Gerät
- in der Datenbank (Free-Plan 500 MB)
- in Storage (Free-Plan 1 GB)

Die Grenzen lassen sich über `organizations.settings -> 'storage_limits'` anpassen, z. B. `{"database_mb": 8192, "files_mb": 102400}` für den Pro-Plan.

**Einmalig im Dashboard einstellen:** Unter **Authentication → URL Configuration** die Site URL `https://husora26.github.io/markdown/` eintragen und unter „Redirect URLs“ ebenfalls hinzufügen. Dann führen die Bestätigungslinks in den Registrierungs-Mails direkt zur App.

### Partner-Portal (Zugang für Servicepartner)

Servicepartner nutzen dieselbe App. Beim ersten Start wählt man „Servicepartner“, oder man öffnet das Portal unter Einstellungen → Daten & App. Die Wahl legt nur den Einstieg fest, beide Rollen sind jederzeit möglich.

**Datenmodell:** Ein Servicebetrieb ist eine eigene Organisation (`org_type = 'service_partner'`) mit Firmendaten: Rechtsform, USt-IdNr., Bank, Einsatzradius, Öffnungszeiten, Notfallnummer. Verbunden wird so:

1. Der Hausbesitzer legt den Partner an (`service_partners`) und erzeugt mit `create_service_partner_invite()` einen Code `HUS-XXXX-XXXX`.
2. Der Partner gibt den Code im Portal ein (`accept_service_partner_invite()`). Dabei wird `service_partners.partner_organization_id` gesetzt und automatisch ein Kunde (`customers`) angelegt.
3. Ab dann gelten die bestehenden Regeln: Der Partner sieht genau die Aufträge, die der Hausbesitzer ihm sendet, sowie die betroffenen Häuser. Gästebuchungen bleiben verborgen.

Es gibt keine doppelten Daten: Aufträge, Kontrollen, Fotos, Rechnungen und Nachrichten liegen einmal in der Organisation des Hausbesitzers.

**Rollen im Servicebetrieb:**

| Rolle | Darf |
|---|---|
| `admin` | alles, inkl. Firma und Mitarbeiter |
| `dispatcher` / `service_manager` | alle Aufträge, Mitarbeiter einteilen, eigene Kunden pflegen |
| `accounting` | Aufträge lesen, Angebote und Rechnungen |
| `technician` / `inspector` | **nur zugewiesene** Aufträge (`service_orders.assigned_user_id`) und Kontrollen: starten, Fotos, Checkliste, abschließen; keine Preise, keine Rechnungen |
| `viewer` | nur lesen |

Mitarbeiter lädt der Admin mit `create_member_invite()` ein (Code `TEAM-XXXX-XXXX`). Der Code gilt nur für die eingeladene E-Mail-Adresse.

**Kontrollen:** `partner_start_inspection()` legt beim Kunden eine Kontrolle mit einer Vorlage des Partners an. Fünf Vorlagen entstehen beim Onboarding: Standard, Ferienhaus, Übergabe, Winter und Technik. Mängel werden beim Abschluss automatisch zu Reparaturen beim Kunden. Der Prüfbericht liegt als PDF in `husora-documents/…/inspections/`.

**Eigene Kunden:** Partner können zusätzlich Kunden ohne Husora führen (`customers`, `properties.owner_customer_id`). Aufträge dafür laufen über den eigenen Partner-Datensatz des Betriebs.

### Partner-Portal für Hausbesitzer (Menü → Servicepartner → Partner-Portal)

- **Partner & Codes:**
  - Servicepartner anlegen, auch direkt aus den in der App zugeordneten Partnern.
  - Einladungscode `HUS-XXXX-XXXX` erzeugen und per Kopieren, Teilen, E-Mail oder SMS weitergeben.
  - Der Status zeigt an, ob der Partner nicht eingeladen ist, die Einladung offen ist oder er verbunden ist.
- **Messenger:**
  - Je verbundenem Partner ein durchgehendes Gespräch, dazu die Gespräche zu einzelnen Aufträgen.
  - Ungelesen-Zähler im Menü und im Reiter, „gelesen“-Anzeige, neue Nachrichten erscheinen automatisch (alle 12 s).
  - Der Partner antwortet in seinem Portal unter „Nachrichten → Kunden“.
- **Aufträge:**
  - Offene Aufgaben an einen verbundenen Partner senden.
  - Status und Antworten der Partner einsehen.

Sichtbar sind die Gespräche nur für die Verwaltung des Hausbesitzers und die Leitung des Partnerbetriebs, nicht für Techniker oder fremde Firmen.

**Bewusst noch nicht umgesetzt** (Spezifikation, spätere Phasen):
- interne vs. kundensichtbare Nachrichten und Dateianhänge im Messenger
- Rechnungspositionen und Zahlungen
- Arbeitszeiten und Material
- wiederkehrende Termine
- Push-Mitteilungen
- vollständiger Offline-Modus mit Upload-Warteschlange (das Portal zeigt offline nur den zuletzt geladenen Stand)
- KI-Assistent

---

## 1. Datenbankinstallation

Voraussetzungen:

- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) ab Version 2
- Docker (für die lokale Umgebung)
- `psql` (PostgreSQL-Client) für den RLS-Test

```bash
# macOS
brew install supabase/tap/supabase
# Windows
scoop bucket add supabase https://github.com/supabase/scoop-bucket.git && scoop install supabase
# Linux / npm
npm install --save-dev supabase

git clone https://github.com/husora26/markdown.git
cd markdown
supabase --version
```

Die Migrationen benötigen **PostgreSQL 15 oder neuer**, weil sie `unique nulls not distinct` und `on delete set null (spalte)` verwenden. Neue Supabase-Projekte erfüllen das.

## 2. Supabase-Konfiguration

**Lokal:** `supabase/config.toml` ist fertig konfiguriert:

- API, Studio und Storage aktiv
- Seed eingeschaltet
- Schema `private` nicht veröffentlicht

**Cloud-Projekt:**

1. Auf [supabase.com](https://supabase.com/dashboard) ein Projekt anlegen. Die Region sollte in der EU liegen, z. B. Frankfurt oder Stockholm.
2. Das Projekt mit dem Repository verbinden:
   ```bash
   supabase login
   supabase link --project-ref <PROJECT_REF>
   ```
3. Unter **Authentication → URL Configuration** die App-Adresse als Site-URL eintragen, z. B. `https://husora26.github.io/markdown/`.
4. Unter **Database → Extensions** sicherstellen, dass `pgcrypto`, `btree_gist` und `supabase_vault` aktiv sind. Die Migration aktiviert pgcrypto und btree_gist selbst.
5. Secrets für Buchungskanäle und Webhooks in **Vault** anlegen. Die Namen müssen zu den Verweisen in `booking_sources.credentials_reference` bzw. `webhook_endpoints.secret_reference` passen:
   ```sql
   select vault.create_secret('<geheimer-wert>', 'webhook_airbnb_secret');
   ```
6. Optional `pg_cron` aktivieren und die zeitgesteuerte Automation einplanen:
   ```sql
   select cron.schedule('husora-automation', '7 * * * *', 'select public.run_scheduled_automations()');
   ```
   Die Funktion markiert fällige Wartung, startet die Regeln `maintenance_due` und setzt überfällige Rechnungen auf `overdue`.

## 3. Environment Variables

In der App bzw. in Edge Functions:

| Variable | Wo | Inhalt |
|---|---|---|
| `SUPABASE_URL` | App + Edge Functions | `http://127.0.0.1:54321` lokal, sonst `https://<PROJECT_REF>.supabase.co` |
| `SUPABASE_ANON_KEY` | App (öffentlich) | Anon-/Publishable-Key. Unbedenklich, weil RLS jeden Zugriff prüft. |
| `SUPABASE_SERVICE_ROLE_KEY` | **nur** Server/Edge Functions | Umgeht RLS. Niemals in die App, ins Repository oder in den Browser. |
| `SUPABASE_DB_URL` | CI, RLS-Test | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` lokal |

Die lokalen Werte zeigt `supabase status` an. Vorlage für eine `.env`, die nicht eingecheckt wird:

```bash
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=<aus supabase status>
SUPABASE_SERVICE_ROLE_KEY=<aus supabase status – nur Server>
SUPABASE_DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
```

## 4. Migration ausführen

Lokal:

```bash
supabase start      # startet Postgres, Auth, Storage, Studio (Docker)
supabase db reset   # baut die DB neu: alle Migrationen + seed.sql
```

Im Cloud-Projekt:

```bash
supabase db push    # spielt neue Migrationen ein (ohne Seed)
```

Neue Änderungen kommen immer als neue Datei hinzu, bestehende Migrationen werden nicht nachträglich geändert:

```bash
supabase migration new <name>
```

## 5. Seed-Daten laden

`supabase db reset` lädt `supabase/seed.sql` automatisch. Manuell:

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
```

Die Seed-Daten enthalten:

- **Testorganisation:** „Husora Testorganisation“ (SE, SEK) und eine zweite, fremde Organisation für den Isolationstest
- **Zwei Ferienhäuser:**
  - Stuga Björkbacken (Sunne, Eigentümer Erik)
  - Stuga Solbacken (Mora)
  - jeweils mit Ausstattung
- **Drei Servicepartner,** jeweils mit Leistungen, Preisen und Einsatzgebieten:
  - Nortivo Service AB
  - Solrosen Städ
  - Mora Bygg & VVS AB
- **Neun Servicearten:** Reinigung, Garten, Schnee, Kontrolle, Elektrik, Sanitär, Heizung, Dach, Hausmeister
- **Kontrollvorlage** „Abwesenheitskontrolle Standard“ mit 12 Kontrollpunkten
- **Buchungen:** Airbnb, Booking.com, direkt, Eigennutzung und ein abgeschlossener Aufenthalt
- **Sechs Automationsregeln.** Beim Laden erzeugen sie automatisch:
  - Endreinigungen inklusive Angebot an den bestplatzierten Partner
  - Kontrollen nach jeder Abreise
  - aus dem Mangel „Dachrinne“ eine Reparatur
- **Beispielaufgaben,** u. a. eine Aufgabe für die Reinigungskraft
- **Serviceaufträge:** Heizungswartung (angenommen) und Dachrinne (angeboten)
- **Weitere Daten:** Angebot, Rechnung, Dokumente, Foto, Wartungsplan, Benachrichtigungen, Nachrichten

Testkonten, Passwort jeweils `Husora!2026`. **Nur lokal verwenden.**

| E-Mail | Rolle |
|---|---|
| admin@husora.test | Admin |
| eigentuemer@husora.test | Eigentümer (Stuga Björkbacken) |
| partner@husora.test | Servicepartner (Nortivo) |
| reinigung@husora.test | Reinigungskraft |
| betrachter@husora.test | Nur lesen |
| fremd@husora.test | Admin der fremden Organisation |
| support@husora.test | Husora-Super-Admin |

## 6. RLS testen

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
```

So funktioniert der Test:

- Er meldet sich nacheinander als jede Testrolle an. Dafür setzt er dasselbe JWT, das auch PostgREST setzt.
- Er prüft unter anderem:
  - Die fremde Organisation sieht keinerlei Husora-Daten: keine Häuser, Buchungen, Partner, Aufträge, Dokumente, Dateien oder Audit-Logs.
  - Der Eigentümer sieht nur sein Haus.
  - Partner und Reinigungskraft sehen nur ihre Aufträge bzw. Aufgaben und keine Gästedaten.
  - Niemand kann sich selbst Rechte geben.
  - Doppelbuchungen werden abgelehnt.
  - Querverweise auf fremde Organisationen scheitern am Fremdschlüssel.
  - Storage-Pfade sind geschützt.
  - Webhooks sind idempotent und werden wiederholt.
- Der Test läuft in einer Transaktion und wird zurückgerollt. Die Daten bleiben unverändert.
- Jede Prüfung meldet `OK – …`. Beim ersten Fehler bricht der Test mit `RLS-TEST FEHLGESCHLAGEN` ab.

Manuell im SQL-Editor bzw. in `psql` als bestimmter Benutzer:

```sql
begin;
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-0000-4000-8000-000000000002", "role": "authenticated"}', true);
set local role authenticated;
select name from properties;   -- → nur „Stuga Björkbacken“
rollback;
```

Zusätzlich lohnt der Supabase Security Advisor: im Dashboard **Advisors → Security**, lokal mit `supabase db lint`.

## 7. Lokale Entwicklung starten

```bash
supabase start            # Datenbank, API, Auth, Storage
supabase status           # URLs und Keys anzeigen
python3 -m http.server 8080   # App unter http://localhost:8080
```

| Dienst | Adresse |
|---|---|
| API | http://127.0.0.1:54321 |
| Datenbank | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |
| Studio | http://127.0.0.1:54323 |
| E-Mails (Inbucket) | http://127.0.0.1:54324 |

Typische Abläufe aus der App (supabase-js):

```js
// Partner-Ranking für eine Aufgabe
const { data } = await supabase.rpc('match_service_partners', {
  p_property_id: propertyId, p_service_type_id: cleaningTypeId, p_limit: 3 });

// Aufgabe dem besten Partner anbieten
const { data: orderId } = await supabase.rpc('offer_service_order', { p_service_task_id: taskId });

// Partner nimmt an / lehnt ab (bei Ablehnung bietet die Automation den nächsten Partner an)
await supabase.rpc('respond_service_order', { p_service_order_id: orderId, p_accept: true });

// Foto hochladen – Pfad nach Konvention
await supabase.storage.from('husora-property-photos')
  .upload(`organization/${orgId}/property/${propertyId}/inspections/${file.name}`, file);
```

### Storage

Es gibt vier Buckets:

| Bucket | Öffentlich | Inhalt |
|---|---|---|
| `husora-public` | ja | z. B. Bilder für Inserate; nur die Verwaltung darf schreiben |
| `husora-private` | nein | allgemeine private Dateien |
| `husora-documents` | nein | Verträge, Rechnungen, Protokolle (PDF, Office) |
| `husora-property-photos` | nein | Fotos von Haus, Kontrollen und Reparaturen |

Für die Pfade gelten folgende Regeln:

- Sie folgen dem Muster `organization/{organization_id}/property/{property_id}/{photos|documents|inspections|repairs}/…`.
- Dokumente ohne Hausbezug liegen unter `organization/{organization_id}/documents/…`.
- Die Policies prüfen Organisation, Haus und Rolle direkt aus dem Pfad.
- `documents` und `photos` erzwingen dieselbe Konvention per CHECK.
- Private Dateien werden über signierte URLs ausgeliefert (`createSignedUrl`), nie öffentlich.

### Webhooks

Für die Endpunkte `/api/webhooks/{channel-manager|booking|payment|service-order|partner}` ist eine Edge Function vorgesehen. Sie arbeitet so:

1. Sie prüft die Signatur mit `webhook_verify_signature(endpoint_id, body, signature)`. Das ist ein HMAC-SHA256; das Secret liegt in Vault. **(authentifiziert)**
2. Sie speichert das Ereignis mit `webhook_receive(...)`. Eine erneute Zustellung derselben `event_id` wird als Duplikat erkannt. **(idempotent, protokolliert)**
3. Ein Worker holt Ereignisse mit `webhook_claim(10)` ab. Das ist parallel sicher dank `for update skip locked`.
4. Nach der Verarbeitung meldet der Worker `webhook_complete(id, ok, fehler)`. Fehlgeschlagene Ereignisse werden mit exponentiellem Backoff erneut versucht. Admins können sie mit `webhook_retry(id)` manuell neu anstoßen. **(wiederholbar)**
5. Buchungen aus Kanälen übernimmt `upsert_external_booking(...)` idempotent über `(organization_id, source, external_booking_id)`.

Alle Webhook-Funktionen außer `webhook_retry` sind nur mit service_role ausführbar.

### Automatisierung

Regeln in `automation_rules` reagieren auf diese Auslöser:

- `booking_created`, `booking_checkout`, `booking_cancelled`
- `inspection_completed`, `inspection_item_defect`
- `service_order_rejected`
- `maintenance_due`

Mögliche Aktionen:

- `create_cleaning_task`, `create_task`
- `create_inspection`
- `create_repair`
- `notify`
- `cancel_booking_tasks`
- `offer_next_partner`

Für jede Regel gilt:

- Jede Ausführung wird in `automation_runs` protokolliert.
- Eine Regel läuft je Auslöser und Objekt höchstens einmal.
- Fehler einer Regel blockieren weder die anderen Regeln noch den auslösenden Vorgang.

### Partner-Ranking

```
score = distance_score + availability_score + rating_score + price_score
```

Die Gewichte stellt jede Organisation in `organizations.settings` ein:

```json
{"partner_ranking": {"distance": 40, "availability": 20, "rating": 25, "price": 15,
                     "max_distance_km": 100, "max_open_orders": 10}}
```

Die vier Teilwerte entstehen so:

- **Entfernung:** Haversine aus den Koordinaten von Haus und Partner.
- **Einsatzgebiet:** Berücksichtigt werden nur Partner, deren Gebiet das Haus abdeckt (PLZ, Ort, Region oder Radius).
- **Verfügbarkeit:** Zahl der offenen Aufträge, dazu Terminkonflikte am Wunschtag.
- **Bewertung:** Wert von 0 bis 5.
- **Preis:** im Verhältnis zum günstigsten Anbieter.

## Tarife freischalten

Bis die Stripe-Zahlung angebunden ist, wird ein Tarif im SQL Editor (service_role) gesetzt:

```sql
insert into public.subscriptions (organization_id, plan_id, status, note)
values ('<organization_id>', 'pro', 'active', 'manuell freigeschaltet')
on conflict (organization_id) do update set plan_id = excluded.plan_id, status = excluded.status, note = excluded.note;
```

Preise und Umfang ändert man in `public.plans` (`price_monthly_cents`, `limits`, `features`, `highlights`) – die App liest sie beim Start. Ohne Eintrag in `subscriptions` gilt FREE; ein Downgrade löscht keine Daten.

## Stripe einrichten (Online-Bezahlung der Tarife)

Der Code liegt bereit in `supabase/functions/stripe-checkout` (Checkout + Kundenportal) und `supabase/functions/stripe-webhook` (Abo-Abgleich). So wird er aktiviert:

1. Im Stripe-Dashboard je Tarif ein Produkt mit monatlichem Preis anlegen (PLUS 7,90 €, PRO 17,90 €, ULTIMATE 34,90 €) und die Preis-IDs eintragen:
   ```sql
   update public.plans set stripe_price_id = 'price_…' where id = 'plus';   -- ebenso pro, ultimate
   ```
2. Secrets setzen und Funktionen veröffentlichen:
   ```bash
   supabase secrets set STRIPE_SECRET_KEY=sk_test_… STRIPE_WEBHOOK_SECRET=whsec_…
   supabase functions deploy stripe-checkout
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
3. In Stripe einen Webhook auf `https://<projekt>.supabase.co/functions/v1/stripe-webhook` mit den Ereignissen `checkout.session.completed`, `customer.subscription.created/updated/deleted`, `invoice.payment_failed` anlegen.
4. Kundenportal in Stripe aktivieren (Kündigen, Tarif wechseln, Zahlungsmittel).

Sobald eine `stripe_price_id` gesetzt ist, zeigt die App statt der E-Mail-Anfrage den Stripe-Checkout; „Abo verwalten“ öffnet das Kundenportal. Erst im Testmodus prüfen, dann auf Live-Schlüssel umstellen.

## Feedback und Fehlerberichte lesen

`public.app_feedback` ist aus der App nur beschreibbar. Auswerten im SQL Editor:
```sql
select created_at, kind, message, page, app_version, contact_email from public.app_feedback order by created_at desc limit 100;
```
