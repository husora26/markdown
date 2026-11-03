# Husora – Beta Release & App-Verteilung (Android + iOS)

Umsetzung der „Husora Beta Release & App Distribution Specification“ v1.0 (03.11.2026).
Rechtliche Angaben (Store-Datenschutz, Texte): **Entwurf – finale juristische Prüfung offen.**

## 0. Analyse und Grundentscheidung (Steps 1–5)

| Prüfpunkt | Ergebnis |
|---|---|
| Expo / React Native | **Nicht vorhanden.** Husora ist eine Web-App in einer Datei (`index.html`, Vanilla JS) auf GitHub Pages, Daten in Supabase. |
| Konsequenz | Statt Expo/EAS: **Capacitor 8** als native Hülle. Die bestehende `index.html` läuft unverändert in der App. Builds über **GitHub Actions** (übernimmt die Rolle von EAS Build/Submit). Das ist die Variante mit den wenigsten Änderungen; ein Neubau in React Native hätte Spec-Regel 1 verletzt. |
| App-Konfiguration | Bisher keine App-IDs. Neu: `com.husora.app` (Android `applicationId`, iOS `PRODUCT_BUNDLE_IDENTIFIER`). |
| Supabase | Ein Projekt `ggsoygxmcsmrsrbmplrz`, wird als **BETA** geführt. Live-Stand: Migrationen bis 3500 (3600–4500 noch einspielen). Production-Projekt existiert noch nicht. |
| Feedback / Datenschutz | Vorhanden (Beta Mode 3700, Compliance 4400). **Nicht neu gebaut**, nur angebunden: Umgebung `beta`, Plattform `android`/`ios`, Build-Nummer in Feedback, Fehlern und Ereignissen. |
| Konto löschen, Export, Offline-Hinweis, Rollenwahl im Onboarding, doppelte Uploads | Vorhanden. Uploads sind inhaltsadressiert (SHA-256 + Upsert), deshalb ohne Duplikate und wiederholbar. Weiterverwendet. |

Zuordnung der EAS-Profile aus der Spec:

| Spec-Profil | Husora |
|---|---|
| development | `node tools/build-app.mjs --env development` + lokaler Supabase-Stack, `npx cap run android/ios` |
| preview (intern, nicht Store) | GitHub Actions „Android Build“ bei jedem Push: Debug-APK als Artefakt; „iOS Build“: Simulator-Build |
| beta | Actions → *Run workflow* mit Umgebung `beta`: signiertes **AAB** → Play Closed Testing / **IPA** → TestFlight |
| production | dieselben Workflows mit Umgebung `production` (eigenes Supabase-Projekt, Release-Version ohne `-beta`) |

## A. Geänderte Dateien
| Datei | Änderung |
|---|---|
| `index.html` | Release-Modul (siehe unten); Version 1.0.0-beta.1 (Build 1); Beta-Kennzeichnung in Menü, Fußzeile, „Über Husora“, Hilfe; Laufzeit-Konfiguration statt fest verdrahteter Umgebung in App-Builds; Zeitlimits und verständliche Netzwerk-/Serverfehler; Fehlergrenze für Seiten; Sitzungsablauf-Hinweis; Auth-Rücksprung auch per App-Schema; Einladungstexte mit öffentlicher Web-Adresse; Manifest/Icons |
| `package.json`, `package-lock.json` | Capacitor-Pakete (feste Versionen), Skripte `version:*`, `build:web:*`, `cap:sync:*`, `secrets:check` |
| `.gitignore` | `.env*`, `www/`, Keystores, `.p8/.p12`, Dienstkonto-JSON, native Build-Ordner |
| `.github/workflows/tests.yml` | Versions- und Secret-Prüfung; Supabase-CLI fest auf 2.122.0 (CLI 3.0 lehnt `[inbucket]` ab) |
| `tests/e2e/run.sh` | neue Suite `release` |
| `supabase/husora_komplett.sql` | neu erzeugt (47 Migrationen) |
| `GO_NO_GO_REPORT.md` | Migration 4500 ergänzt |

