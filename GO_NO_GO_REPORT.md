# HUSORA LEGAL & BETA COMPLIANCE – GO/NO-GO-Bericht

Stand: 02.11.2026 · Grundlagen: „Husora Legal & Beta Compliance Specification“ v1.0, „Husora Beta Mode“, Architektur-Spezifikation Phasen 8–12.
Technisch umgesetzt / juristische Prüfung offen. Rechtstexte: Entwurf – finale juristische Prüfung offen. Details: `HUSORA_COMPLIANCE_IMPLEMENTATION_REPORT.md`.

## IMPLEMENTIERT
1. Rechtliches-Hub (Einstellungen → Rechtliches): Impressum, Datenschutzerklärung, Nutzungsbedingungen, Beta-Bedingungen, Servicepartner-Regeln, Haftungs-/Prüfhinweise, Bewertungsregeln, KI-Transparenz, Datenschutz-Einstellungen, Datenexport, Datenschutz-Anfrage, Konto löschen, Versionen
2. Rechtstext-Versionierung + kontrollierte erneute Zustimmung (Nutzungs- und Beta-Bedingungen)
3. Editierbares Impressum (Admin, keine erfundenen Angaben, Platzhalter)
4. Datenschutzerklärung passend zur Architektur inkl. Anbieter-Tabelle (Zweck, Daten, Rechtsgrundlage, Ort, Speicherdauer, Rolle, Drittland, Garantien)
5. Einwilligung (notwendig / Statistik / externe Inhalte / Marketing), Widerruf so einfach wie Zustimmung, Consent-Log; Analytics serverseitig nur mit Einwilligung; externe Inhalte erst nach Einwilligung
6. Admin-Rollen (super/support/content/security) mit Least Privilege + **MFA-Pflicht (TOTP)**
7. Husora Admin: Release-Gate, Impressum, Bewertungsmoderation, Partner-Nachweise, Datenschutz-Anfragen, Datenpannen, Audit-Log, Drittanbieter-Register
8. Konto löschen mit Passwort-Bestätigung, Folgenanzeige, Sitzungsende, Löschung/Pseudonymisierung
9. Datenexport (Gerät + Cloud, nur eigene Organisationen)
10. Zentrale Aufbewahrungsregeln (gesetzlich vs. Produktdaten), Bereinigung danach
11. Register: Drittanbieter (15), Verarbeitungstätigkeiten (12), KI-Systeme (2)
12. Sicherheits-Audit-Log (Login, Rechte, Dokumentzugriff/-löschung, Freigaben, Admin-Aktionen, Löschung, Export, Zuordnungen)
13. Hauskontroll-Hinweis (App, Partner-Portal, Prüfbericht-PDF) + Kennzeichnung sensibler Bereiche
14. Eindeutige kostenpflichtige Bestätigungen (Reparatur, Angebot, Mehrkosten, Notdienst); Anfragen als unverbindlich gekennzeichnet
15. Husora als Plattform (Nutzungsbedingungen, Partner-Regeln); Partner-Nachweisstatus „nicht geprüft … verifiziert“ nur mit dokumentierter Prüfung
16. Bewertungen melden, moderieren, Missbrauch markieren; ausgeblendete zählen nicht
17. Notfall & Zugang: nie öffentlich, nur befristete, widerrufbare, protokollierte Freigabe je Auftrag
18. KI-Kennzeichnung („Du nutzt hier ein KI-System“), maschinelle Übersetzung gekennzeichnet
19. Immobilienimport: Quellen-/Rechtehinweis + Bestätigung, nur nach Einwilligung externe Inhalte
20. Beta ohne Zahlungen (App + Edge Function), Premium nur als Vorschau/„Interesse vormerken“
21. Beta Release Gate (automatisch + manuell) – Open Beta serverseitig erst nach bestandenem Gate
22. Storage: private Buckets mit Größen- und Typbegrenzung (auch `husora-private`)

## NICHT IMPLEMENTIERT
1. ZIP-Export inklusive Fotos/Dokumente (Export enthält Verweise)
2. Admin-Oberfläche zur Vergabe von Admin-Rollen (derzeit per SQL durch Super-Admin)
3. Marketing-Einwilligung (kein Marketing vorhanden – bewusst deaktiviert)
4. Screenshot-Anhang bei Fehlerberichten

## JURISTISCHE PRÜFUNG OFFEN
1. Alle Rechtstexte (Impressum-Pflichtangaben, Datenschutzerklärung, Nutzungs-/Beta-Bedingungen, Haftung, Partner-Regeln, Bewertungsregeln)
2. Rechtsgrundlagen: Analytics (derzeit Einwilligung), Fehlerberichte (berechtigtes Interesse), externe Inhalte (Einwilligung)
3. Vermittlungsmodell (Vertragspartner, Haftung, Provision) und Verbraucherinformationen vor echtem Verkauf
4. Aufbewahrungsfristen (u. a. Rechnungen 10 Jahre, Auftragsnachweise, Consent-Log)
5. Datenschutz-Folgenabschätzung (Zugangsdaten, KI, Partnerzugriff)
6. Immobilienimport (Nutzungsbedingungen der Portale, Urheberrecht an Texten/Fotos)
7. KI-Verordnung Art. 50 – Umfang der Kennzeichnungspflicht

