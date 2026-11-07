# Husora · Onboarding – Bestandsaufnahme und Implementierungsplan

Grundlage: *Husora Onboarding Architecture Specification* v1.0, alle 22 Kapitel gelesen. Stand: 07.11.2026.

## 1. Vorhandene Architektur (wiederverwendet)

| Bereich | Vorhanden | Verwendung im Onboarding |
|---|---|---|
| App | Eine Datei `index.html` (Vanilla JS); Hausbesitzer-App mit `render()` und `currentPage`; Partner-Portal `pp.*` mit `ppRender()` und `pp.view` | Kein neues Framework und keine neue Route. Die Einrichtung ist eine weitere Ansicht. |
| Erststart | `#onboarding-modal`, `onboardingNeeded()`, Rollenwahl `data-ob-role`, Demo-Weg `data-ob-demo`, Speicher `stugliv-onboarding` | Das Fenster ist die Onboarding-Shell. Rollenwahl und Demo bleiben erhalten. |
| Häuser | `properties`, `propertyWithDefaults`, `saveProperties`, `canAddProperty`; Import über `openAddChoice()` (Inserat); Demo-Haus `sunne` | H2 nutzt dieselbe Anlage. Das Demo-Haus wird umgewandelt, sodass kein Duplikat entsteht. Der Import ist die vorhandene Funktion. |
| Hausprofil | Felder in `#property-form`: `yearBuilt`, `livingArea`, `plotSize`, `rooms`, `heatingSystem`, `fireplace`, `condition`, `lastRenovations`, `plannedRenovations` | H3 schreibt in dasselbe Objekt. Die Auswahllisten werden aus `#property-form` übernommen. |
| Aufgaben | `tasks`, `persistTasks`, `#task-form` mit Wiederholung und Priorität, Tarif-Limit `entitlements.within('tasks_active')` | H4 legt eine echte Aufgabe an. Das ausführliche Formular ist das vorhandene `openTaskModal()`. |
| Kontrolle, Automatik, Partner, Kalender, Dokumente, Kosten | Seiten `inspections`, `automation` (Tarif-Sperre `PAGE_GATES`), `providers`, `calendar`, `documents`, `costs` | H5–H8 führen auf die echten Seiten. Gesperrte Funktionen werden als gesperrt gekennzeichnet. |
| Partner-Betrieb | RPC `create_partner_organization`; Tabellen `organizations`, `service_partners`, `service_partner_areas`, `service_partner_services`; `ppAreasHtml()`, `ppPackages()`, `PP_SERVICE_GROUPS` | P2–P4 schreiben in diese Tabellen. Das Servicegebiet ist die eingebettete vorhandene Komponente. |
| Rollen | `pp.ctx.role`, `ppIsLead()`, `ppIsAdmin()`, Mitgliedschaften | Die Einrichtung sehen nur Leitungsrollen. Serverseitig wird die Mitgliedschaft geprüft. |
| Auth / Cloud | `cloudSignedIn()`, `cloudFetch()`, `cloudSignIn()`, `cloudSignOut()`, `private.current_user_id()` | Server-Fortschritt läuft nur mit Konto. Die Identität kommt aus dem JWT. |
| Analytics | `trackEvent()` → `track_events` → `analytics_events`, abhängig von der Beta-Einwilligung | Keine neue Tracking-Technik. Es werden nur Schlüssel gesendet, keine Inhalte. |
| i18n | `I18N_SOURCE` (DE\|EN\|SV), `I18N_PATTERNS`, `i18nApply` per MutationObserver | Alle Onboarding-Texte sind dort hinterlegt. |
| Hilfe | Seite `help` mit „Ersteinrichtung starten“ | Erneut starten oder fortsetzen; Schalter für die Hilfe-Tipps. |
| Design | Tokens `--green`, `--paper`, `--line`; `primary-btn`, `secondary-btn`, `pp-card`; Dark Mode | Kein neues Branding. |

## 2. Lücken und Konflikte (gefunden → Entscheidung)

1. **Kein Server-Fortschritt vorhanden.** Entscheidung: additive Migration 4800 mit `onboarding_sessions`, `onboarding_step_progress` und `user_onboarding_preferences`. RPCs als `security definer`, RLS nur auf eigene Zeilen.
2. **Keine Sprachspalte nötig.** Die Sprache liegt bereits in `husora-lang`. `preferred_language` wird deshalb nicht dupliziert.
3. **Hausbesitzer ohne Cloud-Konto.** Die App ist local-first. Der Fortschritt liegt lokal und wird bei Anmeldung abgeglichen.
4. **Haus-ID ist eine lokale Text-ID.** Sie wird als `primary_property_ref` (Text) gespeichert, nicht als Fremdschlüssel.
5. **Leistungen.** Das Leistungsmodell besteht aus drei Gruppen plus eigenen Paketen. P4 bietet die Mehrfachauswahl dieser Gruppen. Preise und eigene Pakete bleiben unter „Leistungen“.
6. **Logo und Haustyp.** Logo, Haustyp und Wasser/Abwasser fehlen im Datenmodell. Sie werden nicht vorgetäuscht und sind als offene Punkte dokumentiert.
7. **Echte Demo-Aufträge für P6.** Gibt es nicht. P6 zeigt den Ablauf nur als Erklärung, ohne Demo-Aufträge anzulegen.
8. **Demo-Modus.** Der vorhandene Demo-Weg bleibt. Beim Anlegen des echten Hauses werden Demo-Haus und Beispielaufgaben entfernt bzw. umgewandelt.

