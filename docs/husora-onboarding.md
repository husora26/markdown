# Husora · Onboarding (Hausbesitzer & Servicepartner)

Stand: Migration **4800** (`20261030004800_onboarding.sql`), App `index.html`.
Grundlage: *Husora Onboarding Architecture Specification*.

## Ziel

Neue Nutzer kommen schnell zu ihrem ersten echten Ergebnis:

- **Hausbesitzer:** erstes Haus → Hausprofil → erste Aufgabe.
- **Servicepartner:** vollständiges Unternehmensprofil → Servicegebiet → Leistungen.

Danach stellt der Flow die wichtigsten Funktionen kurz vor. Jeder Schritt außer Willkommen und Abschluss lässt sich überspringen. Die Einrichtung lässt sich pausieren und später fortsetzen, auch auf einem anderen Gerät, und jederzeit neu starten.

## Architektur

```
OB_FLOWS (Konfiguration je Rolle, versioniert)
   │
   ├─ obState / obMark / obStart / obFinish   lokaler Stand: localStorage husora-onboarding-<rolle>
   │        │                                 (offline-fähig, sofort)
   │        └─ obPush ──► RPC onboarding_save / _finish / _restart   (nur mit Konto, Fehler blockieren nie)
   │
   ├─ obPull  ◄── RPC onboarding_get   (bei Anmeldung, App-Start mit Sitzung, erstem Laden des Partner-Portals)
   │            Zusammenführung: „erledigt“ von beiden Seiten bleibt erledigt, sonst gilt der Server
   │
   ├─ Hausbesitzer: Einrichtungsfenster #onboarding-modal (9 Schritte) + Checkliste „Dein Husora-Start“
   ├─ Servicepartner: Portal-Ansicht pp.view = 'setup' (10 Schritte) + Checkliste „Dein Unternehmen ist bereit?“
   └─ Feature-Guides „Was kann ich hier tun?“ (OB_GUIDES), abschaltbar
```

**Erledigt kommt aus echten Daten, nicht aus Häkchen.**

- Hausbesitzer:
  - „Erstes Haus“ heißt: ein echtes Haus existiert (nicht das Demo-Haus).
  - Hausprofil gilt ab 3 von 7 Angaben als erledigt.
  - Die Aufgabe muss eine echte Aufgabe sein, keine Beispielaufgabe.
  - Die Hauskontrolle braucht einen Kontrollplan oder ein Protokoll.
  - Servicepartner braucht eine Zuordnung.
- Servicepartner:
  - Das Profil braucht Ansprechpartner, Telefon oder E-Mail und Straße oder Ort.
  - Das Gebiet braucht ein Gebiet mit Ort, PLZ, Region oder Umkreis. Das leere Standardgebiet aus der Betriebsanlage zählt nicht.
  - Leistungen braucht mindestens ein aktives Paket.
- `obPartnerSync()` setzt erledigte Schritte nach, wenn Daten anderswo vervollständigt werden, etwa unter Mehr → Firma.

## Flows

### homeowner_v1

| # | Schlüssel | Inhalt | Erledigt wenn |
|---|---|---|---|
| 1 | welcome | Nutzen, Rollenwahl, Rechtstexte (Entwurf), optional Demo | Rolle „Hausbesitzer“ gewählt |
| 2 | property | Name\*, Adresse, Region, Nutzung, ggf. Name; oder Inserat-Import / ausführliches Formular | Haus gespeichert (Demo-Haus wird umgewandelt, keine Duplikate) |
| 3 | profile | Baujahr, Wohnfläche, Grundstück, Zimmer, Heizung, Kamin, Zustand (Fortschrittsanzeige) | ≥ 3 Angaben |
| 4 | task | Vorlagen-Chips oder eigener Titel, Fälligkeit, Wiederholung; ausführliches Formular möglich | Aufgabe gespeichert (Tariflimit geprüft) |
| 5 | inspection | Ablauf Kontrollplan → Fotos → Intervall → Mangel→Aufgabe, Haftungshinweis | Seite geöffnet |
| 6 | automation | Einmalig/wiederkehrend, Beispiel, „nichts automatisch eingeschaltet“, Tarifhinweis | Seite geöffnet |
| 7 | partners | Suche, Zuordnen, Partner-Portal; Hinweis „keine Empfehlung“ | Seite geöffnet |
| 8 | organize | Kalender, Dokumente, Kosten | Weiter |
| 9 | done | Checkliste mit „Jetzt erledigen“ | „Zur Übersicht“ |

