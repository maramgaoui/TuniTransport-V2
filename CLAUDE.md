# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies
flutter pub get

# Run the app (Android/iOS device or emulator)
flutter run

# Static analysis
flutter analyze

# Unit tests
flutter test

# Run a single test file
flutter test test/path/to/file_test.dart

# Integration tests (require live Firebase — disabled by default unless env vars are set)
flutter test integration_test/auth_flow_test.dart \
  --dart-define=IT_RUN_AUTH_FLOW=true \
  --dart-define=IT_USER_EMAIL=... \
  --dart-define=IT_USER_PASSWORD=...

# Regenerate Firebase config (after key rotation)
flutterfire configure --project=tuni-transport-20eaf --out=lib/firebase_options.dart --platforms=android,ios,web,macos,windows

# Deploy Firestore rules
firebase deploy --only firestore:rules

# Android release build (requires android/key.properties)
flutter build apk --release
```

## Architecture

TuniTransport is a Flutter app for public transport route search in Tunisia (TRANSTU bus, Métro du Sahel, Banlieue trains, SNCFT). The backend is Firebase (Firestore + Auth + FCM).

### Initialization sequence (`lib/main.dart`)

1. Firebase is initialized via `FirebaseRuntimeOptions.currentPlatform` — in normal builds this falls back to `DefaultFirebaseOptions`; integration tests can override it with `TEST_FIREBASE_*` dart-define env vars.
2. `FirestoreInitializationService` seeds TRANSTU hub stations, destinations, and bus routes into Firestore if the `stations` collection is empty.
3. `SettingsService` restores persisted theme/language/last-route preferences.
4. `setupServiceLocator()` registers `get_it` singletons: `FirebaseFirestore`, `BusServiceRepository`, `StationRepository`, `SettingsService`.

### Routing (`lib/router/app_router.dart`)

Navigation uses `go_router`. All `/home/*` tab paths render the same `HomeScreen` widget, which derives the active tab from the URL. The router's `redirect` callback handles:
- Unauthenticated → `/auth`
- Admin user → `/admin`
- Regular user → `/home/journey-input`
- Route restoration: the last restorable route is persisted via `SettingsService` and restored on next app open.

### Auth (`lib/controllers/auth_controller.dart`)

`AuthController` is a manual singleton (`AuthController.instance`). It wraps Firebase Auth + Firestore and adds:
- **Session caching**: in-memory (5 min TTL) + `SharedPreferences` fallback. Survives transient Firestore offline errors.
- **Role resolution**: admin users are keyed by UID in the `admins` collection. A fallback email-lookup auto-migrates legacy admins to UID-keyed documents.
- **Ban/block enforcement**: `status` field on the `users` document. Expired bans are auto-cleared. Blocked users are signed out immediately.
- A real-time listener on the user's `users` document invalidates the session cache when `status` changes.

For tests, inject a fake with `AuthController.resetInstance(controller)`.

### Journey search (`lib/controllers/journey_search_controller.dart`)

`JourneySearchController` (a `ChangeNotifier`) drives the search UI. Its `search()` method runs branching logic — **branch order matters and must not be reordered**:

1. **Banlieue Nabeul** (`bn_*` station IDs) — checked first as a priority override
2. **Métro du Sahel** (`ms_*`)
3. **Banlieue Sud** (`bs_*`)
4. **Banlieue Ligne D** (`bd_*`)
5. **Banlieue Ligne E** (`be_*`)
6. **SNCFT Grandes Lignes** (`sncft_*`)
7. **TRANSTU bus** — departure must be a TRANSTU hub station

Station IDs may have legacy aliases (e.g. `sncft_bir_bou_regba` → `bn_bir_bou_regba`). Normalization runs in `_normalizeBnLegacyStationId()` before branch selection. The shared `bs_tunis_ville` / `bn_tunis` hub is also remapped depending on which network the peer station belongs to.

Results are emitted as `JourneySearchState` (immutable, `copyWith`-based).

### Transport data model

- **`MetroSahelResult`** — used for all train/metro results (Métro du Sahel, Banlieue, SNCFT). Has a `toJourney()` converter for favorites/active-journey compatibility.
- **`Journey`** — used for TRANSTU bus results and favorites storage.
- **`BusService`** — TRANSTU bus line with hub/suburb departure times.
- **`Station`** — has `operatorsHere` and `transportTypes` arrays; `StationRepository` uses these to classify stations into network branches.

### Service layer

| File | Responsibility |
|---|---|
| `StationRepository` | Firestore station reads + in-memory 10-min cache; fuzzy station name search with alias map |
| `JourneyRepository` | Finds next departure for each line type using `route_stops` and `trips` Firestore collections |
| `BusServiceRepository` | TRANSTU bus: finds services connecting two stations; `isTranstuHub()` helper |
| `RouteRepository` | Resolves `routeId` from `(fromStation, toStation)` pair for train lines |
| `NotificationService` | FCM setup + local notifications |
| `ActiveJourneyService` | Persists and tracks the user's ongoing journey |
| `FavoritesService` | Reads/writes favorites subcollection under `users/{uid}/favorites` |

### Admin panel (`lib/admin/`)

Separate screen tree under `/admin/*`. Admin role is determined by presence of a UID-keyed document in the `admins` Firestore collection. The `admins` collection is **read-only from the client** (`allow write: if false` in `firestore.rules`).

### Localization

Three locales: `en`, `fr` (default), `ar`. ARB files live in `lib/l10n/`. Generated Dart files are committed (`app_localizations*.dart`). Run `flutter gen-l10n` or `flutter pub get` to regenerate after editing ARB files.

### Firebase config & secrets

`lib/firebase_options.dart` is **not tracked in git**. Regenerate it with `flutterfire configure` after cloning or after key rotation. See `docs/firebase_key_rotation_runbook.md` for the full rotation procedure.

Firestore persistence is intentionally disabled in `main.dart` to avoid stale data issues.

### Integration tests

Both integration test files are **disabled by default** and require dart-define flags to run:
- `IT_RUN_AUTH_FLOW=true` enables `auth_flow_test.dart`
- `IT_RUN_DATA_FLOW=true` enables `journey_data_flow_test.dart`

Credentials are passed via dart-define (`IT_USER_EMAIL`, `IT_USER_PASSWORD`, `IT_ADMIN_MATRICULE`, etc.).

### Android release signing

Requires `android/key.properties` with `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. The Gradle build fails fast if the keystore file is missing. Do not use debug signing for release builds.
