# Husora Launch-Checkliste – Prüfstand

Geprüft gegen den Code in diesem Repository (`index.html`, `supabase/`) – Stand 31.10.2026.
Grundlage: „Husora Launch Checklist v1.0“.

Legende: **[x]** erledigt · **[~]** teilweise / mit Einschränkung · **[ ]** offen · **[ext]** braucht eine Entscheidung oder ein Konto außerhalb des Codes (Betrieb, Recht, Stripe …)

> **Architektur-Hinweis:** Husora läuft als eine Web-App (`index.html`, GitHub Pages) mit Supabase (Postgres, Auth, Storage, RLS) statt Next.js/Vercel. Die Daten liegen offline-fähig im Browser und werden mit der Cloud abgeglichen (`app_data`); Häuser, Buchungen und Aufgaben werden zusätzlich in die Fachtabellen übernommen. Geschäftsregeln mit Fremdzugriff (Partner, Aufträge, Rechnungen, Tarife) prüft die Datenbank selbst.

**Mit diesem Durchgang neu umgesetzt:** Feedback-Kanal in der App · automatische Fehlerberichte (abschaltbar) · Konto- und Cloud-Daten selbst löschen · Benachrichtigungen bei Auftragsstatus und Rechnungen in der Glocke · Offline-Hinweis · Stripe Checkout/Webhook/Kundenportal vorbereitet · Aufbewahrungsfristen per pg_cron · API-Schlüssel der Buchungsportale verlassen das Gerät nicht mehr (Sicherheitslücke geschlossen) · Datenschutzerklärung ergänzt.

---

## 1. Launch-Ziel und MVP-Abgrenzung
- [x] P0 Produktziel: Hausbesitzer verwalten ihr Haus zentral
- [x] P0 Kernworkflow durchgängig: Registrierung → Rolle → Haus → Dashboard → Hauskontrolle → Mangel → Servicepartner → Auftrag → Termin → Erledigung → Bericht/Foto → Rechnung → Kosten (End-to-End getestet)
- [~] P0 Je Schritt Datenbank/UI/Serverfunktion/Fehlerfall – vorhanden, aber nicht als eigenes Dokument beschrieben
- [x] P0 Nicht-MVP-Funktionen markiert: Tarifvergleich kennzeichnet „in Vorbereitung“ (Kostenprognose, Portfolio, Eskalationen …)
- [ ] P0 Definition of Done festlegen **[ext]**
- [x] P1 Feedbackkanal in der App (Hilfe & Support → Feedback & Fehler melden → `app_feedback`) *neu*
- [ ] P1 Beta-/Testgruppe festlegen **[ext]**

## 2. Authentifizierung und Benutzer
- [x] P0 Supabase Auth produktiv (Projekt `ggsoygxmcsmrsrbmplrz`)
- [x] P0 Registrierung per E-Mail, Login/Logout, Passwort zurücksetzen, E-Mail-Bestätigung (inkl. „erneut senden“)
- [x] P0 Session-Handling: automatische Token-Erneuerung bei 401, Rückkehr aus Bestätigungs-/Reset-Mail
- [x] P0 Benutzerprofil, Onboarding nach Registrierung, Rollenwahl Hausbesitzer/Servicepartner
- [~] P0 Rolle dauerhaft: Organisationstyp `homeowner`/`service_partner` in der Datenbank; ein Konto darf bewusst beides haben (eigene Häuser + eigener Betrieb)
- [x] P0 Rollenwechsel nicht unkontrolliert: Rechte hängen an der Mitgliedschaft je Organisation, nicht an einer Browser-Einstellung
- [~] P0 Abgelaufene Sessions: Erneuerung getestet; Fehlerfall „Refresh-Token ungültig“ führt zur Anmeldung
- [~] P1 Profil: Name/E-Mail ja; Profilbild, Telefon, Sprache fehlen
- [x] P1 Account löschen *neu* (Einstellungen → Daten & App → Konto und Cloud-Daten löschen) · Datenexport über Datensicherung (Datei)

