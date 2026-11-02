# Husora – Architektur-Audit Servicepartner

Abgleich: **„Husora Servicepartner – Claude Implementation Specification v1.0“** gegen den Bestand
Stand: 02.11.2026 · Repository `husora26/markdown` (Commit `adee994`) · Supabase-Projekt `ggsoygxmcsmrsrbmplrz` (live geprüft)

> Phase 1 der Spezifikation (§50). Bei dieser Analyse wurde **kein Code und keine Datenbank geändert**.

---

## 1. Kurzfazit

| Bereich | Einschätzung |
|---|---|
| Grundgerüst (Mandanten, RLS, Rollen, Aufträge, Kontrollen, Angebote, Rechnungen, Dokumente, Benachrichtigungen, Audit-Log) | **weitgehend vorhanden**: 45 Tabellen, RLS auf allen, SQL-RLS-Tests, 30 Playwright-Suiten |
| Priorität 1 (17 Punkte) | 10 vorhanden, 7 teilweise, 0 fehlen |
| Priorität 2 (11 Punkte) | 4 vorhanden, 4 teilweise, 3 fehlen (Zeit, Material, Fahrt) |
| Priorität 3 (9 Punkte) | 0 vorhanden, 4 teilweise, 5 fehlen |
| Größte Lücken | Status-Engine und Ereignisprotokoll je Auftrag · explizite Objektfreigabe (`property_service_assignments`) · Freigabesystem mit Auto-Limit · Arbeitszeit, Material und Fahrt · Mängel des Hausbesitzers liegen nur im Gerät bzw. im `app_data`-Blob (Regel 5) |
| Größte Abweichung von der Spezifikation | Die App ist **eine Datei mit Vanilla-JS** (`index.html`, ca. 20 500 Zeilen), nicht React/TypeScript. Die Spezifikation verbietet eine neue, getrennte App (§0, Regel 2). Der Plan baut deshalb auf dem Bestand auf. |

**Empfehlung:** Die Tabellennamen der Spezifikation werden **nicht** neu angelegt. Bestehende Tabellen werden erweitert, wie es Regel 13/14 verlangt (Zuordnung in Abschnitt 4). Neu entstehen nur die Tabellen, für die es heute wirklich nichts gibt.

---

## 2. Ist-Architektur (Bestandsaufnahme nach §50)

### 2.1 Framework, Routing, Komponenten
- **Framework:** keines. Eine Datei `index.html` mit Template-Literals, ohne Build und ohne TypeScript. Zusätzlich `sw.js` (Offline-Cache), `assets/`, `tools/`.
- **Routing:**
  - Hausbesitzer: `currentPage` + `render()`, Seiten-Gates `PAGE_GATES`.
  - Partnerportal: Zustand `pp` mit `pp.view`, dazu `ppRender()` / `ppLoad()` / `ppRun()`, Start über `?partner`.
  - Kein URL-Router; der Zurück-Knopf läuft über eine eigene History-Logik.
- **„Komponenten“:** Render-Funktionen, z. B.:
  - `ppOrderRow`, `ppTilesHtml`, `ppDefectsHtml`, `ppDocumentsHtml`, `ppAgreementsHtml`, `ppSettingsHtml`
  - `hubAgreementsHtml`, `portfolioPage`, `taskArchiveHtml`
- **Service-Layer:**
  - `cloudFetch` (REST/Storage) und die Partner-Helfer `ppQ`, `ppInsert`, `ppPatch`
  - RPCs: `propose_/respond_/update_/delete_service_agreement`, `my_organizations`, `my_plan`, Projektionsfunktionen
- **Mehrsprachigkeit:** Wörterbuch `I18N_SOURCE` (DE/EN/SV) mit MutationObserver. Vollständig übersetzt ist das Partnerportal, auf der Hausbesitzer-Seite nur ein Teil.
- **Qualitätssicherung:**
  - 30 Playwright-Suiten (`tests/e2e`, `run.sh`)
  - SQL-Tests `supabase/tests/rls_test.sql` und `partner_portal_test.sql`
  - CI `.github/workflows/tests.yml`
  - Es gibt **kein** Lint, keinen Typecheck und keine Unit-Tests.

### 2.2 Supabase-Client und Auth
- Nur der Anon-/Publishable-Key liegt im Client; ein Service-Key ist nicht im Frontend (Regel 8 ✔).
- Sitzungsverwaltung: `cloudSetSession`, `tokenSub`. Die Organisation ist an das Konto gebunden (Fehler beim Kontowechsel behoben).
- `organization_id` vom Frontend wird serverseitig nicht blind übernommen. Trigger und RLS prüfen über `private.is_org_staff`, `can_read_org`, `is_partner_member`, `is_partner_employee`, `can_work_order`.
- Entitlements: Im Client steuert `entitlements.can()` nur die Anzeige. Maßgeblich sind serverseitig `org_plan`, `subscriptions` und der Trigger `require_service_portal`.

### 2.3 Datenbank (live)
45 Tabellen in `public`, **alle mit RLS** (`stripe_events` ohne Policy, also nur über `service_role` erreichbar). Statuswerte werden über `CHECK`-Constraints geprüft, nicht über Enums.