## B. Neue Dateien
| Datei | Zweck |
|---|---|
| `version.json` | **zentrale Version** (`version`, `marketingVersion`, `build`, `date`) |
| `config/environments.json` | Umgebungen development/beta/production: App-Name, erwartete Server-Umgebung, zulässige Supabase-Projekte, öffentliche Web-Adresse |
| `.env.example`, `.env.beta.example`, `.env.production.example` | Vorlagen (nur öffentliche Werte) |
| `tools/build-app.mjs` | erzeugt `www/` je Umgebung, bettet `window.HUSORA_RUNTIME` ein, bricht bei Secrets, falschem Projekt oder Versionsabweichung ab, setzt App-Namen und Version in den nativen Projekten |
| `tools/version.mjs` | `check` (Konsistenz) · `bump [beta|release|patch|minor|major]` (Build-Nummer +1, nie zurück) |
| `tools/check-secrets.mjs` | Secret-Scan aller versionierten Dateien |
| `tools/generate-icons.py` | App-Icons/Splash aus `assets/logo.png` |
| `capacitor.config.json`, `android/`, `ios/` | native Projekte (Capacitor 8.5.3) |
| `ios/ExportOptions.plist` | Export/Upload zu App Store Connect |
| `.github/workflows/android.yml`, `ios.yml` | Build-, Signatur- und Upload-Pipeline |
| `manifest.webmanifest`, `assets/icons/*` | Web-App-Manifest, Icons |
| `beta.html` | Beta-Landingpage mit Buttons „Android Beta testen“ / „iPhone Beta testen“ (Links aus der Konfiguration), Erklärung, Version, Datenschutz, Support, Feedback, Einladungscode aus `?invite=` |
| `supabase/migrations/20261030004500_beta_release.sql` | siehe D |
| `supabase/tests/beta_release_test.sql` | 70 Prüfungen (Mandanten-Matrix inkl. Storage, Beta-Funktionen) |
| `tests/e2e/release.js` | 16 Browser-Schritte (Web, App-Build, simulierte native App, Admin) |
| `store/google-play.md`, `store/app-store-connect.md`, `store/listing-de.md` | Store-Unterlagen (H, I) |

**Release-Modul in `index.html`:**
- **Umgebungswächter:** App-Builds sprechen nur mit dem eingebauten Projekt. Vor dem ersten Cloud-Zugriff vergleichen sie `app_config.environment` mit der erwarteten Umgebung. Passt sie nicht, erscheint ein Sperrbildschirm und es werden keine Daten übertragen.
- **Wartung und Mindest-Build:** Wartungshinweis oder -sperre sowie „Update erforderlich“ mit Store-Link, gesteuert über die Konfiguration (ohne neuen Build).
- **Version melden:** Beim Start und Login meldet die App Version, Build, Plattform und Umgebung (`report_app_session`).
- **Rollen:** Nach dem Login wird die Rolle geprüft. Ein reines Servicepartner-Konto landet im Partner-Portal.
- **Einladungscode:** eigener Dialog sowie Übernahme aus `?invite=` und aus dem App-Link `com.husora.app://beta?invite=`.
- **Native Funktionen:**
  - Deep Links und Auth-Rücksprung `com.husora.app://auth`
  - Android-Zurück-Taste
  - Downloads, Datenexport und PDFs über Speichern/Teilen
  - externe Links im System-Browser
  - kein Web-Push und kein Stripe-Kauf in der App
- **Admin-Bereich:** Beta-Tester (pseudonymisiert), Einladungscodes, Tester markieren, Release-Links, Mindest-Builds, Einladungspflicht, Wartung.