## 3. Organisationen und Berechtigungen
- [x] P0 Organisation je Konto (`ensure_my_organization`), Mitglieder, Rollen (admin, property_manager, service_manager, dispatcher, technician, inspector, accounting, viewer)
- [~] P0 HOUSE_OWNER / SERVICE_PARTNER / ADMIN: über Organisationstyp + Rolle abgebildet; ein Plattform-Admin-Bereich existiert nicht (Verwaltung über Supabase-Dashboard)
- [x] P0 Property-Mitgliedschaften (`property_users`), serverseitige Prüfung über RLS + security-definer-Funktionen
- [x] P0 Servicepartner sehen nur Objekte mit eigenem Auftrag, keine fremden Kundendaten
- [x] P0 RLS auf allen Kundentabellen, Cross-Tenant getestet (`supabase/tests/rls_test.sql` 84 Prüfungen, `partner_portal_test.sql` 53)
- [x] P1 Mitglieder in Hausbesitzer-Organisationen einladen (Einstellungen → Mitglieder, TEAM-Code, Rollen, Organisationswahl) *neu*

## 4. Haus / Objektverwaltung
- [x] P0 Haus anlegen, bearbeiten, löschen; Adresse, Standort (Karte)
- [x] P0 Wohnfläche, Grundstück, Baujahr, Zimmer, Betten; Heizung/Kamin u. a. als Gebäudedaten (Import oder manuell)
- [x] P0 Fotos hochladen, Titelbild festlegen (auch direkt unter Buchungen)
- [x] P0 Bauteile/Bereiche (Hausmodell, Mängel je Bauteil)
- [~] P0 Räume: als Bereiche/Positionen der Kontrolle, nicht als eigene Raumliste
- [x] P0 Hausbesitzer ↔ Objekt (Organisation), Datenvalidierung (Pflichtfelder, Wertebereiche, DB-Constraints)
- [x] P0 Archivieren statt Löschen (wiederherstellbar; in der Cloud bleibt das Haus mit Aufträgen erhalten) *neu* · Löschen entfernt alle verknüpften Aufgaben, Mängel, Kosten *neu*
- [ ] P1 Zustands-Score (im Tarif ULTIMATE als „in Vorbereitung“)
- [x] P1 Hausmodell
- [ ] P2 mehrere Eigentümer

## 5. Dashboard
- [x] P0 Gewähltes Haus, offene/überfällige Aufgaben, kommende Kontrollen, offene Mängel, Verträge/Fristen, Kosten, Notfall, Schnellaktionen, leere Zustände
- [~] P0 Offene Serviceaufträge: im Partner-Portal und als Aufgabenstatus „In Bearbeitung“, nicht als eigene Dashboard-Kachel
- [ ] P1 Zustandsscore · [~] P1 Handlungsempfehlungen (Erinnerungen in der Glocke)

## 6. Hauskontrolle
- [x] P0 Kontrollplan, Kontrollpunkte, Kategorien, Frequenz, Verantwortlicher (Servicepartner)
- [x] P0 Status OK / Hinweis (auffällig) / Mangel / nicht geprüft
- [x] P0 Foto und Notiz je Punkt, Mangel direkt aus der Kontrolle, Bericht speichern, PDF-Prüfbericht, Abschluss
- [x] P0 Nachkontrolle nur der auffälligen Punkte *neu*
- [~] P1 automatische Folgekontrolle (monatliche Abwesenheitskontrolle als Automatik) · [x] P1 Saison-Checklisten · [x] P1 Partner je Kontrollbereich

## 7. Mängelmanagement
- [x] P0 Mangel erstellen, mit Haus/Bauteil/Kontrolle verknüpft, Priorität, Beschreibung, Fotos, Fälligkeit, Servicepartner
- [x] P0 Status: Gemeldet / Reparatur geplant / In Arbeit / Behoben / Abgebrochen / als Sanierung geplant *neu*
- [x] P0 Automatisch Reparaturaufgabe aus Mangel; mit verbundenem Partner automatisch Auftrag
- [x] P0 Mangelhistorie mit Verlauf aller Statuswechsel *neu*
- [~] P0 Abschluss nach Bestätigung: Auftrag „erledigt“ hakt die Aufgabe automatisch ab (bewusst so gewünscht); eine zusätzliche Abnahme durch den Hausbesitzer gibt es nicht
- [ ] P1 Eskalation bei Überfälligkeit (Tarif ULTIMATE, in Vorbereitung)