| Gruppe | Tabellen |
|---|---|
| Mandanten / Benutzer | `organizations` (org_type `homeowner`/`service_partner`/`both`), `organization_members`, `organization_invites`, `users` (`is_super_admin`), `property_users` |
| Objekte | `properties`, `property_features`, `bookings`, `booking_sources`, `customers` |
| Servicepartner | `service_partners` (Verknüpfung Kunde↔Partner-Org, dazu ein „Self“-Datensatz je Partner-Org), `service_partner_services`, `service_partner_areas`, `service_partner_invites`, `service_partner_users` (Altbestand, im Client ungenutzt), `service_types`, `service_agreements` |
| Arbeit | `service_tasks`, `service_orders`, `order_access_shares`, `inspections`, `inspection_items`, `inspection_templates`, `inspection_template_items`, `repairs`, `maintenance` |
| Finanzen | `quotes`, `invoices`, `invoice_orders` |
| Dateien | `photos`, `documents`, `document_archive` |
| Kommunikation | `notifications`, `messages` |
| Automatisierung / Integration | `automation_rules`, `automation_runs`, `webhook_endpoints`, `webhook_events` |
| System | `audit_logs`, `app_data` (JSON-Spiegel der Gerätedaten), `app_feedback`, `plans`, `subscriptions`, `usage_counters`, `stripe_events` |

**Statusmodelle heute:**
- `service_orders`: `draft, offered, accepted, rejected, scheduled, in_progress, completed, cancelled`. Partner-Übergänge prüft `private.service_orders_guard`.
- `inspection_items`: `ok, warning, defect, not_checked, not_applicable` (deckt §14 ab).
- `repairs`: `reported, approved, assigned, in_progress, completed, cancelled`; Priorität `low…urgent`.
- `quotes`: `requested, received, approved, rejected, expired`.
- `invoices`: `draft, received, approved, paid, overdue, cancelled`.
- `service_tasks`: `pending, assigned, accepted, in_progress, completed, cancelled`.

### 2.4 Migrationen
30 Dateien `supabase/migrations/20261030000100…3000_*.sql`, idempotent wo nötig. `supabase/husora_komplett.sql` ist der Gesamtauszug. Die nächste freie Nummer ist **3100**.

### 2.5 Storage
| Bucket | öffentlich | Zweck |
|---|---|---|
| `husora-public` | ja | nur unkritische Inhalte |
| `husora-private` | nein | private Dateien |
| `husora-documents` | nein | Dokumente, Rechnungs- und Angebots-PDFs |
| `husora-property-photos` | nein | Objekt- und Kontrollfotos |

Pfadkonvention per CHECK erzwungen: `organization/{org}/property/{property}/…` bzw. `organization/{org}/documents/…`, kein `..`. Das entspricht §17/§42 ✔.

### 2.6 Rollen

| Rolle laut Spezifikation | Bestand | Status |
|---|---|---|
| `homeowner` | Organisation `org_type=homeowner` + Mitglied `owner`/`admin`/`property_manager` | ✔ |
| `service_provider_owner` | Partner-Org + Rolle `owner` (bzw. Ersteller als `admin`) | ✔ |
| `service_provider_admin` | `admin`, `service_manager`, `dispatcher`, `accounting` | ✔ (feiner als die Spezifikation) |
| `service_provider_employee` | `technician`, `inspector`, `cleaner`; RLS über `assigned_user_id` und `is_partner_employee` | ✔ |
| `service_provider_contractor` | fehlt (Zugriff nur auf einzelne Aufträge) | ✖ |
| `husora_admin` | `users.is_super_admin` + `private.is_super_admin()`; keine Admin-Oberfläche | ◐ |

### 2.7 Vorhandene Servicepartner-Funktionen (markiert)
- **Registrierung und Konto:**
  - Partner-Registrierung (`?partner`), Onboarding-RPC mit Self-Datensatz, Standardleistungen und Kontrollvorlagen.
  - Firmendaten: Rechtsform, USt-ID, Bank, Radius, Geschäftszeiten, Notfalltelefon.
  - Mitarbeitende mit Namen, Telefon und Info; Einladungen mit Bearbeiten und Löschen.
  - Einladungslink für Kunden (ab PRO).
- **Startseite und Einstellungen:**
  - Kacheln, Hell/Dunkel, Schriftgröße, Sprache DE/EN/SV.
  - Daten & App, rechtliche Seiten.
- **Aufträge und Kalender:**
  - Aufträge: annehmen, ablehnen, planen, starten, abschließen; Mitarbeiterzuweisung.
  - Sammelabschluss.
  - Monatskalender.
- **Kontrollen, Mängel und Fotos:**
  - Kontrollen mit Checkliste und Vorlagen; Prüfplan-PDF.
  - Mängelübersicht aus `inspection_items`.
  - Fotos hochladen (`photos`, Bucket `husora-property-photos`).
