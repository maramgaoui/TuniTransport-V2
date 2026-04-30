# Sprint Analysis Report — Fix Idempotency Issues

**Date:** 2026-04-30
**Analyst:** Claude Code

---

## 1. What Was Scanned

- All 17 `scripts/data/transtu*.json` files (175 station entries, 232 route entries)
- `lib/services/firestore_initialization_service.dart` (in-app seeder)
- `scripts/seed_transtu.js` (external admin seeder)
- `lib/services/bus_service_repository.dart` (consumer of seeded data)
- `scripts/firebase_admin_init.js` and `scripts/package.json`

---

## 2. Root Causes Found

### 2.1 — Two seeding paths, incompatible doc ID schemes (HIGH)

`FirestoreInitializationService` runs on every cold app start and writes:

| Collection    | Doc ID scheme          | Example                          |
|---------------|------------------------|----------------------------------|
| `stations`    | `transtu_hub_*`        | `transtu_hub_barcelone`          |
| `bus_services`| `transtu_line_<num>`   | `transtu_line_44`                |
| `route_stops` | **random** (`add()`)   | `<auto-id>`                      |

`scripts/seed_transtu.js` writes to the same collections with:

| Collection    | Doc ID scheme                          | Example                                          |
|---------------|----------------------------------------|--------------------------------------------------|
| `stations`    | same `transtu_*` IDs                   | `transtu_hub_tunis_marine`                       |
| `bus_services`| `bus_svc_<routeId>`                    | `bus_svc_route_transtu_tunis_marine_ligne5`      |
| `route_stops` | `<routeId>_stop_<order>_<stationId>`   | `route_transtu_..._stop_1_transtu_hub_*`         |

**Effect:**
- `bus_services` accumulates docs from both sources. `BusServiceRepository` queries by `hubStationId` field and returns all matching docs → doubled/inconsistent results.
- `route_stops` auto-ID entries from the app accumulate on every cold start where `stations.count() == 0` is briefly true.

### 2.2 — 16 duplicate station definitions across JSON files, 8 inconsistent (HIGH)

Stations that appear in multiple files with different data:

| Station ID                        | Files                                              | Issue                                                                |
|-----------------------------------|----------------------------------------------------|----------------------------------------------------------------------|
| `transtu_dest_kalaat_alandalous`  | `transtu10dec`, `transtuariana`, `transtubelhouanel`, `transtuintileka`, `transtumarine` | Coordinates differ: `(36.92, 10.12)` × 4 vs `(37.091, 10.081)` in marine |
| `transtu_dest_charguia`           | `transtubebalioua`, `transtumarine`, `transtutbourba` | Name: `"El Charguia"` vs `"Charguia"`; 3 different coordinate pairs |
| `transtu_dest_omrane_superieur`   | `transtubebalioua`, `transtubelhouanel`, `transtumarine` | 3 different lat/lng values                                          |
| `transtu_hub_intilaka`            | `transtuintileka`, `transtumarine`                 | Arabic name typo: `"الانطالقة"` vs `"الانطلاقة"`                   |
| `transtu_dest_tebourba`           | `transtubebalioua`, `transtuslimane`               | Two entirely different stations sharing the same ID                  |
| `transtu_dest_cite_bassatine`     | `transtubelhouanel`, `transtuslimane`              | Name: `"Cité Bassatine"` vs `"Cité El Bassatine"`                  |
| `transtu_dest_raoued_plage`       | `transtucharguia`, one other                       | Consistent data — safe duplicate (use merge)                         |
| `transtu_hub_carthage`            | `transtucarthage`, one other                       | Consistent data — safe duplicate (use merge)                         |

### 2.3 — `seed_transtu.js` hardcoded service account path (MEDIUM)

Line 14 of `seed_transtu.js`:
```js
const serviceAccount = require('C:/Users/Snaws/Desktop/serviceAccount.json.json');
```
This fails on any machine that is not the original developer's. A portable `firebase_admin_init.js` already exists and uses `GOOGLE_APPLICATION_CREDENTIALS` env var, but `seed_transtu.js` does not use it.