## C. Neue Environment Variables
| Variable | Wo | Inhalt |
|---|---|---|
| `APP_ENV` | `.env.<env>` / CI | `beta` · `production` · `development` (muss zu `--env` passen) |
| `HUSORA_PUBLIC_SUPABASE_URL` (Alias `EXPO_PUBLIC_SUPABASE_URL`) | `.env.<env>` / GitHub-Environment-**Variable** | Projekt-URL |
| `HUSORA_PUBLIC_SUPABASE_ANON_KEY` (Alias `EXPO_PUBLIC_SUPABASE_ANON_KEY`) | dto. | publishable/anon-Schlüssel (öffentlich; RLS schützt) |
| `APP_VERSION` | optional | muss `version.json` entsprechen, sonst Abbruch |
| `API_BASE_URL` | optional | Standard = Supabase-URL |
| `HUSORA_PUBLIC_WEB_URL`, `HUSORA_SUPPORT_EMAIL` | optional | Einladungslinks / Support |
| `HUSORA_PRODUCTION_SUPABASE_URL` / `HUSORA_BETA_SUPABASE_URL` | optional | Gegen-URL: Build bricht ab, wenn Beta auf Production zeigt (und umgekehrt) |
| **Secrets** (GitHub → Settings → Environments → `beta`/`production`) | | `HUSORA_UPLOAD_KEYSTORE_BASE64`, `HUSORA_UPLOAD_KEYSTORE_PASSWORD`, `HUSORA_UPLOAD_KEY_ALIAS`, `HUSORA_UPLOAD_KEY_PASSWORD`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`, `APPLE_TEAM_ID` |

Service-Role- und andere geheime Schlüssel gehören nie in die App. `build-app.mjs` und `check-secrets.mjs` brechen in diesem Fall ab.

**„Beta nie gegen Production“** ist dreifach abgesichert:
1. Der Build lehnt Projekte ab, die in `config/environments.json` einer anderen Umgebung gehören, sowie die Gegen-URL.
2. Die Laufzeit überschreibt gespeicherte fremde Projekte.
3. Der Server meldet seine Umgebung (`app_config.environment`, nur per SQL änderbar), und die App sperrt bei Abweichung.

## D. Supabase-Migrationen
`20261030004500_beta_release.sql` (idempotent, nach 3600–4400 einspielen):
1. `users`: `tester_group` (homeowner/service_partner/internal), `app_platform`, `last_app_version`, `last_app_build`, `last_environment`, `last_seen_at`, `beta_invite_id`. Die Spec-Felder `is_beta_tester`/`beta_joined_at` gab es bereits als `is_beta_user`/`beta_started_at`. Die Felder sind gegen Selbständerung geschützt.
2. `app_config`: `environment` (Standard `beta`, aus der App nie änderbar), `maintenance`, `release` (Store-Links, Mindest-Build, Einladungspflicht, Support).
3. `beta_invites`, `beta_invite_redemptions`, `beta_invite_attempts`:
   - Codes werden nur als SHA-256-Hash gespeichert.
   - Höchstens 10 Fehlversuche pro Stunde.
   - Serverseitige Sperre: Bei aktiver Einladungspflicht kann ohne Code keine Organisation angelegt werden.
4. RPCs: `report_app_session`, `my_beta_status` (Rollen), `redeem_beta_invite`, `beta_invite_create`, `beta_invite_set_active`, `admin_set_beta_tester`, `beta_testers_overview` (pseudonymisiert). Admin-RPCs erfordern Admin-Rolle und MFA; alle Admin-Aktionen landen im Sicherheits-Audit-Log.
5. Umgebung `beta` in `app_feedback`/`analytics_events`/`track_events` zulässig. Die Einwilligungsprüfung bleibt erhalten.

**Für Production:** neues Projekt anlegen und alle Migrationen einspielen (`supabase db push` oder `husora_komplett.sql`). Danach einmalig:
`update public.app_config set value = '{"name": "production"}' where key = 'environment';`

**Supabase Beta – Auth-Einstellungen (Dashboard):**
- Site URL `https://husora26.github.io/markdown/`
- Redirect URLs: `https://husora26.github.io/markdown/**`, `com.husora.app://**`
- eigener SMTP-Server
- MFA (TOTP) an
- Leaked-Password-Protection an

