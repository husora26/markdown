# Husora – Designsprache (Stand 2026-11)

**Leitsatz:** ruhig, wohnlich, nordisch.
Husora ist das Werkzeug, mit dem Ferienhausbesitzer aus der Ferne ihr Haus in Schweden im Griff behalten. Das Design soll Ruhe und Verlässlichkeit ausstrahlen, gut lesbar sein (auch für ältere Nutzer) und nie technisch wirken.

Regler: Kreativität = sicher · Dichte = ausgewogen · Varianz = einheitlich · Bewegung = zurückhaltend.

## Was bleibt (Wiedererkennung)
- Logo und Wortmarke „HUSORA“ (Avenir Next, weit gesperrt) im dunklen Waldgrün-Band mit Landschaftsfoto.
- Farben: Waldgrün `#244b3d` / `#17372f`, Tinte `#203a33`, warmes Papier `#fffdf8`, Leinwand `#f4efe4`, Bernstein `#a9844f` als Akzent.
- Dunkelmodus (`html.dark`) mit eigener Palette.

## Tokens (in `index.html`, `:root`)
| Bereich | Tokens |
|---|---|
| Schrift | `--font-ui`: **Figtree** (lokal in `assets/fonts/`, OFL, kein Google-Server) → Avenir Next → Systemschrift |
| Schriftgrößen | `--fs-2xs` 12 · `--fs-xs` 13 · `--fs-sm` 14 · `--fs-base` 15 · `--fs-md` 16 · `--fs-lg` 18 · `--fs-xl` 22 · `--fs-2xl` 26 (px) |
| Ecken | `--r-xs` 4 · `--r-sm` 8 · `--r-md` 12 · `--r-lg` 16 (px); Pillen bleiben rund |
| Tiefe | `--shadow-sm` (Karten) · `--shadow-md` (Hover, Toast) · `--shadow-lg` (Menüs, Dialoge) – grün getönt, nie reines Schwarz |
| Fokus | `--focus-ring` – 3 px weicher grüner Ring für Tastatur und Schalter |
| Text grau | `--muted` `#5d6a62` (Kontrast 5,5 : 1 auf Papier, vorher 3,9 : 1) |

## Regeln
- Neue Schriftgrößen, Ecken und Schatten **nur** über die Tokens, keine festen px-Werte.
- Bedienelemente mindestens **44 px** hoch (Knöpfe, Eingabefelder, Symbolknöpfe).
- Eingabefelder auf dem Handy mit **16 px**, sonst zoomt iOS beim Antippen hinein.
- Ein Akzent pro Fläche: Grün für Handeln, Rot nur für Überfälliges/Fehler, Bernstein für „bald fällig“.
- Gestaltungsschicht: Block `HUSORA-DESIGN-2026` direkt vor `DARK-MODE-START` in `index.html`.

## Begriffe (überall gleich verwenden)
| Begriff | Bedeutung | Nicht verwenden |
|---|---|---|
| Ferienhaus | das Objekt des Besitzers | Objekt, Immobilie (außer im Partner-Portal) |
| Aufgabe | alles, was jemand erledigen soll | Serviceauftrag, To-do |
| Hauskontrolle | Rundgang mit Prüfpunkten | Inspektion, Check |
| Mangel | etwas, das kaputt oder auffällig ist | Schaden, Auffälligkeit (nur im Prüfbericht) |
| Reparatur | die Behebung eines Mangels | Instandsetzung |
| Servicepartner | Betrieb vor Ort | Dienstleister, Handwerker |

## Navigation
- Untere Leiste ist in jedem Tarif gleich aufgebaut: Übersicht, Aufgaben, Kalender, Mehr (ab PLUS frei belegbar). Sie wechselt nie ihren Inhalt.
- Bereiche einer Seite (z. B. Kosten: Übersicht/Ist/Plan, Einstellungen) stehen als Reiter oben unter der Überschrift (`.view-tabs`).
- Startseite „Was steht an?“ zeigt höchstens 3 Punkte mit Ampel; die Glocke zählt dieselben Punkte.
