# HUSORA – Compliance Implementation Report

Stand: 02.11.2026 · Grundlage: „Husora Legal & Beta Compliance Specification“ v1.0 und „Husora Beta Mode“.
**Wichtig (§42):** Alles unten ist *technisch umgesetzt – juristische Prüfung offen*. Rechtstexte sind *Entwurf – finale juristische Prüfung offen*. Nichts in diesem Bericht bestätigt, dass Husora „DSGVO-konform“ ist.

---

## 1. ARCHITEKTUR (Analyse vor der Umsetzung)

| Bereich | Bestand |
|---|---|
| Frontend | Eine Web-App `index.html` (Vanilla JS, kein Build), GitHub Pages |
| Backend | Supabase: Postgres + RLS, Auth, Storage, Edge Functions (`stripe-checkout`, `stripe-webhook`, `notify-dispatch`, `ai-assist`) |
| Auth | Supabase Auth (E-Mail/Passwort), `public.users` mit Schutz-Trigger; neu: TOTP-MFA für Admins |
| Mandanten | `organizations` (homeowner/service_partner/both) + `organization_members.role`; „tenant_id“ = `organization_id` |
| Rollen | Org-Rollen (admin, property_manager, service_manager, dispatcher, technician, accounting, viewer, contractor …); neu: Admin-Rollen `super_admin`, `support_admin`, `content_admin`, `security_admin` |
| Hausbesitzer-Daten | local-first im Browser, optional Husora Cloud (`app_data` + Projektion in Fachtabellen) |
| Rechtstexte (vorher) | Impressum, Datenschutz, AGB, Partnerhinweis, Lizenzen – fest im Code |
| Analytics (vorher) | Beta-Analytics (Migration 3700), Opt-out |
| Externe APIs | OSM-Kacheln, Nominatim, Google Maps, Open-Meteo, Wechselkurse, Google Übersetzer/MyMemory, Inseratsimport über Weiterleitungsdienste, CDNs, Repull, Stripe, (Anthropic, Resend, Web-Push vorbereitet) |
| PDF/Dokumente | eigene PDF-Erzeugung (Prüfbericht, Rechnung), pdf.js, Tesseract (lokal) |
| Servicepartner, Kontrollen, Reparaturen, Bewertungen, Zahlungen | siehe Phasen 2–12 (`ARCHITECTURE_AUDIT.md`) |

**Plan** (danach umgesetzt): Migration 4400 → Rechtliches-Hub + Einwilligung → Hinweise/Bestätigungen in den Abläufen → Admin-Bereich mit MFA → Security-Testmatrix → Compliance-Test → Bericht.

## 2. DATENBANK (Migration `20261030004400_legal_compliance.sql`)

Neu: `legal_documents`, `legal_acceptances`, `consent_log`, `review_reports`, `privacy_requests`, `security_incidents`, `security_audit_log`, `retention_rules`, `third_party_providers`, `processing_activities`, `ai_register`.
Erweitert: `users.admin_roles`; `organizations.verification_status/_note/verified_at/verification_expires_at`; `service_partner_reviews.moderation_status/moderated_at/moderated_by`; `app_config`-Schlüssel `security`, `imprint`, `payments`, `release_gate`.
RPCs: `my_admin_status`, `my_pending_legal`, `log_client_security_event`, `set_partner_verification`, `admin_partner_list`, `report_review`, `moderate_review`, `export_my_data`, `release_gate`, `provider_flags`, `partner_directory_facts` (+ Nachweisstatus).
Geändert: `track_events` (nur mit Einwilligung), `track_server_event` (ohne Einwilligung nur anonymer Zähler), `delete_my_account` (Audit), `beta_dashboard` (Rollen + MFA), `cleanup_retention` (liest `retention_rules`), `protect_user_columns` (Admin-Rollen nur durch Super-Admin).

## 3. RLS

- Alle Tabellen in `public` haben RLS (automatisch geprüft in `security_test.sql` und im Release-Gate).
- Admin-Zugriff über `private.has_admin_role(rolle)`: Rolle **und** zweiter Faktor (`aal2`), solange `app_config.security.require_admin_mfa = true` (Standard).
- Least Privilege: Support sieht Feedback, Bewertungen (Beta) und Datenschutz-Anfragen, **keine** Häuser/Dokumente der Mandanten; Sicherheit sieht Audit-Log und Vorfälle; Inhalte pflegt Impressum, Rechtstexte, Moderation, Nachweise; nur Super-Admin ändert Konfiguration, Anbieterstatus, Aufbewahrung, Release-Gate.
- Nutzer sehen nur eigene Einwilligungen, Zustimmungen, Anfragen; Zustimmung nur zu veröffentlichten Fassungen.
- Organisation/Nutzer werden serverseitig aus der Sitzung abgeleitet (nie allein aus Client-Feldern).
- TRUNCATE/TRIGGER/REFERENCES für Client-Rollen entzogen (4100, 4400).