### service_partner_v1

| # | Schlüssel | Inhalt | Erledigt wenn |
|---|---|---|---|
| 1 | welcome | Nutzen, Dauer | „Einrichtung starten“ (folgt direkt auf „Betrieb anlegen“) |
| 2 | profile | Ansprechpartner\*, Telefon/E-Mail, Adresse, Kurzbeschreibung (schreibt `organizations` und `service_partners`) | Pflichtfelder vorhanden |
| 3 | area | eingebettete Servicegebiete (`service_partner_areas`), „Weiter“ erst mit Gebiet | echtes Gebiet vorhanden |
| 4 | services | Anzahl aktiver Leistungen, Sprung zu Leistungen & Preise | aktives Paket |
| 5 | orders | Statusablauf Neu → Annehmen → Planen → Erledigt | Auftragsansicht geöffnet |
| 6 | workflow | Ablauf vor Ort | „Verstanden“ |
| 7 | documentation | Fotos, Mängel, Berichte, Haftungshinweis | „Verstanden“ |
| 8 | finance | Angebote, Rechnungen, offene Posten, Steuerhinweis | Finanzen geöffnet |
| 9 | team | Rollen, Einteilung, Rechte | Team geöffnet |
| 10 | done | Checkliste | „Zur Startseite“ |

Die Partner-Einrichtung sehen nur die Leitungsrollen (`ppIsLead()`). Mitarbeitende, die per Einladungscode beitreten, starten direkt bei ihren Aufträgen.

## Bedienung

- **Später fortsetzen** pausiert die Einrichtung (`paused = true`):
  - kein automatisches Öffnen beim nächsten Start;
  - Fortsetzen über die Checkliste auf der Startseite oder über Hilfe → „Einrichtung fortsetzen“.
- **Nicht pausiert:** Beim nächsten App-Start öffnet sich die Einrichtung am gespeicherten Schritt.
- **Später erledigen** markiert den Schritt als `skipped`. Er bleibt in der Checkliste offen.
- **Aus der Einrichtung in eine Funktion:** Ein Hinweis „Weiter mit der Einrichtung“ führt zurück; beim Hausbesitzer ist das eine schwebende Pille, im Partner-Portal ein Banner.
- **Haus oder Aufgabe über das ausführliche Formular bzw. den Import:** Das wird erkannt (`obAfterRender`), und die Einrichtung springt zum nächsten Schritt.
- **Neustart:**
  - Hilfe → „Ersteinrichtung starten“, wenn die Einrichtung abgeschlossen ist;
  - „Einrichtung starten“ auf der Partner-Checkliste.
  - Der Neustart setzt nur die Schritte zurück. Haus, Aufgaben und Firmendaten bleiben.
- **Checkliste ausblenden** speichert die Präferenz lokal und am Server:
  - Hausbesitzer: `onboarding_dismissed_at`;
  - Partner: Guide-Schlüssel `partner_checklist`.
- **Feature-Guides** gibt es auf Aufgaben, Hauskontrolle, Servicepartner, Dokumente, Kalender und Automatisierung:
  - Pille „Was kann ich hier tun?“, darunter die Karte mit „Nicht mehr anzeigen“ (pro Seite);
  - global ein- und ausschaltbar unter Hilfe → „Hilfe-Tipps aus-/einschalten“.
- **Bestandsnutzer** mit Daten oder dem Stand `stugliv-onboarding = done` sehen weder Fenster noch Checkliste.
- **„Erst die Demo ansehen“** (nur außerhalb der Beta) bleibt erhalten. Der Demo-Hinweis führt direkt zu „Erstes Haus“.

## Datenbank (Migration 4800)

| Tabelle | Zweck |
|---|---|
| `onboarding_sessions` | eine Sitzung je Nutzer, Rolle und Flow-Version: `current_step_key`, `status` (`not_started`, `in_progress`, `completed`, `skipped`), `paused`, `primary_property_ref`, `organization_id`, Zeitstempel |
| `onboarding_step_progress` | Status je Schritt: `pending`, `in_progress`, `completed`, `skipped`; Zeitstempel und kurze Metadaten (≤ 1000 Bytes) |
| `user_onboarding_preferences` | `onboarding_dismissed_at`, `help_tips_enabled`, `dismissed_guides[]` |