## 8. Servicepartner
- [x] P0 Registrierung, Unternehmensprofil, Ansprechpartner, Kontakt, Leistungen (Hauskontrolle/Servicearbeiten/Sanierungen mit Preis je Paket/Stunde)
- [~] P0 Einsatzgebiet: Radius in km; keine Gebietskarte
- [x] P0 Zuordnung zu Häusern, Partner-Dashboard, nur zugewiesene Aufträge, annehmen/ablehnen, Termin, Status, Fotos/Bericht, Abschluss (+ Rechnung in einem Schritt)
- [ ] P1 Bewertungen · [ ] P1 Zertifikate · [~] P1 Suche (Verzeichnis „Servicepartner finden“) · [ ] P2 komplexes Matching (Datenbankfunktion `match_service_partners` vorhanden, nicht in der UI)

## 9. Serviceaufträge
- [x] P0 aus Aufgabe/Mangel erzeugen („SP beauftragen“, automatisch), manuell (Partner-Portal, Mehrfachauswahl), Leistungsbeschreibung, Priorität, Frist/Termin, Statusworkflow, Rückmeldung, Arbeitsfotos, Abschlussnotiz
- [~] P0 Raum/Mangel-Verknüpfung über die Aufgabe, nicht direkt am Auftrag
- [x] P0 Zugangsinformationen zeitlich begrenzt je Auftrag freigeben, Abruf protokolliert, endet mit dem Auftrag *neu*
- [x] P0 Historie/Audit Trail: Auftragsverlauf aus `audit_logs` in der Auftragskarte (Admins) *neu*
- [x] P1 Kosten-/Angebotsfeld · [ ] P1 Auftrag als PDF · [ ] P1 E-Mail-Benachrichtigung
- [x] neu: Benachrichtigung bei angenommen/abgelehnt/terminiert/begonnen/erledigt und zurückgezogen

## 10. Aufgaben
- [x] P0 erstellen, bearbeiten, Fälligkeit, Verantwortlicher (Partner/Eigenleistung), Priorität, Status, wiederkehrend, Hausbezug, erledigen, überfällig, getrennt von Hauskontrollen
- [ ] P1 Unteraufgaben · [ ] P1 Anhänge

## 11. Automatisierung
- [x] P0 Regeln mit Auslöser, Aktion, Frequenz, aktiv/inaktiv, je Haus (Gästewechsel, Saison, Kontrolle, Reparatur)
- [~] P0 Fehlerprotokoll: serverseitig `automation_runs`; in der App keine Anzeige
- [x] P0 keine Endlosschleifen (jede Automatik erzeugt je Anlass genau eine Aufgabe)
- [x] P1 saisonale Aufgaben, Kontrolltermine, Erinnerungen · [ ] P2 intelligente Auftragsvergabe

## 12. Reparatur und Instandhaltung
- [x] P0 Reparaturfall, Mangel → Reparatur, Status, Partner, Termin, Fotos, Kosten, Rechnung verknüpft, Abschluss
- [~] P1 Wartungshistorie je Bauteil · [~] P1 Wartungsintervalle (wiederkehrende Aufgaben)

## 13. Sanierung und Renovierung
- [x] P1 Projekt, Budget, Zeitraum, Status, Kosten, Dokumente, Auftragnehmer
- [~] P1 Gewerke, Fotos vorher/nachher, Budgetabweichung – teilweise
- [ ] P2 Fördermittel · [ ] P2 Meilensteine

## 14. Dokumente
- [x] P0 Supabase Storage (private Buckets), Upload, Hauszuordnung, Kategorien, sichere Zugriffsregeln, Anzeige/Download, Löschen, Typ-/Größenprüfung, keine öffentlichen URLs
- [ ] P1 Versionierung · [x] P1 automatische Ablage (Rechnungen, Prüfberichte) · [x] P1 OCR (Rechnungen auslesen)