## SECURITY RISIKEN
1. **Live-Datenbank:** TRUNCATE-Lücke (alle Mandantendaten löschbar) besteht bis zum Einspielen der Migrationen 4100/4400 – höchste Priorität
2. MFA muss im gehosteten Supabase-Projekt aktiv sein; ohne Einspielen gilt dort noch die alte Super-Admin-Regel ohne MFA
3. Zugangsdaten liegen im Browser/`app_data` unverschlüsselt (nur Organisationsmitglieder) – Verschlüsselung erwägen
4. Edge Functions (`notify-dispatch`, `ai-assist`) nicht deployt, lokal nicht typgeprüft (kein Deno)

## DATENSCHUTZ RISIKEN
1. Drittlandübermittlungen (Supabase-Region, GitHub Pages, Google, Anthropic, Resend) ungeprüft; keine AVV im Register als unterschrieben markiert
2. CDN-Bibliotheken übertragen IP-Adressen ohne Einwilligung (als notwendig eingestuft – prüfen bzw. selbst hosten)
3. Inseratsimport über Weiterleitungsdienste unbekannter Anbieter
4. Hosting der App auf GitHub Pages (USA) – EU-Hosting für Produktion erwägen

## DRITTANBIETER
Supabase · GitHub Pages · Stripe (Beta: aus) · Resend (nicht eingerichtet) · Web-Push-Dienste (nach Aktivierung) · Anthropic (aus) · OpenStreetMap-Kacheln · Nominatim · Google Maps · Open-Meteo · Wechselkurs-APIs · CDN-Bibliotheken · Google Übersetzer/MyMemory · Inseratsimport (Portale, allorigins, cors.lol) · Repull — **alle Status `under_review` bzw. `unknown`, keiner `approved`**.

## MIGRATIONEN
1. 3600 Kosten & Freigaben · 3700 Beta Mode · 3800 Benachrichtigungen & Chat · 3900 Wiederkehr & Automatik · 4000 Bewertungen/Angebote/Notdienst
2. 4100 Security-Härtung (TRUNCATE/anon) · 4200 KI-Vorschläge · 4300 Aufbewahrung/Allowlist/Lösch-Fix
3. **4400 Legal & Beta Compliance** (Rollen+MFA, Rechtstexte, Consent, Nachweise, Moderation, Anfragen, Vorfälle, Audit, Aufbewahrung, Register, Export, Release-Gate, Storage)
4. **4500 Beta Release** (Tester-Felder, Einladungscodes, Umgebungskennung, Wartung, App-Version, Admin-Übersicht) – siehe `README_BETA.md`
Alle idempotent, Neuinstallation (47 Migrationen + Seed) erfolgreich. **Live noch nicht eingespielt (3600–4500).**

## RLS POLICIES
1. RLS auf allen Tabellen in `public`; neue Tabellen nur eigene Zeilen bzw. Admin-Rolle mit `aal2`
2. Admin-Policies auf `private.has_admin_role()` umgestellt (Feedback, Bewertungen, Analytics, Beta-Dashboard, Konfiguration je Schlüssel)
3. Schreiben sensibler Tabellen nur über geprüfte RPCs (Analytics, Freigaben, KI-Ergebnis, Moderation, Nachweise)
4. Keine Client-Rolle mit TRUNCATE/TRIGGER/REFERENCES; `anon` nur Feedback-Insert, Tarife/Konfiguration/Rechtstexte lesen

## TESTERGEBNIS
**PASS** (automatisiert):
- SQL auf frischer Datenbank: 15 Dateien, **398 Prüfungen, 0 Fehler** – davon Testmatrix §39 **48/48** (Tenant-, Partner-Isolation, Widerruf, Admin+MFA, Löschung, Export, Moderation, Einwilligung)
- Browser-E2E: **46/46 Suiten grün** (u. a. `legal` 13/13, `beta` mit TOTP 13/13)
- Release-Gate im System: **nicht bestanden** (13 von 21 Punkten offen – Impressum unvollständig, Drittanbieter ungeprüft, manuelle Prüfungen ausstehend)

## BETA RELEASE

| Stufe | Entscheidung |
|---|---|
| Code & lokale Umgebung | **GO** |
| Live-Datenbank | **NO-GO bis Migrationen 3600–4400 eingespielt** (4100/4400 zuerst) und MFA im Dashboard aktiv |
| Geschlossene Alpha (persönlich eingeladene Tester, keine Zahlungen) | **GO unter Bedingungen:** Migrationen live, Impressum vollständig, Rechtstexte kurz juristisch gesichtet, Tester über Beta-Status informiert |
| **Open Beta** | **NO-GO** – Release-Gate nicht bestanden: juristische Prüfung, AV-Verträge/Drittanbieter, Impressum, DSFA, Importprüfung offen |

Die Entscheidung über den öffentlichen Beta-Start darf nicht allein aus dem automatisierten „PASS“ abgeleitet werden (§43) – sie bleibt eine menschliche, nach juristischer Prüfung.
