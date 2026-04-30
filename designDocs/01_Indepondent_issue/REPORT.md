# Sprint Report — Fix Idempotency Issues
**Project:** TuniTransport V2  
**Sprint:** 01 — Independent Issues  
**Date:** 2026-04-30  
**Status:** Analysis complete, implementation pending  

---

## Executive Summary

The project has **two independent seeding pipelines** writing to the same Firestore collections using incompatible document ID schemes. This produces duplicate and inconsistent documents every time either pipeline runs, making Firestore data unreliable. Additionally, 17 JSON data files contain 16 cross-file duplicate station definitions — 8 of which carry conflicting coordinate or name data. Five sub-sprints are proposed to resolve all issues without touching business logic.

---

## 1. System Components Scanned

| Component | Path | Role |
|---|---|---|
| Flutter app seeder | `lib/services/firestore_initialization_service.dart` | Seeds TRANSTU data on cold app start |
| Node.js seed scripts | `scripts/seed_transtu.js` + 9 others | Admin tool for seeding all transport data |
| TRANSTU data files | `scripts/data/transtu*.json` (17 files) | Source of truth for bus routes and stations |
| Bus service repository | `lib/services/bus_service_repository.dart` | App reads `bus_services` collection at runtime |
| Firebase Admin init | `scripts/firebase_admin_init.js` | Portable credential helper (exists, underused) |
| Script manifest | `scripts/package.json` | Defines `npm run` commands |

**Data volume scanned:** 175 station entries, 232 route entries, 410 routeStops entries across 17 JSON files.

---

## 2. Issues Found

### Issue 1 — Dual seeding paths with incompatible doc ID schemes *(Severity: HIGH)*

Two separate systems write to the same Firestore collections, using different document ID schemes:

**`FirestoreInitializationService` (Flutter app — runs on cold start):**

| Collection | Doc ID pattern | Example |
|---|---|---|
| `stations` | `transtu_hub_*` | `transtu_hub_barcelone` |
| `bus_services` | `transtu_line_<N>` | `transtu_line_44` |
| `route_stops` | `add()` — **random auto-ID** | `<firebase-auto-id>` |

**`scripts/seed_transtu.js` (Node.js admin tool):**

| Collection | Doc ID pattern | Example |
|---|---|---|
| `stations` | `transtu_hub_*` / `transtu_dest_*` | `transtu_hub_tunis_marine` |
| `bus_services` | `bus_svc_<routeId>` | `bus_svc_route_transtu_tunis_marine_ligne5` |
| `route_stops` | `<routeId>_stop_<order>_<stationId>` | `route_transtu_..._stop_1_transtu_hub_*` |

**Consequences:**

- `bus_services` accumulates documents from both sources simultaneously. `BusServiceRepository.findServicesConnectingStations()` queries by `hubStationId` field (not doc ID), so it returns docs from both pipelines — doubled results, inconsistent departure times.
- `route_stops` auto-ID documents from the app grow unboundedly. Each cold start where `stations.count() == 0` resolves true (network latency, first run) re-seeds all stops with new random IDs.
- `FirestoreInitializationService` seeds only 4 hub stations and 7 bus services — a fraction of the full dataset — so the app's version of the data is always stale and incomplete.

---

### Issue 2 — 16 cross-file duplicate station definitions, 8 with inconsistent data *(Severity: HIGH)*

Stations shared across multiple JSON files where the last `seed_transtu.js` run wins (Firestore `merge: true`), making the final stored value non-deterministic depending on file processing order.

**Inconsistent duplicates (require decision before fix):**