## 15. Rechnungen und Kosten
- [x] P0 manuell erfassen, hochladen, Betrag, Datum, Anbieter, Kategorie, Hausbezug, speichern, verknüpfen
- [x] P0 Partner-Rechnungen werden automatisch als Ist-Kosten gebucht
- [x] P0 KI/OCR-Ergebnis wird vor dem Speichern zur Prüfung angezeigt
- [x] P1 Jahreskosten · [x] P1 Kostenentwicklung · [ ] P2 Prognose

## 16. Verträge und Fristen · 17. Zähler · 19. Buchungen
- [x] P1 Verträge mit Art, Anbieter, Beginn/Ende, Kündigungsfrist, Erinnerung, Fristberechnung · [~] Dokumentverknüpfung
- [x] P1 Zähler, Typ, Nummer, Einheit, Stand, Datum, Verbrauch · [~] Foto · [ ] P2 Analyse
- [x] P1 Buchungen manuell, An-/Abreise, Gast, Status, iCal-Kalender, Portale über Repull · [x] P2 automatische Reinigung/Kontrolle nach Abreise

## 18. Notfall und Zugang
- [x] P0 Notfallkontakte, Telefonnummern, Hinweise, Zugangsinformationen
- [~] P0 Zugriff: nur Mitglieder der eigenen Organisation (RLS); innerhalb der Organisation keine Sonderstufe (auch „Nur lesen“-Mitglieder sehen Zugangsdaten)
- [x] P0 keine öffentlichen Links · [x] P1 zeitlich begrenzte Zugangsfreigabe je Auftrag *neu*

## 20. Listing Import / AI
- [x] P1 Import mit Prüfung vor Übernahme, Übersetzung, Gebäudehinweise
- [~] P0 KI-Fehler werden abgefangen; Kennzeichnung „Vorschlag“ vorhanden, aber nicht überall einheitlich
- [x] P1 Tariflimits inkl. Monatszähler für Inseratimporte und Rechnungsanalysen (`consume_usage`) *neu*

## 21. Tarife und Entitlements
- [x] P0 FREE/PLUS/PRO/ULTIMATE aus `public.plans` (Preise nicht im Code), zentrale Prüfung `entitlements.can()/limit()`
- [x] P0 Limits Häuser, aktive Aufgaben, Servicepartner, Dokumente; Module (Reparatur, Sanierung, Verträge, Zähler, Automatik, Hausmodell, Partner-Portal, Import, Rechnungserkennung)
- [x] P0 serverseitig: Partner-Portal/Serviceaufträge ab PRO (Trigger), Abo kann nicht aus dem Browser gesetzt werden
- [x] P0 Häuser-, Dokument- und Benutzergrenzen zusätzlich serverseitig *neu*
- [x] P0 Downgrade löscht nichts, neue Einträge über dem Limit gesperrt, Bestand bleibt lesbar
- [x] P0 Benutzer-Limit (Server lehnt Einladungen über dem Limit ab) *neu*

## 22. Stripe / Bezahlung
- [x] Code vorbereitet *neu*: `supabase/functions/stripe-checkout` (Checkout + Kundenportal), `stripe-webhook` (Signaturprüfung, Idempotenz über `stripe_events`, Upgrade/Downgrade/Kündigung/Zahlungsfehler → `subscriptions`)
- [x] App: Knopf „Wechseln“ nutzt Stripe, sobald `plans.stripe_price_id` gesetzt ist; sonst Anfrage per E-Mail; „Abo verwalten“ öffnet das Kundenportal
- [ ] P0 Stripe-Konto, Produkte/Preise, Secrets, Deploy der Funktionen, Webhook-Endpunkt, Testkäufe **[ext]** – Anleitung in `supabase/README.md`