- **Angebote, Rechnungen und Verträge:**
  - Angebote mit PDF.
  - Rechnungen mit PDF, Sammelrechnung, Nummernschutz, EUR/SEK.
  - Jahresverträge (`service_agreements`) mit mehreren Aufgaben und Laufzeit.
- **Kunden, Leistungen und Dokumente:**
  - Kunden und Objekte, Kundenkontakte bearbeiten.
  - Leistungspakete mit Ergänzungsfeld.
  - Dokumente: ansehen, PDF-Export, Archiv.
- **Kommunikation:** Nachrichten je Auftrag bzw. Partner; Benachrichtigungen in der App (Trigger).
- **Zugangsdaten:** zeitlich begrenzte Freigabe (`order_access_shares`).
- **Hausbesitzer-Seite:** Partner-Hub, Beauftragung (`ownerDispatchOrders`), Prüfplan-PDF beim Auftrag, Rechnungen verbuchen, Verträge bestätigen.

---

## 3. Grundsatzentscheidungen (Abweichungen mit Begründung)

| # | Spezifikation | Bestand | Vorschlag |
|---|---|---|---|
| G1 | React/TS-Struktur `src/features/...`, Definition of Done „TypeScript ohne Fehler, Production Build“ | Vanilla-JS in einer Datei, kein Build | **Beibehalten.** Ein Umbau wäre eine neue App und damit verboten. Ersatz für die DoD: keine Konsolenfehler (wird im E2E-Test geprüft), E2E grün, SQL-Tests grün, Dunkelmodus-Generator gelaufen. Optional später `// @ts-check` mit JSDoc für neue Helfer. |
| G2 | Tabellennamen `work_orders`, `attachments`, `service_catalog`, `service_areas`, `provider_employees` … | `service_orders`, `photos`+`documents`, `service_types`+`service_partner_services`, `service_partner_areas`, `organization_members` | **Nicht umbenennen, nicht duplizieren** (Regeln 12–14). Bei Bedarf Views mit den Spezifikationsnamen nur zur Lesbarkeit. |
| G3 | `work_orders.organization_id` + `service_provider_id` | `service_orders.organization_id` = **Hausbesitzer-Org**, `service_partner_id` → `service_partners` (Verknüpfung) → `partner_organization_id` | Entspricht dem Zielbild. Beibehalten. |
| G4 | Status `pending`, `sent` | `offered` | `offered` gilt als „sent“; Anzeige „Angefragt/Gesendet“. `pending` wird nicht gebraucht, weil der Entwurf direkt angefragt wird. Neu kommen nur `waiting_customer` und `waiting_parts`. Bestehende Werte bleiben, damit keine Daten migriert werden müssen. |
| G5 | `service_provider_profiles` als eigene Tabelle | Profil liegt auf `organizations` (Radius, Geschäftszeiten, Notfalltelefon, Beschreibung, Bank …) | `organizations` **erweitern** (`emergency_service`, `auto_accept_orders`, `requires_order_confirmation`, `minimum_order_value`, `travel_fee`, `hourly_rate`). Keine zweite Profiltabelle, sonst liegen Radius und Beschreibung doppelt. Bewertungen werden aggregiert (§34). |
| G6 | `defects` als eigene Tabelle | `repairs` (mit `inspection_id`, `inspection_item_id`, `service_order_id`, Priorität, Kosten) + `inspection_items.status='defect'` | `repairs` als Mängeltabelle **erweitern** (Schwere, Kategorie, Ort, Quelle, Kundensichtbarkeit). Ein Mangel aus einer Kontrolle erzeugt bzw. verknüpft einen `repairs`-Datensatz. |
| G7 | `provider_availability` als Tabelle | `organizations.business_hours` (jsonb, je Wochentag) | Für den ganzen Betrieb jsonb **beibehalten**. Neu nur `service_partner_absences`, und Verfügbarkeit je Mitarbeiter erst, wenn die Disposition sie braucht. |
| G8 | Regel 5: mandantenrelevante Daten nicht nur im LocalStorage | Hausbesitzer-Mängel (`stugliv-issues`), lokale Kontrollen, Kosten und Ausgaben liegen im Gerät und als JSON in `app_data`. Projiziert werden nur Objekte, Aufgaben, Buchungen, Dokumente und Fotos. | Schrittweise Projektion der Daten, die der Partner sehen muss: Mängel → `repairs`, beauftragte Kontrollen → `inspections`. Kosten bleiben vorerst privat beim Hausbesitzer; sie sind mandanten-privat, aber per `app_data` serverseitig gesichert. |

---

## 4. Gap-Matrix je Abschnitt der Spezifikation

Legende: ✔ vorhanden · ◐ teilweise · ✖ fehlt · ➜ Maßnahme