## E. EAS-/Build-Konfiguration (Capacitor + GitHub Actions)
- `capacitor.config.json`: `appId com.husora.app`, `webDir www`, https-Schema, kein Mixed Content, WebView-Debugging aus.
- Android (`android/app/build.gradle`): `versionCode` = `version.json.build`, `versionName` = `version.json.version`. Signatur über Umgebungsvariablen oder `android/keystore.properties` (ignoriert). Keine Cloud-Sicherung der App-Daten. Deep-Link-Schema. Berechtigungen nur Internet und Netzwerkstatus.
- iOS (`ios/App`): Swift Package Manager (keine CocoaPods). URL-Schema, Kamera-/Foto-Begründungen, `ITSAppUsesNonExemptEncryption=false`. Version wird beim Build aus `version.json` gesetzt.
- Workflows:
  - `android.yml`: Push → Debug-Prüf-Build. Manuell → signiertes AAB und Upload in Track `internal`/`alpha`.
  - `ios.yml`: Push → Simulator-Build. Manuell → Archiv und Upload zu TestFlight.
- Versionierung: `npm run version:bump` (Beta n+1, Build +1) → Commit → Workflow starten. Die Build-Nummer wird nie zurückgesetzt.

## F. Android-Release-Anleitung
1. Einmalig: Upload-Schlüssel erzeugen (`store/google-play.md` §1) und Secrets in GitHub-Environment `beta` anlegen: `base64 -w0 husora-upload.jks` → `HUSORA_UPLOAD_KEYSTORE_BASE64`.
2. `npm run version:bump` → committen und pushen.
3. GitHub → Actions → **Android Build** → *Run workflow*: Umgebung `beta`, Track `none` → AAB als Artefakt herunterladen → **erstes AAB manuell** in der Play Console (Geschlossener Test) hochladen.
4. Ab dem zweiten Build: Track `alpha` (Closed Testing) bzw. `internal` → Upload automatisch.
5. Opt-in-Link aus der Play Console in Husora Admin → „Release & Wartung“ eintragen.

## G. iOS/TestFlight-Anleitung
1. Einmalig: App in App Store Connect anlegen und API-Schlüssel erzeugen (`store/app-store-connect.md` §1). Secrets `ASC_*` und `APPLE_TEAM_ID` setzen.
2. `npm run version:bump` → pushen.
3. GitHub → Actions → **iOS Build** → *Run workflow*: Umgebung `beta`, Upload an → Build erscheint nach der Verarbeitung (ca. 10–30 Min.) in TestFlight.
4. Zuerst interne Tester, dann externe Gruppe (Beta App Review). Den öffentlichen TestFlight-Link in Husora Admin eintragen.
5. Alternativ lokal auf einem Mac: `npm ci && npm run cap:sync:beta && npx cap open ios` → Xcode → Product → Archive → Distribute.

## H. Google-Play-Setup-Checkliste
Siehe `store/google-play.md`: Konto, App, Play App Signing, Upload-Schlüssel, Dienstkonto, Store-Eintrag, App-Zugriff (Testkonto), Einstufung, Zielgruppe, Data Safety (Entwurf), Kontolöschung, Berechtigungen, Target SDK 36, Tester-Liste, Closed-Testing-Track.

## I. App-Store-Connect-Setup-Checkliste
Siehe `store/app-store-connect.md`: Developer Program, Bundle ID, App-Datensatz, API-Schlüssel, TestFlight-Texte (Beschreibung, Was testen, Feedback, Kontakt, Testzugang), App Privacy (Entwurf, kein Tracking), Altersfreigabe, Exportkonformität, Anmelde-/Löschpflicht, keine In-App-Käufe in der Beta, Richtlinie 4.2.

## J. Security-Test-Ergebnis (Spec §26)
| Prüfpunkt | Ergebnis |
|---|---|
| RLS überall aktiv | ✔ (Security-Advisor und `security_test.sql`; neue Tabellen mit RLS, Schreiben nur über RPCs) |
| Keine Service-Role-Keys im Client | ✔ (Build-Prüfung, Laufzeit-Prüfung in `cloudConnect`, Secret-Scan) |
| Keine Secrets in Git / öffentlichen Variablen | ✔ `tools/check-secrets.mjs` (läuft im CI) |
| Storage-Policies | ✔ Upload, Download, Update und Delete mandantenübergreifend blockiert, Viewer ohne Schreibrecht (`beta_release_test.sql`) |
| Auth-Redirects | ✔ Web und App-Schema; Einträge im Supabase-Dashboard → offen (siehe D) |
| Rollen serverseitig | ✔ `my_beta_status` aus Mitgliedschaften; Admin nur mit Rolle und MFA; Admin nicht selbst registrierbar |
| Nutzer-/Servicepartner-Isolation | ✔ SQL-Matrix (Hausbesitzer A↔B, Partner A↔B, Hausmitglied) |
| Konto löschen | ✔ SQL (Löschung inkl. Beta-Daten) und bestehende E2E-Suite `legal` |
| Passwort-Reset / Sitzungsablauf | ✔ Code-Pfad (Recovery über Web und App-Schema, Ablauf → Hinweis und neue Anmeldung); **auf echten Geräten mit echtem SMTP noch testen** |
| Upload-Sicherheit | ✔ private Buckets mit Größen- und Typgrenzen, Pfadprüfung, keine Duplikate |