## 3. Plan und Status

### Phase 1 – MVP (zwingend)

- [x] Migration 4800 und SQL-Test (Übergänge, Validierung, Mandantentrennung, Cascade)
- [x] Flow-Konfiguration `OB_FLOWS` (`homeowner_v1`, `service_partner_v1`): `key`, `skippable`, `priority`, `rule`
- [x] Shell mit Fortschritt „Schritt n von m“, Zurück, „Später erledigen“, „Später fortsetzen“, Fehlermeldungen
- [x] H1–H4 auf den vorhandenen Funktionen, P1–P4 auf den vorhandenen Tabellen
- [x] Speichern lokal und am Server, Fortsetzen, Abschluss, kein Neustart bei jedem Login
- [x] Dashboard-Checklisten aus echten Daten (Hausbesitzer und Partner)
- [x] **Runde 2:** P4 Mehrfachauswahl der Leistungsgruppen direkt im Schritt
- [x] **Runde 2:** H4 Priorität im Schnellformular, Aufgaben-ID am Schritt speichern
- [x] **Runde 2:** H3 bekannte Reparaturen und geplante Sanierungen (optional, aufklappbar)
- [x] **Runde 2:** P1/P10 Texte nach Spezifikation, P2 Webseite

### Phase 2 – Funktionsführung

- [x] H5–H8 und P5–P9 als kurze Erklärung mit Sprung in die echte Funktion und Rückweg
- [x] Feature-Guides auf Aufgaben, Kontrolle, Partner, Dokumente, Kalender, Automatik
- [x] **Runde 2:** Guide „Hausverwaltung“ (Häuser) und Link „Zur Hilfe“ in jedem Guide
- [x] **Runde 2:** Einstieg Einstellungen → „Einrichtung erneut starten“ (Hausbesitzer und Partner)

### Phase 3 – Optimierung

- [x] DE/EN/SV
- [x] Analytics-Ereignisse
- [x] **Runde 2:** nach Verbindungsabbruch automatisch abgleichen (`online`-Ereignis)
- [x] **Runde 2:** Abmelden entfernt den Partner-Einrichtungsstand vom Gerät (kein Stand eines anderen Nutzers)

### Tests und Abschluss

- [x] SQL-Test sowie E2E für Hausbesitzer und Partner
- [x] **Runde 2:** Unit-Suite für Flow-Auswahl, Reihenfolge, Übergänge, Fortschritt, Versionierung und Checkliste
- [x] **Runde 2:** E2E Hausbesitzer mit Konto: Fortschritt am Server, neues Gerät setzt fort
- [x] **Runde 2:** vollständige Regression aller E2E-Suiten
- [x] Migration 4800 live eingespielt am 07.11.2026 (Projekt ggsoygxmcsmrsrbmplrz). Geprüft: 3 Tabellen, 5 RPCs, RLS aktiv, 3 Policies, anon ohne Ausführungsrecht, kein direktes INSERT für `authenticated`.

## 4. Prüfung nach jeder Phase

| Phase | Prüfung |
|---|---|
| Datenbank | `psql -f supabase/tests/onboarding_test.sql` |
| UI je Rolle | `bash tests/e2e/run.sh onboarding_unit onboarding onboarding_partner` |
| Abschluss | `bash tests/e2e/run.sh` (alle Suiten) |

## 5. Zusätzlich in Runde 2 gefunden und behoben

- **Abgeschlossenen Flow nicht wieder öffnen.** `obStart()` ohne ausdrücklichen Neustart hätte einen abgeschlossenen Flow wieder geöffnet. Abschluss bleibt jetzt bestehen, bis der Nutzer selbst neu startet (Unit-Test).
- **Reihenfolge der Server-Aufrufe.** Parallele Server-Aufrufe konnten in falscher Reihenfolge ankommen, dann zeigte der aktuelle Schritt am Server einen älteren Stand. Alle Onboarding-Aufrufe laufen jetzt nacheinander (`obQueue`). Der Integrationstest prüft das.
- **Standard-Servicegebiet.** Das bei der Betriebsanlage erzeugte leere Gebiet zählte als „Servicegebiet festgelegt“. Es zählt jetzt nicht mehr (E2E).

## 6. Testergebnis Runde 2 (lokaler Supabase-Stack)

- **SQL** `onboarding_test.sql`: bestanden.
- **E2E gesamt:** alle Suiten grün, darunter:
  - `onboarding_unit`: 14/14
  - `onboarding`: 24/24
  - `onboarding_partner`: 14/14
- **Angepasste Bestandstests:**
  - `partner`: Ein neuer Betrieb startet jetzt in der Einrichtung, der Test geht über „Später fortsetzen“ weiter.
  - `back`: Unterseiten zeigen den Zurück-Pfeil.
  - `cal`: Der Test war datumsabhängig. Am Wochenende lag der Auftrag „in 2 Tagen“ in der nächsten Kalenderwoche.
