# How to Run TuniTransport

## Step 1 — Install Flutter

1. Download Flutter SDK: https://docs.flutter.dev/get-started/install/windows
2. Extract to e.g. `C:\flutter`
3. Add `C:\flutter\bin` to your system `PATH`
4. Verify: `flutter doctor`

Fix everything `flutter doctor` flags (Android SDK, Android licenses, etc.) before continuing.

---

## Step 2 — Firebase config file (one-time, gitignored)

`lib/firebase_options.dart` is not in the repo. You must generate it.

```bash
# Install FlutterFire CLI once
dart pub global activate flutterfire_cli

# Generate the config (run from repo root)
flutterfire configure \
  --project=tuni-transport-20eaf \
  --out=lib/firebase_options.dart \
  --platforms=android,ios,web,macos,windows
```

This requires you to be logged into Firebase CLI:
```bash
npm install -g firebase-tools
firebase login
```

---

## Step 3 — Install Flutter dependencies

```bash
# From repo root
flutter pub get
```

---

## Step 4 — Seed Firestore data (one-time per environment)

The app needs transport data in Firestore before it can search journeys.

```bash
cd scripts
npm install
```

Create a service account key for the Firebase project:
- Go to Firebase Console → Project Settings → Service Accounts → Generate new private key
- Save the downloaded file somewhere safe (NOT inside the repo)

Then set the env var and run:

```bash
# Windows CMD
set GOOGLE_APPLICATION_CREDENTIALS=C:\path\to\your-service-account.json
set FIREBASE_PROJECT_ID=tuni-transport-20eaf

# Seed all TRANSTU bus data
node seed_transtu.js

# Seed train/metro lines
node seed_metro_sahel.js
node seed_banlieue_sud.js
node seed_banlieue_nabeul.js
node seed_line_d.js
node seed_line_e.js
node seed_sncft_line5.js
node seed_grandes_lignes.js
```

To reseed from scratch (wipe + reseed TRANSTU):
```bash
# Note: cleanup_transtu_all.js is currently missing — see analysis_report.md Sub-Sprint B
npm run reseed-transtu
```

---

## Step 5 — Run the app

Connect an Android device or start an emulator, then:

```bash
flutter run
```

To run on a specific device:
```bash
flutter devices          # list available devices
flutter run -d <device-id>
```

---

## Step 6 — Deploy Firestore security rules (when changed)

```bash
firebase deploy --only firestore:rules
```

---

## Daily development commands

```bash
flutter analyze          # static analysis
flutter test             # unit tests
flutter pub get          # after pubspec.yaml changes
flutter gen-l10n         # after editing lib/l10n/*.arb files
```

---

## Integration tests (optional, requires live Firebase credentials)

```bash
flutter test integration_test/auth_flow_test.dart \
  --dart-define=IT_RUN_AUTH_FLOW=true \
  --dart-define=IT_USER_EMAIL=your@email.com \
  --dart-define=IT_USER_PASSWORD=yourpassword \
  --dart-define=IT_ADMIN_MATRICULE=xxxx \
  --dart-define=IT_ADMIN_PASSWORD=xxxx
```

---

## Android release build

Requires `android/key.properties`:
```
storeFile=/absolute/path/to/keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Then:
```bash
flutter build apk --release
```
