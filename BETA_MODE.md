# Husora Beta Mode

Umsetzung des Briefs „Husora Beta Mode – Implementierungsbrief für Claude“ (02.11.2026). Migration `20261030003700_beta_mode.sql`, SQL-Test `supabase/tests/beta_mode_test.sql`, E2E `tests/e2e/beta.js`.

## 1. Bestandsaufnahme (vor der Umsetzung)

| Bereich | Bestand | Folge für den Beta Mode |
|---|---|---|
| Frontend | Eine Web-App `index.html` (Vanilla JS, Template-Literale, GitHub Pages), kein Build-Schritt, kein TypeScript | Kein `.ts`-Config-File; Beta-Modul als Funktionsblock in `index.html` |
| Backend | Supabase (Postgres, Auth, Storage, RLS), Geschäftsregeln als RPCs/Trigger | Tabellen, RLS, RPCs, Trigger in einer Migration |
| Auth | Supabase Auth; `public.users` (Profil, `is_super_admin`) mit Schutz-Trigger `protect_user_columns` | Beta-Status als Spalten an `users`, Schutz-Trigger erweitert |
| Rollen / Tenant | Organisationen (`org_type` homeowner/service_partner/both), `organization_members.role`; „tenant_id“ = `organization_id` | Namenskonvention `organization_id`; Organisation nur übernommen, wenn der Nutzer Mitglied ist |
| Admin | `users.is_super_admin` (Husora-Team), Helper `private.is_super_admin()` | Dashboard und Auswertung nur für Super-Admins |
| Hausbesitzer-Daten | **local-first**: Häuser, Aufgaben, Dokumente, Kontrollen im Browser (`localStorage`), Abgleich über `app_data` | Ereignisse werden aus erfolgreichen Speichervorgängen abgeleitet (Vorher/Nachher-Vergleich) statt an Buttons |
| Servicepartner / Aufträge | Serverseitig (`service_orders`, `inspections`, `service_partners` …) | Prozess-Ereignisse per Datenbank-Trigger (zählen nur Gespeichertes) |
| Bestehendes Feedback | `public.app_feedback` (Migration 2200): kind feedback/bug/error, nur Insert, Rate-Limit, automatische Fehlerberichte im Client | **Erweitert statt doppelt angelegt**; Views `beta_feedback` / `beta_bug_reports` mit den Namen des Briefs |
| Analytics | nicht vorhanden (nur `usage_counters` für Tariflimits, `audit_logs`) | neue Tabelle `analytics_events` |

## 2. Entscheidungen

- **Keine doppelten Tabellen:** Feedback und Fehlerberichte bleiben in `app_feedback` (neue Spalten: `user_id`, `app_role`, `feedback_type`, `title`, `expected_behavior`, `actual_behavior`, `platform`, `environment`, `severity`, `status`, `resolved_at`). Die Views `beta_feedback` und `beta_bug_reports` (`security_invoker`) zeigen sie unter den Namen des Briefs.
- **tenant_id → organization_id** (bestehende Konvention). Nutzer und Organisation setzt immer der Server aus der Sitzung; eine vom Client mitgeschickte Organisation wird verworfen, wenn der Nutzer nicht Mitglied ist.
- **Analytics nur mit Konto.** Ohne Husora-Konto werden Ereignisse lokal gepuffert (max. 300, 60 Tage) und nach der Anmeldung gesendet. Es gibt keine anonymen Analytics-Schreibrechte (kein Spam-Einfallstor).
- **Konfiguration ohne Codeänderung:** `public.app_config` (Schlüssel `beta`: `enabled`, `feedback`, `analytics`, `error_reporting`, `default_group`). Lesbar für alle, änderbar nur für Super-Admins (Schalter im Dashboard). Die App merkt sich den letzten Stand für den Offline-Betrieb.
- **Sichtbare Beta-Elemente in automatisierten Browser-Tests aus** (`navigator.webdriver`), außer der Test setzt `localStorage['husora-beta-ui'] = '1'`. So verdecken Banner und Button keine bestehenden Testklicks.

## 3. Umgesetzt