## 4. STORAGE

Alle Buckets außer `husora-public` privat, mit Größenlimit und Dateityp-Allowlist (`husora-private` in 4400 nachgezogen: 25 MB, PDF/Bilder/Office/Text). Zugriff nur authentifiziert über Storage-RLS, keine öffentlichen URLs für private Dateien. Dokumentabrufe im Partner-Portal werden protokolliert (`document_access`), Löschungen per Trigger (`document_delete`).

## 5. AUTH

Supabase Auth (Passwort-Hash, Rate-Limits und Brute-Force-Schutz der Plattform). TOTP-MFA aktiviert (`config.toml`; gehostet: Dashboard → Auth → MFA) und für Admin-Funktionen erzwungen; Einrichtung/Abfrage in der App. Konto löschen verlangt Passwort, zeigt Folgen, löscht `auth.users` → alle Sitzungen ungültig.

## 6. RECHTLICHE SEITEN

Einstellungen → **Rechtliches**: Impressum, Datenschutzerklärung, Nutzungsbedingungen, Beta-Bedingungen, Servicepartner-Regeln, Haftungs- & Prüfhinweise, Bewertungsregeln, KI-Transparenz, Datenschutz-Einstellungen, Datenexport, Datenschutz-Anfrage, Konto löschen, Versionen.
- Impressum aus `app_config.imprint`, im Admin editierbar; leere Felder als Platzhalter (keine erfundenen Angaben).
- Datenschutzerklärung um Verarbeitungsübersicht und Anbieter-Tabelle (Anbieter, Zweck, Daten, Rechtsgrundlage, Ort, Speicherdauer, Rolle, Drittland, Garantien) ergänzt.
- Nutzungsbedingungen: Husora als Plattform, Servicepartner als eigenständige Anbieter (Vertragspartner, Preis, Leistung, Haftung, Rechnung, keine Provision).
- Versionierung in `legal_documents`; zustimmungspflichtige Fassungen (Nutzungs- und Beta-Bedingungen) werden nach dem Login kontrolliert abgefragt.

## 7. DRITTANBIETER

`third_party_providers` (15 Einträge) und `processing_activities` (12) als interne Register. **Kein Anbieter ist „approved“** – Status `under_review` bzw. `unknown`, AVV-Status `unknown`. Externe Inhalte (Karten, Adresssuche, Wetter, Wechselkurse, Übersetzung, Import, Google-Karte) laden erst nach Einwilligung „Externe Inhalte“; gesperrte Anbieter (`blocked`) lädt die App gar nicht.

## 8. KI

`ai_register` (Anbieter, Modell, Zweck, Ein-/Ausgabe, Speicherung, Training, Ort, AVV, Transparenz). KI-Karten tragen „KI-Vorschlag“ und „Du nutzt hier ein KI-System“; KI ist standardmäßig deaktiviert. Maschinelle Übersetzung wird als solche benannt und nur nach Einwilligung genutzt.

## 9. ANALYTICS

Nur mit Einwilligung (Consent-Log, serverseitig in `track_events` erzwungen; Widerruf wirkt sofort). Ohne Einwilligung zählt der Server Prozessschritte nur anonym (ohne Nutzer/Objekt). Metadaten nur aus einer Allowlist; keine Inhalte, Tokens, Notizen, Zugangscodes. Lesen nur Super-Admin.

## 10. LÖSCHUNG

`delete_my_account` löscht Konto, Mitgliedschaften, Organisationen ohne weitere Mitglieder (inkl. Häuser, Dateien), Analytics, Einwilligungen, Bewertungen, Benachrichtigungen; Aufträge/Rechnungen bei anderen Betrieben bleiben ohne Kontobezug (Nachweispflicht – juristisch zu prüfen). `retention_rules` trennt gesetzliche Aufbewahrung (`legal_hold`, z. B. Rechnungen 10 Jahre – zu prüfen) von Produktdaten; wöchentliche Bereinigung.

## 11. EXPORT

`export_my_data()` (läuft mit den Rechten des Nutzers) + lokale Gerätedaten als JSON-Download: Profil, Mitgliedschaften, Organisationen, Häuser, Räume/Merkmale, Aufgaben, Kontrollen, Mängel, Serviceaufträge, eigene Nachrichten, Bewertungen, Feedback, Einstellungen, Einwilligungen, Zustimmungen, Anfragen, Cloud-App-Daten. Nur eigene Organisationen. Fotos/Dokumente als Verweise (ZIP optional, nicht umgesetzt). Export wird protokolliert.

## 12. AUDIT