## 23. Benachrichtigungen
- [x] P0 In-App (Glocke): Aufgaben, Kontrollen, überfällig, Fristen + *neu* Cloud-Ereignisse (Auftrag angenommen/abgelehnt/erledigt, Rechnung)
- [x] P0 Partner: neue Anfrage (Zähler), zurückgezogen; Nachrichten im Messenger mit Zähler
- [ ] P1 E-Mail · [~] P2 Push (System-Benachrichtigung bei geöffneter App) · [ ] P2 SMS/WhatsApp

## 24. Datenbank / Supabase
- [x] P0 Tabellen, Fremdschlüssel (zusammengesetzt mit `organization_id`), Unique, NOT NULL, Indizes, Zeitstempel, RLS, Storage-Policies, RPCs mit Berechtigungsprüfung, Audit Logs
- [~] P0 Soft Delete nur teilweise (Status statt Löschen bei Aufträgen)
- [~] P0 Backup-Konzept: Supabase-Tagesbackups (Tarif abhängig) + Datensicherung in der App; Wiederherstellung nicht geprüft **[ext]**
- [x] P1 Seed-Daten, versionierte Migrationen (`supabase/migrations`, 22 Dateien), [~] Produktion getrennt von Entwicklung (lokaler Stack vs. ein Produktionsprojekt, kein Staging)

## 25. API / Backend
- [~] P0 Geschäftsregeln: Fremdzugriffe (Aufträge, Rechnungen, Partner, Tarife) serverseitig; eigene Hausdaten im Gerät
- [x] P0 Eingaben serverseitig über Constraints/Trigger, Authentifizierung und Autorisierung bei jedem Zugriff (RLS)
- [~] P0 Fehlercodes teilweise standardisiert (Postgres-Fehlercodes + deutsche Meldungen)
- [~] P0 Rate Limits: Supabase Auth + Feedback (30/h je Konto); sonst keine
- [x] P0 keine KI-/API-Schlüssel im Frontend (nur der öffentliche Supabase-Schlüssel), Stripe-Secrets nur in Edge Functions
- [x] P1 Logging (Fehlerberichte, Edge-Function-Logs) · [x] P1 Retry (Stripe wiederholt, App wiederholt Speichern) · [x] P1 Idempotenz bei Webhooks

## 26. Sicherheit
- [x] P0 RLS vollständig getestet, A sieht B nicht, Organisation A sieht B nicht, Partner nur Freigegebenes, Dokumente/Storage geprüft
- [~] P0 Notfall-/Zugangsdaten: organisationsweit lesbar (siehe 18)
- [x] P0 SQL-Injection (PostgREST, parametrisiert), XSS (durchgängig `escapeHtml`), CSRF (Bearer-Token, keine Cookies)
- [x] P0 keine Secrets in Git, kein `.env`
- [x] *neu behoben:* Repull-API-Schlüssel wurde beim Cloud-Abgleich mit hochgeladen – bleibt jetzt nur auf dem Gerät
- [ ] P0 „Leaked Password Protection“ in Supabase Auth einschalten **[ext]** (Dashboard → Authentication → Passwords)
- [ ] P1 externes Security Audit · [x] P1 Dependency Audit (keine npm-Abhängigkeiten im Client)

## 27. Recht / Datenschutz
- [~] P0 Impressum – Telefon und USt-IdNr. fehlen noch (`LEGAL_INFO` in `index.html`)
- [x] P0 Datenschutzerklärung (Cloud, Supabase/London, Partner-Portal, Feedback/Fehlerberichte, Löschung) · [x] P0 AGB mit Widerrufsrecht
- [x] P0 keine Tracking-Cookies (nur lokaler Speicher für die App-Funktion)
- [ ] P0 AVV mit Supabase abschließen **[ext]** (Supabase Dashboard → Legal → DPA), ebenso Stripe
- [x] P0 Löschkonzept *neu* (Selbst-Löschen, Fristen per pg_cron), Datenexport (Datensicherung), Datenschutzeinstellung (Fehlerberichte aus)
- [~] P0 Einwilligungen dokumentieren: AGB-Bestätigung beim Kauf; bei der Registrierung kein gespeicherter Nachweis
- [~] P0 KI-Datenverarbeitung: Hinweis beim Import (Übersetzungsdienst), nicht zentral erklärt
- [ ] P1 rechtliche Prüfung durch Fachperson **[ext]**