| § | Thema | Bestand | Status | ➜ Maßnahme (erweitern statt ersetzen) |
|---|---|---|---|---|
| 2 | Rollen | siehe 2.6 | ◐ | Rolle `contractor` ergänzen (Members-CHECK + RLS nur auf zugewiesene Aufträge); Super-Admin-Ansicht später |
| 3 | Multi-Tenancy | `organization_id` auf allen mandantenbezogenen Tabellen, RLS-Helfer | ✔ | Auf neuen Tabellen übernehmen |
| 4 | organizations / members | vorhanden, reicher als die Spezifikation | ✔ | — |
| 5 | Servicepartner-Profil | Felder auf `organizations` | ◐ | Spalten ergänzen (G5), UI im Firmendaten-Fenster |
| 6 | Leistungen | `service_types` (global + eigene) + `service_partner_services` (Preis von/bis, Einheit, Label, Beschreibung, Notizen) | ◐ | `price_type` (`hourly/fixed/quote/free`) ergänzen und aus `price_unit` ableiten; fehlende Standardtypen (Pool, Sauna, Dach, Notdienst …) als globale `service_types` nachtragen |
| 7 | Servicegebiet | `service_partner_areas` (PLZ, Ort, Region, Radius) am Self-Datensatz; UI nur für den Radius | ◐ | Spalten `name, country, postal_code_prefix, latitude, longitude, active`; UI für mehrere Gebiete |
| 8 | Verfügbarkeit / Abwesenheit | `business_hours` jsonb; keine Abwesenheiten | ◐/✖ | Neue Tabelle `service_partner_absences` (org, user optional, Zeitraum, Grund); Kalender blendet sie ein |
| 9 | Mitarbeiter | `organization_members` + Einladungen (Name, Telefon, Info, Rolle, Status) | ◐ | Mitarbeitende **ohne** Login vorerst nicht abbilden (Entscheidung offen, siehe Abschnitt 8) |
| 10 | Objektzuordnung | Zugriff des Partners nur über Aufträge (`can_read_service_order`) bzw. die Kundenverknüpfung `service_partners`; lokal `servicePartnerAssignments` | ✖ | Neue Tabelle `property_service_assignments` (property, service_partner [Verknüpfung], service_type, status, start/end, `access_level basic/service/full`); RLS-Helfer `private.partner_can_see_property()`; Hausbesitzer-UI „Partner für Objekt freigeben“; lokale Zuordnungen projizieren |
| 11 | Aufträge | `service_orders` | ◐ | Spalten `order_type, priority (inkl. emergency), scheduled_end, started_at, cancelled_at, estimated_minutes, actual_minutes, requires_approval, approval_status, customer_visible`; `scheduled_at` = `scheduled_start` |
| 12 | Status-Workflow | 8 Status, Übergänge im Guard | ◐ | `waiting_customer`, `waiting_parts` ergänzen; Notfallpfad über `priority='emergency'` |
| 13 | Auftragsereignisse | allgemeines `audit_logs` + Hub-Historie im Client | ✖ | Neue Tabelle `service_order_events` (= `work_order_events`), befüllt per Trigger aus dem Guard; Zeitleiste im Auftrag (Partner und Hausbesitzer) |
| 14 | Hauskontrollen | `inspections` + `inspection_items` + Vorlagen, Status passt | ✔ | Hausbesitzer-Kontrollen projizieren (G8) |
| 15 | Mängel | `repairs` + `inspection_items.defect`; Hausbesitzer-Mängel nur lokal | ◐ | G6: `repairs` erweitern; Projektion `stugliv-issues` → `repairs` |
| 16 | Foto-Dokumentation | `photos` (Bezug Objekt, Kontrolle, Position, Reparatur, Auftrag, Aufgabe) | ◐ | Spalte `photo_kind` (`before/after/defect/general`); Vorher/Nachher im Auftrag |
| 17 | Storage | Buckets und Pfad-CHECK | ✔ | — |
| 18 | Arbeitszeit | — | ✖ | Neue Tabelle `service_order_work_logs` (Auftrag, Benutzer, Start, Ende, Minuten, Notiz, abrechenbar); Start-/Stopp-Knopf im Auftrag |
| 19 | Fahrt / km | — | ✖ | Neue Tabelle `service_order_travel_logs` (km, Pauschale, Betrag) |
| 20 | Material | — | ✖ | Neue Tabelle `service_order_materials` (Bezeichnung, Menge, Einheit, Einzelpreis, Summe) |
| 21 | Angebote | `quotes` ohne Positionen | ◐ | Neue Tabelle `quote_items`; Statusanzeige `received` = „gesendet“ |
| 22 | Freigabesystem | Angebot freigeben/ablehnen über `quotes.status`; Verträge über RPC | ◐ | Neue Tabelle `approval_requests` (Typ: Angebot, Mehrkosten, Reparatur; Betrag, Status, Frist, Entscheider) + RPC `respond_approval` |
| 23 | Automatische Reparaturfreigabe | — | ✖ | `auto_approval_limit` je Objekt bzw. Org beim Hausbesitzer; Trigger genehmigt unter dem Limit und protokolliert das im Audit-Log |
| 24/25 | Rechnungen | `invoices` + `invoice_orders`, PDF, Nummernschutz, Sammel- und Vertragsrechnung | ✔ | Positionen aus Arbeitszeit, Material und Fahrt automatisch vorbelegen (nach §18–20) |
| 26 | Notfallsystem | Notfalltelefon im Profil, lokales `stugliv-emergency` | ✖ | `priority='emergency'`, Partner mit `emergency_service`, Sofort-Benachrichtigung |
| 27 | Benachrichtigungen | `notifications` in der App per Trigger | ◐ | Push (Web-Push / Service Worker) und E-Mail über eine Edge Function; Einstellungen je Benutzer |
| 28 | Chat | `messages` je Auftrag oder Partner | ◐ | **Keine** `conversations`-Tabellen anlegen (G2). `messages` reicht für Auftrags- und Partnerchat; Gruppen-Chats erst bei Bedarf |
| 29 | Kalender | Monatsansicht im Partnerportal | ◐ | Tages- und Wochenansicht, Filter Mitarbeiter/Leistung, Abwesenheiten |
| 30 | Dokumentenarchiv | `documents` + `document_archive` | ✔ | — |
| 31 | Dashboard | Kacheln mit Kennzahlen | ◐ | Ergänzen: heutige Termine, überfällig, wartet auf Freigabe, Umsatz Monat |
| 32 | Navigation | Kachel-Startseite, „Mehr“-Menü | ✔ | Neue Bereiche einhängen (Zeiten, Freigaben) |
| 34 | Bewertungen | `service_partners.rating` (Feld ohne Funktion) | ✖ | Neue Tabelle `service_partner_reviews` (nur nach abgeschlossenem Auftrag; eine je Auftrag); Durchschnitt per Trigger |
| 35 | Matching | SQL `match_service_partners`, `service_orders.match_score`; keine UI | ◐ | UI beim Beauftragen: Vorschläge nach Leistung, Gebiet, Bewertung, Verfügbarkeit |
| 36 | Automation | `automation_rules`/`_runs` (Server), lokale Automatik | ◐ | Regeln wie „Mangel → Reparaturauftrag“ und „Kontrolle fällig → Auftrag“ serverseitig |
| 37 | Wartung | `maintenance` (Server) + lokale Intervalle (3D-Modell) | ◐ | Lokale Intervalle nach `maintenance` projizieren; fällige Einträge erzeugen Aufträge |
| 38 | Frontend-Komponenten | Render-Funktionen | ✔ (anderes Paradigma) | G1 |
| 39 | Mobile-First | durchgehend mobil, Dunkelmodus, Schriftgröße | ✔ | — |
| 40 | Offline | Service Worker, Partner-Cache, `ppQueueSave`-Retry | ◐ | Offline-Warteschlange für Checkliste, Fotos und Zeiten im Partnerportal |
| 41 | RLS | auf allen Tabellen, Helfer, SQL-Tests | ✔ | Jede neue Tabelle mit Policies und Testfällen |
| 42 | Storage-Sicherheit | private Buckets, Pfad-CHECK, signierte URLs | ✔ | — |
| 43 | Audit-Log | `audit_logs` + Trigger | ✔ | Neue Tabellen anhängen |
| 44 | API-/Service-Layer | `cloudFetch`, `ppQ`, RPCs | ✔ | Statuswechsel nur über RPC `transition_service_order` |
| 45 | Validierung | CHECK-Constraints + Formularprüfung | ✔ | — |
| 46 | Status-Engine | Guard-Trigger für Partner; Hausbesitzer-Seite frei | ◐ | Zentrale Tabelle bzw. Funktion `private.order_transition_allowed(old, new, role)`; Reopen nur für Admin mit Ereignis |
| 47 | Teststrategie | E2E + SQL; keine Unit-Tests | ◐ | SQL-Tests je Phase; E2E-Szenario §63 als eigene Suite |
| 48 | Sicherheits-Checkliste | Regeln eingehalten, Advisors geprüft | ✔ | Nach jeder Phase `get_advisors` ausführen |
| 49 | UX-Fehlerzustände | Lade-, Leer- und Fehlerzustände im Portal meist vorhanden | ◐ | Für neue Ansichten Pflicht (DoD) |
| 64 | Performance / Indexe | Indexe auf FKs und Status | ✔ | Auf neuen Tabellen ebenso |