| Station ID | Occurrences | Conflict |
|---|---|---|
| `transtu_dest_kalaat_alandalous` | 5 files | Coordinates `(36.92, 10.12)` × 4 vs `(37.091, 10.081)` in `transtumarine.json` |
| `transtu_dest_charguia` | 3 files | Name `"El Charguia"` vs `"Charguia"`; 3 different coordinate pairs |
| `transtu_dest_omrane_superieur` | 3 files | 3 different lat/lng values across `transtubebalioua`, `transtubelhouanel`, `transtumarine` |
| `transtu_hub_intilaka` | 2 files | Arabic name typo `"الانطالقة"` vs correct `"الانطلاقة"` |
| `transtu_dest_tebourba` | 2 files | Entirely different stations sharing the same ID: `"Tebourba"` vs `"Borj El Amri (via Tebourba)"` |
| `transtu_dest_cite_bassatine` | 2 files | Name `"Cité Bassatine"` vs `"Cité El Bassatine"` |

**Consistent duplicates (safe — no conflict, just redundant):**

| Station ID | Occurrences | Action |
|---|---|---|
| `transtu_hub_carthage` | 2 files | Remove from secondary file |
| `transtu_dest_raoued_plage` | 2 files | Remove from secondary file |
| `transtu_dest_douar_hicher` | 2 files | Remove from secondary file |
| `transtu_hub_morneg` | 2 files | Remove from secondary file |
| `transtu_hub_khaireddine` | 2 files | Remove from secondary file |

---

### Issue 3 — 11 forward routes have no `routeStops` entries *(Severity: MEDIUM)*

Out of 232 routes, 27 have no `routeStops` records. 16 are reverse-direction routes (may be intentional if the app uses forward stops bidirectionally). The remaining **11 are forward routes** with missing stop data:

```
route_transtu_carthage_ligne25_naasan
route_transtu_jardin_thameur_ligne12
route_transtu_jardin_thameur_ligne15a
route_transtu_jardin_thameur_ligne15b
route_transtu_jardin_thameur_ligne32
route_transtu_jardin_thameur_ligne32b
route_transtu_jardin_thameur_ligne32c
route_transtu_jardin_thameur_ligne33a
route_transtu_jardin_thameur_ligne34a
route_transtu_jardin_thameur_ligne88
route_transtu_jardin_thameur_ligne89
```

`JourneyRepository` queries `route_stops` to resolve stop offsets and compute arrival times. A route with no stops will return null results — the route exists but the app silently finds no trip.

---

### Issue 4 — `seed_transtu.js` hardcoded to a specific developer's machine *(Severity: MEDIUM)*

```js
// scripts/seed_transtu.js, line 14
const serviceAccount = require('C:/Users/Snaws/Desktop/serviceAccount.json.json');
```

This crashes immediately on any other machine with `MODULE_NOT_FOUND`. A portable alternative (`firebase_admin_init.js`) exists and uses the `GOOGLE_APPLICATION_CREDENTIALS` environment variable, but `seed_transtu.js` and 7 other seed scripts ignore it in favour of loading `./firebase-key.json` directly.

**Auth pattern by script:**

| Pattern | Scripts |
|---|---|
| Hardcoded absolute path | `seed_transtu.js`, `seed_metro_sahel_simple.js` |
| Relative `./firebase-key.json` | `seed_banlieue_sud.js`, `seed_metro_sahel.js`, `seed_grandes_lignes.js`, `seed_sncft_line5.js`, `seed_banlieue_nabeul.js`, `seed_line_d.js`, `seed_line_e.js` |
| Correct — uses `firebase_admin_init.js` | `seed_integration_test_data.js` |

---

### Issue 5 — `cleanup_transtu_all.js` referenced but does not exist *(Severity: MEDIUM)*

`package.json` defines:
```json
"reseed-transtu": "npm run cleanup-transtu && npm run seed-transtu"
```

`cleanup_transtu_all.js` is not present in `scripts/`. Running `npm run reseed-transtu` crashes at step 1 with `MODULE_NOT_FOUND`, making the idempotent reseed workflow completely broken.

---

### Issue 6 — `FirestoreInitializationService` violates separation of concerns *(Severity: LOW — structural)*

The Flutter app embeds transport data as hardcoded Dart maps inside `firestore_initialization_service.dart` and uploads it to Firestore on startup. This means:

- Data changes require a mobile app release instead of a script run.
- The in-app dataset (4 hub stations, 7 bus services) is permanently stale vs the full script dataset (175+ stations, 232 routes).
- The idempotency guard (`stations.count() > 0`) can be fooled if a partial seed has run.

---

## 3. Collection-to-Script Ownership Map

| Firestore Collection | Written by scripts | Written by app | Notes |
|---|---|---|---|
| `stations` | 13 scripts | `FirestoreInitializationService` | Conflict on TRANSTU hub IDs |
| `routes` | 10 scripts | — | Scripts only |
| `bus_services` | `seed_transtu.js` only | `FirestoreInitializationService` | **ID scheme conflict** |
| `route_stops` | 9 scripts | `FirestoreInitializationService` | **Random ID duplication** |
| `trips` | 9 scripts | — | Scripts only |
| `tariffs` | 9 scripts | — | Scripts only |
| `operators` | 10 scripts | — | Scripts only |
| `transport_types` | `seed_metro_sahel.js` only | — | Scripts only |
| `admins` | `create_admin_accounts.js` | — | Client write is blocked by rules |
| `users` | `seed_integration_test_data.js` | Firebase Auth flow | Test data only |
| `community_messages` | — | Chat screen | App only |

---

## 4. Sub-Sprint Plan

### Sub-Sprint A — Standardize Firebase Admin credentials across all scripts

**Scope:** Scripts folder only. No Flutter code.  
**Files:** `seed_transtu.js`, `seed_metro_sahel_simple.js`, + 7 scripts using `./firebase-key.json`  
**Work:**
1. Replace the `C:/Users/Snaws/...` hardcoded path in `seed_transtu.js` with `firebase_admin_init.js`.
2. Replace `require('./firebase-key.json')` + inline `initializeApp()` in all 7 other scripts with `firebase_admin_init.js`.
3. Create `scripts/.env.example`:
   ```
   GOOGLE_APPLICATION_CREDENTIALS=/path/to/your-service-account.json
   FIREBASE_PROJECT_ID=tuni-transport-20eaf
   ```
4. Update `scripts/.gitignore` to ensure `*.json` service account files are never committed.

**Risk:** None — credential loading only, no data changes.

---

### Sub-Sprint B — Create `cleanup_transtu_all.js`

**Scope:** Scripts folder only. No Flutter code.  
**Files:** `scripts/cleanup_transtu_all.js` (new)  
**Work:**
1. Query and batch-delete all documents from:
   - `stations` where ID starts with `transtu_`
   - `routes` where ID starts with `route_transtu_`
   - `bus_services` where ID starts with `transtu_line_` OR `bus_svc_route_transtu_`
   - `route_stops` where field `routeId` starts with `route_transtu_`
   - `trips` where field `routeId` starts with `route_transtu_`
2. Use `firebase-admin` Firestore batch operations (max 500 writes per batch).
3. Use `firebase_admin_init.js` for credentials.
4. Log counts deleted per collection.

**Risk:** Destructive — deletes live data. Must only run in dev/staging, not production.

---

### Sub-Sprint C — Remove `FirestoreInitializationService` from the app

**Scope:** Flutter app. Requires Sub-Sprint B to exist first so cleanup+reseed can validate.  
**Files:** `lib/services/firestore_initialization_service.dart` (delete), `lib/main.dart`, `CLAUDE.md`  
**Work:**
1. Delete `lib/services/firestore_initialization_service.dart`.
2. Remove the `FirestoreInitializationService` import and `initialize()` call from `main.dart`.
3. Add a `kDebugMode` guard in `main.dart` that checks `stations.count()` and prints a warning if zero:
   ```dart
   // Dev hint: run scripts/seed_transtu.js and the other seed scripts
   ```
4. Update `CLAUDE.md` to remove the reference to `FirestoreInitializationService`.

**Risk:** Low. The scripts are the canonical data source. Any environment where scripts have run will be unaffected.

---

### Sub-Sprint D — Canonicalize duplicate stations in JSON files