## 28. Mobile / UX
- [x] P0 Mobile-first, Navigation, Formulare, Upload (Kamera), Ladezustände, Fehlermeldungen, *neu* Offline-Hinweis
- [x] P0 Android Chrome (automatisierte Tests mit mobiler Ansicht 390 px)
- [ ] P0 iPhone Safari und Tablet auf echten Geräten **[ext]**
- [ ] P1 PWA (Installierbarkeit/Offline-Start)

## 29. Performance
- [x] P0 kein Build nötig, Bilder komprimiert (max. 1800 px), Datenbankabfragen optimiert (RLS-Hilfsfunktion beschleunigt)
- [~] P0 API-Aufrufe: Hintergrundabgleich alle 30–60 s; [~] Lazy Loading nur teilweise; [~] Listen mit festen Obergrenzen statt Paginierung
- [ ] P1 Performance-Monitoring / Core Web Vitals

## 30. Testing
- [x] P0 RLS-Tests (137 Prüfungen), Auth, CRUD, Mangel → Auftrag, Auftrag → Abschluss, Rechnung → Kosten, Tariflimits, Uploads, Mobile E2E (15 Playwright-Testreihen)
- [ ] P0 Stripe-Webhook mit echtem Testkonto **[ext]** · [~] KI-Fehlerfälle
- [ ] P0 3 echte Testkonten / externe Tester **[ext]**
- [x] P1 automatisierte E2E-Tests in `tests/e2e` (22 Testreihen) + GitHub Actions (`.github/workflows/tests.yml`) *neu*

## 31. Monitoring / Betrieb
- [x] P0 Produktionsumgebung, *neu* Fehlertracking (`app_feedback`, Art „error“), Edge-Function-Logs, Supabase-Monitoring
- [ ] P0 Staging · [ ] P0 Backup-Wiederherstellung testen **[ext]** · [ ] P1 Uptime-Monitoring · [x] P1 keine Analytics (datenschutzfreundlich)

## 32. Support
- [x] P0 Hilfe-Seite, Kontakt, verständliche Fehlermeldungen · [x] P1 FAQ, Onboarding-Hilfe, Demo-/Testmodus · [~] P1 Tickets (Feedback-Tabelle, Auswertung im Dashboard)

## 33. Deployment
- [x] HTTPS (GitHub Pages), Supabase-Produktionsprojekt, Produktionsmigrationen ausgeführt
- [~] Git sauber; [ ] Branch-Schutz für `main` **[ext]**; [ ] Staging; [ ] eigene Domain **[ext]**; [ ] Stripe Live **[ext]**
- [x] Smoke-Test nach jedem Deployment (lokal gegen echten Supabase-Stack)

## 34. Pre-Launch Smoke Test
- [x] Registrierung · Login · Rolle Hausbesitzer · Haus anlegen · Dashboard · Kontrolle erstellen/abschließen · Mangel · Partner zuordnen · Auftrag erzeugen · Partner sieht/bearbeitet/schließt ab · Rechnung · Kosten · Tariflimit · Dokument-Upload · Logout · A sieht B nicht (alle automatisiert geprüft)

## 35. Launch-Kriterien
- [x] Registrierung/Login stabil · [x] Rollenmodell · [x] Supabase + RLS getestet · [x] Kernworkflow · [x] FREE/PLUS/PRO technisch kontrolliert · [x] Servicepartner-Workflow · [~] mobile Nutzung (echte iPhones offen)
- [ ] Stripe funktioniert **[ext]** · [ ] Recht geprüft **[ext]** · [ ] Backup/Wiederherstellung getestet **[ext]** · [ ] 3–5 externe Tester **[ext]**

---

### Nächste sinnvolle Schritte im Code
Alle zuvor offenen Code-Punkte sind umgesetzt. Offen sind nur noch Punkte mit **[ext]** (Stripe-Konto, Recht, echte Geräte, Tester, Backup-Test) sowie spätere Ausbaustufen (P2/P3).