---

## 5. Die 37 Funktionspunkte (§33)

### Priorität 1
| # | Punkt | Status | Bestand → Lücke |
|---|---|---|---|
| 1 | Servicepartner-Login | ✔ | eigener Einstieg `?partner`, Konto- und Org-Bindung |
| 2 | Eigenes Dashboard | ✔ | Kacheln + Einstellungen; Kennzahlen ergänzen (§31) |
| 3 | Unternehmensprofil | ◐ | Firmendaten vorhanden; Felder aus G5 fehlen |
| 4 | Leistungen | ✔ | Pakete mit Preis und Ergänzungsfeld; `price_type` fehlt |
| 5 | Servicegebiet | ◐ | nur ein Radius; mehrere Gebiete fehlen |
| 6 | Zugeordnete Häuser | ◐ | sichtbar über Kunden und Aufträge; explizite Freigabe je Objekt fehlt (§10) |
| 7 | Auftragsliste | ✔ | Filter, Sortierung, Sammelauswahl |
| 8 | Auftragsdetails | ✔ | Objektangaben, Prüfplan-PDF, Zugangsdaten; Ereignis-Zeitleiste fehlt |
| 9 | Annehmen / ablehnen | ✔ | Guard-Trigger |
| 10 | Statusänderungen | ◐ | Wartestatus und Protokoll je Auftrag fehlen |
| 11 | Kontrolle durchführen | ✔ | `inspections` |
| 12 | Checkliste | ✔ | Vorlagen und Positionen |
| 13 | Fotos | ✔ | Upload; Vorher/Nachher fehlt |
| 14 | Mangel melden | ◐ | Partner meldet über die Position; beim Hausbesitzer nur lokal |
| 15 | Reparaturauftrag erzeugen | ◐ | `repairs.service_order_id` vorhanden; Ablauf „Mangel → Auftrag“ serverseitig fehlt |
| 16 | Benachrichtigungen | ◐ | in der App ja; Push und E-Mail nein |
| 17 | Berechtigungen / RLS | ✔ | Rolle `contractor` und Objektfreigabe fehlen |