## K. Beta-Test-Ergebnis (automatisiert)
- SQL auf frischer Datenbank (47 Migrationen + Seed): **17 Dateien fehlerfrei**, davon `beta_release_test.sql` 70 Prüfungen
- Browser-E2E `release`: **16/16** (siehe unten), Gesamtlauf siehe Commit-Nachricht
- GitHub Actions: **Android-Prüf-Build ✔, iOS-Simulator-Build ✔** (Capacitor-Projekte bauen)

Diese PASS-Ergebnisse ersetzen keine Tests auf echten Geräten und keine juristische Prüfung (Spec §28, Compliance §43).

## L. Offene Punkte (außerhalb des Codes)
1. ~~Live-Datenbank: Migrationen 3600–4500 einspielen~~ – **erledigt am 03.11.2026** (alle Tabellen/Funktionen vorhanden, TRUNCATE gesperrt, Umgebung `beta`).
2. **Supabase-Dashboard:** Redirect-URLs inkl. `com.husora.app://**`, eigener SMTP-Server (sonst erhalten externe Tester keine Mails), MFA, Leaked-Password-Protection, AV-Vertrag.
3. **Konten:** Google Play Developer, Apple Developer Program, Upload-Schlüssel, API-Schlüssel, GitHub-Secrets.
4. **Store-Material:** hochauflösendes Logo (aktuell aus 240-px-Vorlage hochskaliert), Screenshots, Feature-Grafik, Demo-Konto für die Reviews.
5. **Production-Projekt** in Supabase (später) plus Eintrag in `config/environments.json` → `production.projectRefs`.
6. **Gerätetests** nach §27/§28 (Checkliste unten) und Release Candidate: nach bestandenem internen Test `git tag v1.0.0-beta.1 && git push origin v1.0.0-beta.1`.
7. Optional: Universal/App Links. Dafür müssen `apple-app-site-association` und `assetlinks.json` im Stamm `husora26.github.io/.well-known/` liegen (anderes Repository). Bis dahin genügt das App-Schema.
8. Branch-Strategie `develop` → `beta` → `main` und Branch-Schutz in GitHub einrichten (empfohlen, nicht erzwungen).

## M. Bekannte Risiken
- **Apple Richtlinie 4.2:** Web-Inhalte in nativer Hülle können als „Minimalfunktion“ abgelehnt werden. Gegenmaßnahmen: native Kamera/Teilen/Deep Links; native Push als Nächstes.
- **Push in der App:** Web-Push funktioniert in der App nicht. Es gibt E-Mail und In-App-Hinweise; native Push (FCM/APNs) fehlt noch.
- **Lokale Daten (local-first):** Daten liegen im WebView-Speicher. Bei Neuinstallation sind sie ohne Cloud-Abgleich weg. Tester sollen die Cloud aktivieren.
- **Drucken** in der App nur über „PDF teilen“.
- **App-Icon** aus niedrig aufgelöster Vorlage.
- **npm audit:** 3 mittlere Hinweise in der Build-CLI (`@capacitor/cli` → glob/minimatch/uuid). Betrifft nur Build-Werkzeuge, nicht die App.
- Store-Datenschutzangaben sind Entwürfe: **juristische Prüfung offen**.