| Punkt des Briefs | Umsetzung |
|---|---|
| 1 Konfiguration | `app_config` + Client-Voreinstellung; `betaOn(flag)` |
| 2 Banner | „Husora Beta – Hilf uns, Husora gemeinsam weiterzuentwickeln.“ oben in Hausbesitzer-App und Partner-Portal, für 7 Tage ausblendbar |
| 3 Feedback | Fester, kleiner Button „Feedback“ (unten rechts, über der Navigation); Arten Idee/Problem/Funktion fehlt/Bedienung unklar/Lob/Sonstiges; automatisch Bereich, Rolle, Version, Gerät, Umgebung; Organisation/Nutzer serverseitig |
| 4 Fehler melden | Button 🐞: Fehlertyp, Schwere, Beschreibung, Erwartet, Passiert; automatische Fehlerberichte tragen jetzt ebenfalls Rolle/Plattform/Umgebung |
| 5 Tabellen | `analytics_events`, `beta_ratings`, `app_config`; `app_feedback` erweitert; Views `beta_feedback`, `beta_bug_reports` |
| 6 RLS | Eigene Meldungen/Bewertungen lesen; Analytics nur Super-Admin lesbar, Schreiben nur über `track_events()`; Status ändern nur Super-Admin (nur die Spalte `status`) |
| 7/8 Events | `trackEvent(name, payload)` mit lokaler und serverseitiger Doppelerkennung (eindeutiger Index je Nutzer/Ereignis/Objekt). Gesendet wird erst nach erfolgreichem Speichern |
| 9/10 Flows | Hausbesitzer: Onboarding → Haus → Räume → Aufgabe → Kontrolle; Partner: Firma/Leistungen/Gebiet/Profil werden im Dashboard direkt aus den Tabellen ausgewertet, Anfrage/Annahme/Abschluss per Trigger |
| 11 Rating | „Wie hilfreich war Husora?“ 1–5 Sterne + Verbesserungstext nach abgeschlossener Hauskontrolle bzw. abgeschlossenem Service (Partner und Hausbesitzer), höchstens alle 14 Tage |
| 12/13 Umfragen | 7-Tage (≥ 7 Tage seit erster Nutzung, ≥ 3 aktive Tage) und 30-Tage (≥ 30 Tage, ≥ 5 aktive Tage) inkl. Zahlungsbereitschaft; je Nutzer serverseitig nur einmal |
| 14 Premium-Interesse | „Premium-Vorschau“ unter Hilfe mit 5 Funktionen und „Premium vormerken“ → `subscription_interest` (ohne Zahlung) |
| 15–17 Dashboard | Seite „Husora Beta Dashboard“ (Hilfe → Premium-Vorschau → Button, nur Super-Admins; RPC `beta_dashboard()` prüft selbst): Kennzahlen, Funnels Hausbesitzer/Partner mit Umwandlungsraten, KPI-Ziele mit Zielmarke, Premium-Interesse, 30-Tage-Ergebnisse, Ereignisse 7 Tage, Feedback-/Fehlerliste mit Status, Beta-Schalter |
| 18 Beta-Nutzer | `users.is_beta_user`, `beta_started_at`, `beta_group` (alpha/closed_beta/open_beta/pre_launch). Wird beim ersten Tracking gesetzt (Gruppe aus der Konfiguration), Nutzer können es nicht selbst ändern |
| 19 Version | `app_version`, `platform` (z. B. `ios-app`, `android-web`), `environment` (production/staging/development aus dem Hostnamen) an Feedback, Fehlern, Bewertungen und Ereignissen |
| 20 Datenschutz | Metadaten nur aus einer Allowlist bekannter Schlüssel (count, houses, rooms, category, feature, …; Migration 4300), flach und kurz; keine Inhalte aus Dokumenten, Fotos, Notizen, Nachrichten. Schalter „Nutzungsstatistik für die Beta“ (Opt-out) unter Hilfe |

## 4. Ereignisse

| Ereignis | Quelle |
|---|---|
| `user_registered` | Trigger auf `users` |
| `session_started` | Client, einmal täglich (aktive Nutzer, Wiederkehr) |
| `onboarding_started`, `onboarding_completed` | Client (Ersteinrichtung) |
| `house_created`, `room_created`, `task_created`, `task_completed`, `document_uploaded` | Client, nach erfolgreichem Speichern (Vorher/Nachher) |
| `inspection_started`, `inspection_completed` | Client (eigene Kontrolle) und Trigger auf `inspections` (Partner) |
| `service_search` | Client (Servicepartner-Suche, einmal täglich) |
| `service_request_created`, `service_request_accepted`, `service_completed` | Trigger auf `service_orders` (nur echte Anfragen an fremde Partner) |
| `partner_invited`, `partner_connected` | Trigger auf `service_partner_invites` / `service_partners` |
| `rating_created`, `feedback_created`, `bug_report_created` | Trigger auf `beta_ratings` / `app_feedback` |
| `subscription_interest` | Client (Premium vormerken) |

Vom Client vorgetäuschte Server-Ereignisse werden verworfen (Whitelist in `track_events`). Limits: 50 Ereignisse je Aufruf, 2000 je Nutzer und Tag.

## 5. Tests

- SQL `beta_mode_test.sql`: 30 Prüfungen (Konfiguration, Whitelist, Doppelte, Metadaten-Filter, fremde Organisation, Lesen/Schreiben, Beta-Status-Schutz, Feedback/Fehler, Umfrage nur einmal, Dashboard nur Super-Admin, Abschalten).
- E2E `beta`: 13 Schritte (Banner, Feedback ohne Konto, Ereignisse aus Speichern, keine Doppelten, Fehler melden, Rating, Premium, 7-Tage-Umfrage, Sperre für normale Nutzer, Banner im Partner-Portal, Dashboard, Status ändern, Beta abschalten).

## 6. Offen

- Screenshot-Anhang bei Feedback/Fehlern (bräuchte einen privaten Storage-Bucket mit Prüfung).
- Datenschutzerklärung um Beta-Analytics ergänzen, Rechtsgrundlage/Einwilligung prüfen, Impressum prüfen **[ext]** (vor öffentlicher Beta).
- Einzelne Nutzer einer Beta-Gruppe zuordnen geht derzeit per SQL (`update users set beta_group = …`), die Gruppe für neue Beta-Nutzer im Dashboard.
- Hausbesitzer ohne Husora-Konto erscheinen erst nach der Anmeldung in der Auswertung.