### Priorität 2
| # | Punkt | Status | Bestand → Lücke |
|---|---|---|---|
| 18 | Arbeitszeiterfassung | ✖ | neu |
| 19 | Materialkosten | ✖ | neu |
| 20 | Kilometer / Anfahrt | ✖ | neu |
| 21 | Angebot erstellen | ◐ | Angebot mit PDF; ohne Positionen |
| 22 | Eigentümer-Freigabe | ◐ | Angebot und Vertrag ja; allgemeines Freigabesystem nein |
| 23 | Rechnung erstellen | ✔ | inkl. Sammel- und Vertragsrechnung |
| 24 | Mitarbeiterverwaltung | ✔ | ohne Login-lose Mitarbeitende |
| 25 | Kalender | ◐ | nur Monatsansicht |
| 26 | Wiederkehrende Aufträge | ◐ | Jahresverträge + lokale Wiederholaufgaben; serverseitige Erzeugung fehlt |
| 27 | Dokumentenarchiv | ✔ | — |
| 28 | Chat | ✔ | `messages` (G2) |

### Priorität 3
| # | Punkt | Status | Bestand → Lücke |
|---|---|---|---|
| 29 | Automatische Partnervermittlung | ◐ | SQL-Matching ohne UI |
| 30 | Bewertungssystem | ✖ | neu |
| 31 | Notdienst | ✖ | neu |
| 32 | Automatische Auftragserstellung | ◐ | lokale Automatik, `automation_rules` |
| 33 | Preis-/Kostenvergleich | ✖ | neu (setzt Angebotspositionen voraus) |
| 34 | KI-Auswertung von Kontrollberichten | ✖ | neu (Edge Function) |
| 35 | KI-Schadenserkennung aus Fotos | ✖ | neu |
| 36 | Automatische Kostenschätzung | ◐ | Kostenprognose (ULTIMATE) lokal; serverseitig nein |
| 37 | Automatische Wartungsplanung | ◐ | lokale Intervalle + `maintenance` |

---

## 6. End-to-End-Testfall (§63): Abdeckung heute

| Schritt | Heute | Fehlt für „voll grün“ |
|---|---|---|
| 1–2 Kontrolle erstellen → Auftrag | ✔ (`ownerDispatchOrders`) | Voraussetzung „Partner für Haus A freigegeben“ als Datensatz (§10) |
| 3 Benachrichtigung | ✔ in der App | — |
| 4 Mitarbeiter nimmt an | ✔ | — |
| 5 Kalender | ✔ | — |
| 6 Start | ✔ | `started_at` |
| 7–8 Checkliste, Foto | ✔ | — |
| 9–10 Defekt dokumentiert | ✔ (Position `defect`) | `repairs`-Datensatz automatisch |
| 11 Kosten geschätzt | ✔ (`estimated_cost` an der Position) | — |
| 12–13 Freigabe anfordern / genehmigen | ◐ | `approval_requests` |
| 14 Reparaturauftrag | ◐ | serverseitige Erzeugung |
| 15 Reparatur | ✔ | — |
| 16–17 Zeit, Material | ✖ | §18/§20 |
| 18 Nachher-Foto | ◐ | `photo_kind` |
| 19–21 Abschluss, Rechnung, Versand | ✔ | — |
| 22–23 Bezahlt | ✔ (`paid_at`) | — |
| 24 Audit-Log vollständig | ◐ | `service_order_events` + Audit auf neuen Tabellen |

---

## 7. Phasenweiser Implementierungsplan

Für **jede Phase** gilt dieselbe Arbeitsweise:
1. Schema prüfen.
2. Migration schreiben, idempotent mit `if not exists` und `create or replace`.
3. Migration lokal anwenden und SQL-Tests ausführen.
4. Oberfläche in `index.html` ergänzen; neue Texte ins Wörterbuch DE/EN/SV; Dunkelmodus-Generator laufen lassen.
5. E2E-Suite schreiben und die volle Suite ausführen.
6. Migration remote anwenden, danach `get_advisors`.
7. `husora_komplett.sql` neu erzeugen; Commit und Push nach `main`.