### 2.4 — `cleanup_transtu_all.js` is missing (MEDIUM)

`package.json` defines:
```json
"reseed-transtu": "npm run cleanup-transtu && npm run seed-transtu"
```
But `cleanup_transtu_all.js` does not exist. This command will crash immediately with `MODULE_NOT_FOUND`.

### 2.5 — Separation of concerns: app owns data it should not (LOW, but structural)

The Flutter app should not be responsible for seeding production transport data. `FirestoreInitializationService` was likely added as a convenience shortcut early in development. Its `isInitialized` guard (`stations.count() > 0`) means it silently skips if scripts have run — but the opposite is also true: if the app runs first, it seeds a stale partial dataset that then permanently coexists with the real script data.

---

## 3. Sub-Sprints

### Sub-Sprint A — Fix `seed_transtu.js` portability
**Files:** `scripts/seed_transtu.js`, and audit all other `scripts/seed_*.js`
**Work:**
- Replace `require('C:/Users/.../serviceAccount.json.json')` with `firebase_admin_init.js`
- Confirm all other seed scripts also use `firebase_admin_init.js` (or fix them)
- Add `scripts/.env.example` documenting `GOOGLE_APPLICATION_CREDENTIALS` and `FIREBASE_PROJECT_ID`

### Sub-Sprint B — Create `cleanup_transtu_all.js`
**Files:** `scripts/cleanup_transtu_all.js` (new)
**Work:**
- Delete all docs in: `stations` (prefix `transtu_`), `routes` (prefix `route_transtu_`), `bus_services` (both `transtu_line_*` and `bus_svc_route_transtu_*`), `route_stops` (field `routeId` starts with `route_transtu_`), `trips` (field `routeId` starts with `route_transtu_`)
- Use `firebase-admin` batched deletes (500-doc limit)
- Use `firebase_admin_init.js`

### Sub-Sprint C — Canonicalize duplicate stations in JSON files
**Files:** `scripts/data/*.json`
**Work:**
- For consistent duplicates (`transtu_hub_carthage`, `transtu_dest_raoued_plage`, etc.): remove the duplicate entry from one file, keep in the authoritative file.
- For inconsistent duplicates: pick one canonical value (requires ground-truth decision — see open questions below) and remove from all other files.
- Special case `transtu_dest_tebourba`: assign a new unique ID to the `transtuslimane` definition ("Borj El Amri via Tebourba").

**Open questions (need developer input):**
1. `transtu_dest_kalaat_alandalous`: correct coordinates — `(36.92, 10.12)` or `(37.091, 10.081)`?
2. `transtu_dest_charguia`: canonical name — `"El Charguia"` or `"Charguia"`? Coordinates?
3. `transtu_dest_omrane_superieur`: which of the three coordinate sets is correct?
4. `transtu_dest_tebourba` in `transtuslimane.json`: what should the new ID be for "Borj El Amri via Tebourba"?

### Sub-Sprint D — Remove `FirestoreInitializationService` (in-app seeder)
**Files:** `lib/services/firestore_initialization_service.dart`, `lib/main.dart`
**Work:**
- Delete `FirestoreInitializationService` class and file
- Remove the `initialize()` call in `main.dart`
- Add a `kDebugMode` log to `main.dart` warning if `stations` collection is empty (developer hint to run seed scripts)
- Update `CLAUDE.md`

### Sub-Sprint E — Verify `BusServiceRepository` doc ID independence
**Files:** `lib/services/bus_service_repository.dart`
**Work:**
- Confirm `findServicesConnectingStations()` queries only by `hubStationId`/`destinationStationId` field values, not doc IDs
- After Sub-Sprint D removes `transtu_line_*` docs and C cleans duplicates, run a quick Firestore query test

---

## 4. Recommended Execution Order

```
A (portability) → B (cleanup script) → D (remove in-app seeder) → C (canonicalize JSON) → E (verify)
```

A and B are pure scripts work, no Flutter code touched.
D is safe once B exists (cleanup + reseed validates the result).
C requires ground-truth sign-off before execution.
E is a read-only verification step.