**RPCs** (alle `security definer`, `search_path = ''`, nur `authenticated`):

- `onboarding_get(role)`
- `onboarding_save(role, flow, step, status, current, metadata, refs)`
- `onboarding_finish(role, flow, status)`
- `onboarding_restart(role, flow)`
- `onboarding_preferences(dismissed, help_tips, guide, guide_dismissed)`

**Sicherheit:**

- **RLS:** Jeder liest nur die eigenen Zeilen. Direktes Schreiben ist für `anon` und `authenticated` entzogen; Änderungen laufen nur über die RPCs.
- **Organisation:**
  - `organization_id` aus dem Client wird **nicht vertraut**. Die Organisation wird nur verknüpft, wenn der Nutzer aktives Mitglied ist.
  - Der Servicepartner-Flow verlangt die Mitgliedschaft in einem Servicebetrieb.
- **Validierung:**
  - Flow-Version, Schrittschlüssel und Status werden gegen die Konfiguration geprüft.
  - Metadaten werden gefiltert: nur kurze Schlüssel und Werte, keine Freitexte.
- **Übergänge:** Erledigt bleibt erledigt. Ein abgeschlossener Flow wird nicht durch „übersprungen“ überschrieben.
- **Konto löschen:** entfernt Sitzungen, Schritte und Präferenzen per Cascade.

## Analytics

Über das bestehende `trackEvent` mit Beta-Einwilligung, dedupliziert über `entity_ref`. Es werden keine Inhalte gesendet, nur Schlüssel.

Ereignisse:

- `onboarding_started`, `onboarding_resumed`
- `onboarding_step_viewed`, `onboarding_step_completed`, `onboarding_step_skipped`
- `onboarding_completed`, `onboarding_dismissed`
- `activation_property_created`, `activation_first_task_created`, `activation_inspection_started`
- `activation_partner_profile_completed`, `activation_service_added`, `activation_first_order_viewed`
- `feature_guide_opened`, `feature_guide_dismissed`

## Sprachen

Alle neuen Texte sind in `I18N_SOURCE` auf DE, EN und SV hinterlegt. Zahlenhaltige Texte wie „Schritt n von m“ und „x von y … erledigt“ laufen über `I18N_PATTERNS`.

## Tests

| Test | Inhalt |
|---|---|
| `supabase/tests/onboarding_test.sql` | Sitzung, Übergänge, Metadatenfilter, ungültige Werte, Partner-Gating, Pause, Abschluss, Neustart, Präferenzen, Mandantentrennung, anonym, Cascade |
| `tests/e2e/onboarding.js` (22 Schritte) | kompletter Hausbesitzer-Flow, Pflichtfeld, Demo-Haus-Umwandlung ohne Duplikat, Zurück, Pause und Neuladen, Fortsetzen, Funktionssprung mit Rückweg, Überspringen, Abschluss, Checkliste aus echten Daten, Ausblenden, Neustart, ausführliches Formular, Feature-Guides, Hilfe-Tipps, Demo-Weg, Bestandsnutzer |
| `tests/e2e/onboarding_partner.js` (12 Schritte) | Betrieb anlegen → Einrichtung, Profil-Pflichtfelder und DB, Gebiet (leeres Standardgebiet zählt nicht), Leistungen mit Rückweg, Pause, Serverstand, neues Gerät setzt am Serverstand fort, Funktionsschritte, Abschluss (Server), Mitarbeiter ohne Einrichtung |

## Offene Punkte

- **Rechtstexte:** Die Texte und Hinweise im Flow sind Entwürfe. Sie sind technisch umgesetzt, die juristische Prüfung ist offen.
- **Feature-Guides im Partner-Portal** gibt es noch nicht. Dort übernehmen die Einrichtungsschritte diese Rolle.
- **Fotos im Hausprofil-Schritt:** Hier gibt es nur einen Hinweis. Fotos bleiben im Hausprofil, damit der Schritt kurz bleibt.
- **Hausbesitzer ohne Konto:** Der Fortschritt bleibt lokal. Mit der ersten Anmeldung wird er an den Server übertragen.