Bestehende Funktionen, Tabellen und Statuswerte werden **nicht entfernt**.

### Phase 1 – Bestandsaufnahme ✅ (dieses Dokument)

### Phase 2 – Auftragskern: Status-Engine + Ereignisse (Migration 3100)
- **DB:**
  - `service_orders` erweitern: `order_type`, `priority`, `scheduled_end`, `started_at`, `cancelled_at`, `estimated_minutes`, `actual_minutes`, `requires_approval`, `approval_status`, `customer_visible`. Standardwerte so wählen, dass alte Zeilen gültig bleiben.
  - Status-CHECK um `waiting_customer` und `waiting_parts` erweitern.
  - Neue Tabelle `service_order_events`.
  - Zentrale Funktion `private.order_transition_allowed()`; der bestehende Guard ruft sie auf, das Verhalten für die heutigen Übergänge bleibt gleich.
  - RPC `transition_service_order(id, status, message)`.
  - `order_type` aus dem Leistungstyp vorbelegen.
- **RLS:** Ereignisse lesen nur Beteiligte (`can_read_service_order`); schreiben nur Trigger und RPC.
- **UI:**
  - Partner: Knöpfe „Wartet auf Kunde“ und „Wartet auf Material“, Zeitleiste im Auftrag.
  - Hausbesitzer: Zeitleiste im Hub-Auftrag (ersetzt die lokale Historie nicht, ergänzt sie).
- **Tests:** SQL-Matrix erlaubter und verbotener Übergänge (u. a. `completed → in_progress` verboten); E2E `orderflow`.
- **Risiko:** Der Guard wird in 0700, 1700 und 2700 mehrfach neu definiert. Die neue Fassung muss alle bisherigen Sonderfälle übernehmen (Vertragsaufträge, Sammelabschluss, Aufgaben-Sync).

### Phase 3 – Rollen + Objektfreigabe (Migration 3200)
- **DB:**
  - Rolle `contractor` in den Members-CHECK.
  - Neue Tabelle `property_service_assignments` mit `access_level`.
  - Helfer `private.partner_can_see_property(property, level)`.
  - Bestehende Policies für `properties`, `photos`, `documents` und `inspections` **ergänzen**: zusätzliche OR-Bedingung, kein Ersatz.
- **Migration der Bestandsdaten:** für jede aktive Kunde↔Partner-Verknüpfung mit Aufträgen eine Freigabe `service` je betroffenem Objekt anlegen, damit niemand Zugriff verliert.
- **UI:**
  - Hausbesitzer: im Objekt „Servicepartner freigeben“ (Leistung, Zeitraum, Zugriffsstufe); die lokalen `servicePartnerAssignments` werden projiziert.
  - Partner: Bereich „Häuser“ zeigt freigegebene Objekte.
- **Tests:** RLS-Fälle (fremde Org sieht nichts, Contractor sieht nur seinen Auftrag, `basic` sieht keine Dokumente); E2E `assign`.

### Phase 4 – Onboarding & Profil (Migration 3300)
- **DB:**
  - `organizations` erweitern (G5).
  - `service_partner_services.price_type`.
  - `service_partner_areas` erweitern.
  - Neue Tabelle `service_partner_absences`.
  - Fehlende globale `service_types` per Upsert über `code` ergänzen.
- **UI:** Firmendaten (Notdienst, Auto-Annahme, Mindestauftragswert, Anfahrt, Stundensatz), mehrere Servicegebiete, Abwesenheiten.
- **Tests:** E2E `profile`.

### Phase 5 – Dashboard & Kalender (keine bzw. kleine Migration)
- **Dashboard:** Kennzahlen heute, überfällig, wartet auf Freigabe, Umsatz Monat; alles aus vorhandenen Daten.
- **Kalender:** Tages- und Wochenansicht, Filter Mitarbeiter/Leistung, Abwesenheiten anzeigen.
- **Tests:** Erweiterung der Suiten `home` und `partner`.

### Phase 6 – Aufträge vollständig (UI-Phase auf Basis von Phase 2/3)
- **Filter und Status:** Filter nach Status inkl. Wartestatus, Priorität und Auftragsart; Notfall-Kennzeichnung.
- **Zuweisung:** Contractor bekommt einzelne Aufträge.
- **Lade-, Leer- und Fehlerzustände** prüfen.
- **Tests:** E2E `orders2`.

### Phase 7 – Kontrolle + Mängel (Migration 3400)
- **DB:**
  - `repairs` erweitern: `severity`, `category`, `location`, `source` (`owner/partner/inspection`), `customer_visible`.
  - `photos.photo_kind`.
  - Trigger: Position mit `defect` erzeugt bzw. aktualisiert `repairs`.
  - RPC `create_repair_order(repair_id)` erzeugt den Reparaturauftrag.
- **Projektion:**
  - `project_app_issues`: lokale Hausbesitzer-Mängel → `repairs`, über `app_ref` wie bei Aufgaben.
  - Beauftragte lokale Kontrollen → `inspections`.
  - **Wichtig:** Die Projektion darf vom Partner angelegte Zeilen nicht löschen. Das Löschverhalten von `project_app_tasks` darf hier nicht übernommen werden.