**Scope:** `scripts/data/*.json`. No Flutter code, no scripts logic.  
**Files:** `transtu10dec.json`, `transtuariana.json`, `transtubarcelone.json`, `transtubebalioua.json`, `transtubelhouanel.json`, `transtucarthage.json`, `transtucharguia.json`, `transtuintileka.json`, `transtumarine.json`, `transtuslimane.json`, `transtutbourba.json`  
**Work:**
1. **Inconsistent duplicates** — pick one canonical definition per station, remove from all other files. Decisions required (see Section 5).
2. **Consistent duplicates** — remove from the secondary file, keep in the authoritative file.
3. **Special case `transtu_dest_tebourba`** — the `transtuslimane.json` entry (`"Borj El Amri via Tebourba"`) is a different physical station. Assign it a new ID (e.g. `transtu_dest_borj_el_amri`) and update the route in `transtuslimane.json` that references it.
4. **11 forward routes missing `routeStops`** — add the missing stop entries in the relevant JSON files.

**Risk:** Medium. After this sub-sprint, run `npm run reseed-transtu` to verify the clean dataset loads correctly.

---

### Sub-Sprint E — Verify and lock `BusServiceRepository` query contract

**Scope:** Read-only verification, one small code comment.  
**Files:** `lib/services/bus_service_repository.dart`  
**Work:**
1. Confirm `findServicesConnectingStations()` queries only by `hubStationId` and `destinationStationId` field values — not by doc ID.
2. Add a short comment locking in this contract so a future refactor doesn't accidentally add a doc-ID assumption.
3. After Sub-Sprints B+C clean up `transtu_line_*` ghost docs, do a manual Firestore query check.

**Risk:** None — read-only analysis plus a one-line comment.

---

## 5. Open Questions (Developer Input Required Before Sub-Sprint D)

| # | Question | Impact |
|---|---|---|
| 1 | `transtu_dest_kalaat_alandalous`: correct coordinates — `(36.92, 10.12)` or `(37.091, 10.081)`? | Used by map display and distance calculations |
| 2 | `transtu_dest_charguia`: canonical name — `"El Charguia"` or `"Charguia"`? Which lat/lng? | Displayed in search results |
| 3 | `transtu_dest_omrane_superieur`: which of the 3 coordinate sets is correct? | Map pin position |
| 4 | `transtu_dest_tebourba` in `transtuslimane.json`: confirm the new ID for `"Borj El Amri (via Tebourba)"` | Route stop references must be updated to match |
| 5 | The 16 reverse routes (`_rev`) with no `routeStops` — is this intentional (app uses forward stops bidirectionally) or a data gap? | Affects sub-Sprint D routeStops work |
| 6 | The 11 forward `jardin_thameur` routes with no `routeStops` — are these routes active? If yes, stop data needs to be added. | Without stops, these routes return no results in the app |

---

## 6. Recommended Execution Order

```
A → B → C → D → E
```

| Sub-Sprint | Depends on | Can start? |
|---|---|---|
| A — Credential standardization | Nothing | ✅ Now |
| B — Cleanup script | A (uses same init) | After A |
| C — Remove in-app seeder | B (cleanup validates the result) | After B |
| D — Canonicalize JSON data | Developer answers to Section 5 | After sign-off |
| E — Verify BusServiceRepository | B + C (old ghost docs removed) | After B + C |

---

## 7. Risk Summary

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Cleanup script (`cleanup_transtu_all.js`) deletes production data | Low if env is controlled | High | Add environment check (`FIREBASE_PROJECT_ID` must not be production ID), require `--confirm` flag |
| Removing `FirestoreInitializationService` breaks a fresh install where no seeds have run | Medium | Medium | The debug warning in `main.dart` covers this; document in `how_to_run.md` |
| Canonicalizing wrong coordinates for a station | Low | Low | App shows maps and search — wrong pin is visible and easily caught |
| Missing `routeStops` for `jardin_thameur` routes silently produces no results | Already present | Medium | These routes already fail today — fixing is an improvement, not a regression |
