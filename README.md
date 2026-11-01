# Husora – Ferienhausverwaltung

Kopie der Husora-App (Stand 30.10.2026, Quelle: `husora26/claude-version`, Commit `aab093f`).

Husora hilft beim Verwalten von Ferienhäusern in Schweden: Serviceaufgaben, Hauskontrolle mit Kontrollplänen und Prüfprotokollen, Saison-Checklisten, Reparaturen und Sanierungen, Servicepartner, Buchungen, Kosten mit Finanzierung und Jahresarchiv, Dokumente, Verträge, Zählerstände, Notfall & Zugang.

## Lokal starten

Kein Build nötig – die App ist eine einzelne `index.html`. Voraussetzung: Node.js (für `npx`).

```bash
npm run dev            # App unter http://localhost:8080 (Hausbesitzer)
npm run dev:partner    # direkt im Partner-Portal (/?partner)
npm run db:start       # optional: lokale Supabase (Docker), sonst nutzt die App das Husora-Cloud-Projekt
npm run test:e2e       # Browser-Tests (lokale Supabase + App auf Port 8081)
```

## Aufbau

- `index.html` – die komplette App (HTML, CSS und JavaScript in einer Datei)
- `assets/` – Bilder der Startseiten-Kacheln

## Starten

Die App läuft ohne Build-Schritt direkt im Browser:

```bash
python3 -m http.server 8080
# dann http://localhost:8080 öffnen
```

Alle Daten werden im Browser gespeichert (localStorage). Unter Einstellungen → Datensicherung lassen sie sich als Datei sichern und wiederherstellen.

## Datenbank (Supabase)

Unter [`supabase/`](supabase/README.md) liegt die komplette PostgreSQL-Datenbank für den Mehrbenutzerbetrieb:

- Migrationen mit Fremdschlüsseln, Indizes und Row Level Security
- Storage-Buckets
- Automatisierung, Partner-Ranking und Webhooks
- Seed-Daten und ein RLS-Test
- Partner-Portal: Zugang für Servicepartner mit Aufträgen, Kontrollen, Fotos, Rechnungen und Mitarbeitern
- Feedback, automatische Fehlerberichte, Konto selbst löschen, Benachrichtigungen bei Auftragsstatus, Offline-Hinweis
- Tarife FREE, PLUS, PRO und ULTIMATE mit zentraler Freischaltung (Preise und Grenzwerte aus der Datenbank)
- Messenger mit Servicepartnern: neue Nachrichten erscheinen oben rechts in der Hauptleiste (Zähler, Vorschau, direkt ins Gespräch)
- Aufgaben, die in der App einem verbundenen Servicepartner zugeordnet sind, gehen automatisch als Auftrag in dessen Partner-Portal (einmal je Aufgabe)

Den Prüfstand zum Launch zeigt [`LAUNCH_CHECKLIST.md`](LAUNCH_CHECKLIST.md).

Installation, Konfiguration und Tests beschreibt [`supabase/README.md`](supabase/README.md).

## Tests

- SQL-Sicherheitstests: `supabase/tests/*.sql` (RLS, Partnerzugang)
- Browser-Tests (Playwright): `tests/e2e/` – lokal mit `supabase start`, App per `python3 -m http.server 8081`, dann `bash tests/e2e/run.sh` (einzelne Reihen: `bash tests/e2e/run.sh cloud partner`)
- GitHub Actions führt beides bei jedem Push auf `main` aus (`.github/workflows/tests.yml`); Screenshots liegen als Artefakt am Lauf.