- **UI:**
  - Partner: Mangel mit Schwere und Vorher-Foto; „Reparaturauftrag erstellen“.
  - Hausbesitzer: Mängel des Partners erscheinen in seiner Mängelliste.
- **Tests:** SQL (Trigger, RLS); E2E `defects`.
- **Risiko:** Doppelte Mängel durch lokale und Server-Quelle. Abgleich über `app_ref` und Herkunft.

### Phase 8 – Kosten & Freigaben (Migration 3500)
- **DB:**
  - Neue Tabellen `service_order_work_logs`, `service_order_travel_logs`, `service_order_materials`, `quote_items`, `approval_requests`.
  - `auto_approval_limit` (Objekt oder Org).
  - RPC `respond_approval`; Trigger für die Auto-Freigabe mit Audit-Eintrag.
- **UI:**
  - Partner: Zeiterfassung Start/Stopp, Material, Fahrt, Angebotspositionen; Rechnung wird daraus vorbelegt (der bestehende Rechnungsweg bleibt).
  - Hausbesitzer: Freigaben-Liste mit Genehmigen/Ablehnen und Limit-Einstellung.
- **Tests:** SQL (Summen, Freigabe nur durch den Hausbesitzer, Partner kann sich nicht selbst freigeben); E2E `costs`, `approval`.

### Phase 9 – Benachrichtigungen + Chat
- **Push:** Web-Push über den Service Worker. Für VAPID-Schlüssel und E-Mail-Versand braucht es eine Edge Function mit Secrets **im Supabase-Secret-Store**, nicht im Code.
- **Einstellungen:** pro Benutzer und Ereignistyp.
- **Chat:** auf `messages` erweitern (Anhänge über `documents`); keine neuen Tabellen.
- **Tests:** E2E `notify`.

### Phase 10 – Automatisierung & Wiederkehr (Migration 3600)
- **Serverseitige Regeln** über `automation_rules`: Kontrolle fällig → Auftrag, Mangel → Reparaturauftrag.
- **Wiederkehrende Aufträge:** aus `service_agreements` und `maintenance` per pg_cron oder Edge Function erzeugen. Die lokalen Wiederholaufgaben bleiben für Hausbesitzer ohne Partner.
- **Wartung:** lokale Intervalle → `maintenance` projizieren.
- **Tests:** SQL plus E2E `recurring`.

### Phase 11 – Matching, Bewertungen, Notdienst (Migration 3700)
- **DB:** `service_partner_reviews` mit Trigger für den Durchschnitt.
- **Matching:** UI für `match_service_partners`.
- **Notdienst:** Ablauf `priority='emergency'` (Partner mit `emergency_service` im Gebiet, Sofort-Push).
- **Kostenvergleich:** mehrere Angebote nebeneinander.
- **Tests:** E2E `match`.

### Phase 12 – KI
Edge Functions mit serverseitigem Schlüssel:
- Auswertung von Kontrollberichten
- Schadenserkennung aus Fotos
- Kostenschätzung

Die Ergebnisse sind immer als „Vorschlag“ gekennzeichnet und werden nie automatisch freigegeben. Die bestehende Rechnungs-OCR wird wiederverwendet.

### Abschluss
E2E-Suite `fullflow` mit den 24 Schritten aus §63. Volle Suite, SQL-Tests und Advisors grün.

---

## 8. Risiken & offene Entscheidungen

| # | Thema | Empfehlung | Entscheidung nötig? |
|---|---|---|---|
| E1 | Kein Umbau auf React/TS (G1) | beibehalten | Bestätigung erwünscht |
| E2 | Keine Umbenennung der Tabellen (G2), `offered` = „sent“ (G4) | beibehalten | Bestätigung erwünscht |
| E3 | Mitarbeitende ohne eigenen Login (Spezifikation `provider_employees.user_id` optional) | vorerst nicht; Contractor-Rolle deckt Fremdkräfte mit Login ab | **ja** |
| E4 | Hausbesitzer-Kosten bleiben im `app_data`-Blob statt relational | vorerst ja (privat, gesichert); relational erst bei Kostenvergleich | ja |
| E5 | Standardwährung: Spezifikation SEK, Bestand EUR bzw. Org-Währung | Org-Währung beibehalten | nein |
| R1 | Guard-Trigger wird umgebaut | Bestandsverhalten zuerst mit SQL-Tests einfrieren, dann umbauen | — |
| R2 | Neue OR-Bedingungen in RLS-Policies | nur additive Policies, Tests für fremde Org | — |
| R3 | `index.html` wird größer (ca. 20 500 Zeilen) | neue Bereiche als zusammenhängende Blöcke mit klaren Präfixen (`ppTime…`, `ppApproval…`); optional später Auslagerung in `js/*.js` ohne Build | — |
| R4 | Alte, zwischengespeicherte Clients | Service-Worker-Version anheben, neue Spalten mit Standardwerten | — |
| R5 | Altbestand `service_partner_users` (ungenutzt) | nicht löschen (Regel 2); als veraltet markieren | — |