## N. Befehle
```bash
# Lokale Entwicklung
npm ci
npm run db:start                     # lokaler Supabase-Stack (Docker)
npm run dev                          # Web-App unter http://localhost:8080
cp .env.beta.example .env.beta       # öffentliche Beta-Werte
npm run cap:sync:beta                # www/ bauen + in Android/iOS kopieren
npx cap run android                  # Emulator/Gerät (Android Studio/SDK nötig)
npx cap open ios                     # Xcode (nur macOS)

# Prüfen
npm run release:check                # Version konsistent + Secret-Scan
bash tests/e2e/run.sh release        # Browser-Test Beta-Release

# Version erhöhen (vor jedem Store-Build)
npm run version:bump                 # 1.0.0-beta.1 → 1.0.0-beta.2, Build +1

# Beta-Build Android (lokal, mit Upload-Schlüssel in android/keystore.properties)
npm run cap:sync:beta && (cd android && ./gradlew bundleRelease)
#   → android/app/build/outputs/bundle/release/app-release.aab
# Beta-Build iOS (macOS)
npm run cap:sync:beta && npx cap open ios   # Product → Archive

# Submission (GitHub Actions, empfohlen)
#   Android: Actions → „Android Build“ → Run workflow → environment=beta, track=alpha
#   iOS:     Actions → „iOS Build“     → Run workflow → environment=beta, upload=true
```

## Android-Test-APK (ohne Store)
Der Workflow `.github/workflows/android-test-apk.yml` baut bei jeder App-Änderung automatisch eine Test-APK (Beta-Umgebung) und stellt sie unter einer festen Adresse bereit:
**https://github.com/husora26/markdown/releases/download/android-test/husora-beta-test.apk**
Installation: Link auf dem Android-Handy öffnen → APK öffnen → „Installation aus unbekannten Quellen“ erlauben. Debug-Signatur: bei einem Update ggf. alte Version zuerst deinstallieren. Nur für interne Tests, nicht für Google Play.

## Manuelle Release-Checkliste (Spec §27, §28, §37)
**Auth:** [ ] Registrierung · [ ] E-Mail bestätigen (Link öffnet die App) · [ ] Login · [ ] Logout · [ ] Passwort vergessen (Link öffnet die App) · [ ] Passwort ändern · [ ] Sitzung bleibt nach Neustart · [ ] Sitzungsablauf → Hinweis
**Hausbesitzer:** [ ] Profil · [ ] Haus anlegen/bearbeiten · [ ] Aufgaben · [ ] Hauskontrolle · [ ] Fotos (Kamera + Galerie) · [ ] Dokumente (Upload, Öffnen, Teilen) · [ ] Serviceanfrage · [ ] Partnerkontakt
**Servicepartner:** [ ] Registrierung (landet im Partner-Portal) · [ ] Unternehmensprofil · [ ] Leistungen · [ ] Servicegebiet · [ ] Hausservice · [ ] Hauskontrolle · [ ] Aufträge · [ ] Status ändern · [ ] Fotos · [ ] Kundenbezug
**Cloud:** [ ] Speichern/Laden · [ ] Foto/Dokument-Upload · [ ] Löschen · [ ] Flugmodus: App startet, Hinweis, später Abgleich ohne Doppelungen
**Geräte:** [ ] kleines/normales Android, aktuelles und älteres Android (≥ 7.0) · [ ] kleines/aktuelles iPhone, ältere iOS-Version (≥ 15) · [ ] Tastatur, Scrollen, Dark Mode, Zurück-Taste
**Beta:** [ ] Landingpage-Links · [ ] Einladungscode · [ ] Feedback/🐞 kommt im Admin an · [ ] Version im Admin sichtbar · [ ] 5–10 interne Tester → 20–50 externe
**Final:** [ ] P0 = 0 · [ ] P1 = 0 · [ ] Backup/PITR geprüft · [ ] Release Candidate `v1.0.0-beta.1` getaggt

Fehlerpriorität (Spec §31): **P0** sofort (Login defekt, fremde Daten sichtbar, Datenverlust, App startet nicht) · **P1** vor dem nächsten Beta-Build · **P2** Beta-Backlog · **P3** später. Im Admin über den Status der Fehlerberichte steuern.