`security_audit_log`: `user_login`, `permission_change`, `document_access`, `document_delete`, `access_grant`, `access_revoke`, `admin_action`, `account_delete`, `data_export`, `service_assignment` – ohne Inhalte. Zusätzlich bestehendes `audit_logs` (Datenänderungen). Lesen nur `security_admin`.

## 13. SECURITY

MFA für Admins, serverseitige Autorisierung (RLS + Sicherheits-Definer mit festem `search_path`), Rate-Limits (Feedback, Analytics, Bewertungen, KI, Audit-Client), Upload-Grenzen (Größe, MIME), keine RLS-Umgehung über TRUNCATE, Datenpannen-Prozess (`security_incidents`, Meldepflicht nur „zu bewerten/ja/nein“ durch Menschen).
Produkt: Hauskontroll-Hinweis (App, Partner-Portal, Prüfbericht-PDF), Kennzeichnung sensibler Bereiche („Dokumentation – keine Fachprüfung“), kostenpflichtige Schritte mit Bestätigung („Kostenpflichtig beauftragen“, „Angebot kostenpflichtig annehmen“, „Mehrkosten kostenpflichtig freigeben“, „Notdienst kostenpflichtig anfordern“ mit Auftragnehmer, Leistung, Preis/Preislogik, Termin, Kostenhinweis), Anfragen an Partner als unverbindlich gekennzeichnet, Partner-Nachweisstatus („nicht geprüft“ … „verifiziert“ nur mit dokumentierter Prüfung), Bewertungen melden/moderieren, Notfall & Zugang nur per befristeter, widerrufbarer, protokollierter Freigabe, Zahlungen während der Beta in App **und** Edge Function gesperrt, Immobilienimport mit Quellen-/Rechtehinweis und Bestätigung.

## 14. TESTERGEBNIS

| Test | Ergebnis |
|---|---|
| Frische Datenbank (alle 46 Migrationen + Seed) | PASS |
| SQL gesamt | **398 Prüfungen, 0 Fehler** (15 Dateien) |
| Testmatrix §39 (`compliance_matrix_test.sql`, owner_A/B, partner_A/B, admin_A, support_A) | **PASS – 48/48**: Tenant-Isolation (lesen/ändern/löschen/anlegen), Partner-Isolation (fremdes Haus, nicht freigegebenes Haus, fremde Dokumente, fremde Zugangsdaten), Widerruf, Admin-Rollen + MFA, Einwilligung/Widerruf, Rechtstexte, Datenschutz-Anfragen, Export, Moderation, Konto-Löschung, Storage |
| `security_test.sql` / `compliance_test.sql` | PASS 8/8 · PASS 8/8 |
| E2E `legal` (Einwilligung, Rechtliches, Texte, Beta ohne Zahlung, neue Fassung, Consent-Log, Export, Anfrage, Admin mit TOTP, Release-Gate, Impressum, Register) | PASS 13/13 |
| E2E Gesamtsuite | siehe GO/NO-GO-Bericht |

## 15. OFFENE PUNKTE

1. Juristische Prüfung aller Rechtstexte, Rechtsgrundlagen (insb. Analytics/Einwilligung, Fehlerberichte), Haftung, AGB-Konzept, Vermittlungsmodell.
2. AV-Verträge/Transfermechanismen prüfen und im Register auf `signed`/`approved` setzen (Supabase-Region!).
3. Impressum vollständig ausfüllen (Rechtsform, Register, USt-ID, Vertretungsberechtigte).
4. Immobilienimport: Nutzungsbedingungen der Portale prüfen; Weiterleitungsdienste ersetzen oder Import einschränken.
5. Datenschutz-Folgenabschätzung (Art. 35) prüfen – insbesondere Zugangsdaten, KI, Partnerzugriff.
6. ZIP-Export inkl. Dateien, Screenshot-Anhang bei Fehlerberichten, Admin-UI für Rollenvergabe (derzeit SQL).
7. Migrationen 3600–4400 auf dem Live-Projekt einspielen; MFA im Supabase-Dashboard aktivieren.

## 16. RISIKEN

- **Kritisch, live offen:** TRUNCATE-Lücke (4100) bis zum Einspielen der Migrationen.
- Analytics-Rechtsgrundlage: technisch Einwilligung – falls juristisch anders bewertet, Texte und Consent anpassen.
- Datenübermittlung in Drittländer (Supabase, GitHub, Google, Anthropic, Resend) ungeprüft.
- Zugangsdaten im local-first-Speicher des Hausbesitzers liegen unverschlüsselt im Browser und in `app_data` (nur Organisationsmitglieder) – Verschlüsselung erwägen.
- Inseratsimport: urheberrechtliche Risiken bei Fotos/Texten.
- Automatisiertes „PASS“ ersetzt keine menschliche Freigabe (§43).
