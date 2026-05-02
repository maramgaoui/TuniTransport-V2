#!/usr/bin/env node
/**
 * Seed Banlieue de Nabeul (SNCFT) data from scripts/data/banlieue_nabeul/.
 * Format: { operator, stations[], routes[{ trips[] }], routeStops[] }
 * routeStops use 'routeId' field directly.
 *
 * Run:
 *   GOOGLE_APPLICATION_CREDENTIALS="../serviceAccount.json" \
 *   FIREBASE_PROJECT_ID="tuni-transport-20eaf" \
 *   node seed_banlieue_nabeul.js
 */

const path = require('path');
const fs   = require('fs');
const { admin, initializeFirebaseAdmin } = require('./firebase_admin_init');

initializeFirebaseAdmin();
const db = admin.firestore();

// ─── BatchWriter ─────────────────────────────────────────────────────────────

const BATCH_LIMIT = 200;

class BatchWriter {
  constructor() { this._reset(); }
  _reset() { this._batch = db.batch(); this._count = 0; }

  set(ref, data) {
    this._batch.set(ref, data, { merge: true });
    this._count++;
  }

  async flushIfFull() {
    if (this._count >= BATCH_LIMIT) await this.flush();
  }

  async flush() {
    if (this._count === 0) return;
    await this._batch.commit();
    this._reset();
  }
}

// ─── Seed one file ────────────────────────────────────────────────────────────

async function seedTrainFile(d, bw, stats) {
  const { stations = [], routes = [], routeStops = [] } = d;
  const operatorId = d.operator?.id ?? 'sncft_banlieue_nabeul';

  // Build direction→routeId map and firstForwardRouteId fallback
  const directionToRouteId = {};
  let firstForwardRouteId = null;
  for (const r of routes) {
    if (r.direction) directionToRouteId[r.direction] = r.id;
    if (!firstForwardRouteId && (r.direction === 'forward' || r.direction === 'south')) {
      firstForwardRouteId = r.id;
    }
  }

  // 1. Stations
  for (const s of stations) {
    const data = {
      name:           s.name,
      nameAr:         s.nameAr ?? s.name,
      cityId:         s.cityId ?? s.city ?? 'tunis',
      latitude:       s.lat   ?? s.latitude  ?? null,
      longitude:      s.lng   ?? s.longitude ?? null,
      isMainHub:      s.isMainHub ?? false,
      transportTypes: s.transportTypes ?? ['train'],
    };
    // arrayUnion preserves operators already set by other seeders on shared stations
    const ops = s.operatorsHere ?? (s.shared ? null : [operatorId]);
    if (ops) data.operatorsHere = admin.firestore.FieldValue.arrayUnion(...ops);

    bw.set(db.collection('stations').doc(s.id), data);
    await bw.flushIfFull();
    stats.stations++;
  }

  // 2. Routes + Trips
  for (const r of routes) {
    bw.set(db.collection('routes').doc(r.id), {
      lineNumber:          r.lineNumber          ?? null,
      name:                r.name                ?? null,
      direction:           r.direction           ?? 'forward',
      operatorId:          operatorId,
      transportType:       'train',
      originStationId:     r.originStationId     ?? null,
      destinationStationId: r.destinationStationId ?? null,
      operatingDays:       r.operatingDays       ?? [0, 1, 2, 3, 4, 5, 6],
      isActive:            true,
    });
    await bw.flushIfFull();
    stats.routes++;

    for (const t of r.trips ?? []) {
      if (!t.tripNumber) continue;
      const tripSlug = String(t.tripNumber).replace(/[^a-z0-9]/gi, '_');
      const routeSlug = r.id.replace(/^route_/, '');
      const tripId = `trip_${operatorId}_${routeSlug}_${tripSlug}`;
      const tripData = {
        routeId:       r.id,
        operatorId:    operatorId,
        tripNumber:    String(t.tripNumber),
        departureTime: t.departureTime ?? null,
        operatingDays: t.operatingDays ?? r.operatingDays ?? [0, 1, 2, 3, 4, 5, 6],
        terminatesAt:  t.terminatesAtStationId ?? null,
        isActive:      true,
      };
      if (t.stationTimeOverrides) tripData.stationTimeOverrides = t.stationTimeOverrides;
      bw.set(db.collection('trips').doc(tripId), tripData);
      await bw.flushIfFull();
      stats.trips++;
    }
  }

  // 3. Route stops
  for (const rs of routeStops) {
    const routeId = rs.routeId ?? directionToRouteId[rs.direction] ?? firstForwardRouteId;
    if (!routeId || !rs.stationId) continue;
    const docId = `${routeId}_stop_${rs.stopOrder}_${rs.stationId}`;
    bw.set(db.collection('route_stops').doc(docId), {
      routeId:                     routeId,
      stationId:                   rs.stationId,
      stopOrder:                   rs.stopOrder,
      estimatedArrivalTimeMinutes: rs.estimatedArrivalTimeMinutes ?? 0,
    });
    await bw.flushIfFull();
    stats.routeStops++;
  }
}

// ─── main ─────────────────────────────────────────────────────────────────────

async function main() {
  const dataDir = path.join(__dirname, 'data', 'banlieue_nabeul');

  if (!fs.existsSync(dataDir)) {
    console.error(`❌ Folder not found: ${dataDir}`);
    process.exit(1);
  }

  const files = fs.readdirSync(dataDir).filter(f => f.endsWith('.json')).sort();
  if (files.length === 0) {
    console.error('❌ No .json files found in scripts/data/banlieue_nabeul/');
    process.exit(1);
  }

  console.log(`🚆 Seeding Banlieue de Nabeul from ${files.length} JSON file(s)...\n`);

  // Upsert operator
  await db.collection('operators').doc('sncft_banlieue_nabeul').set({
    id:        'sncft_banlieue_nabeul',
    name:      'SNCFT - Banlieue de Nabeul',
    shortName: 'Banlieue Nabeul',
    phone:     '+216 71 334 444',
    typeId:    'train',
    color:     '#8BC34A',
  }, { merge: true });
  console.log('  ✓ Operator doc upserted\n');

  const grand = { stations: 0, routes: 0, routeStops: 0, trips: 0 };

  for (const file of files) {
    const filePath = path.join(dataDir, file);
    let d;
    try {
      d = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (e) {
      console.error(`  ❌ Failed to parse ${file}: ${e.message}`);
      continue;
    }

    const bw    = new BatchWriter();
    const stats = { stations: 0, routes: 0, routeStops: 0, trips: 0 };

    await seedTrainFile(d, bw, stats);
    await bw.flush();

    console.log(
      `  ✓ ${file.padEnd(40)}` +
      `  stations=${String(stats.stations).padStart(3)}` +
      `  routes=${String(stats.routes).padStart(2)}` +
      `  routeStops=${String(stats.routeStops).padStart(3)}` +
      `  trips=${String(stats.trips).padStart(3)}`
    );

    for (const k of Object.keys(grand)) grand[k] += stats[k];
  }

  console.log('\n📊 Grand total:');
  console.log(`   stations   : ${grand.stations}`);
  console.log(`   routes     : ${grand.routes}`);
  console.log(`   route_stops: ${grand.routeStops}`);
  console.log(`   trips      : ${grand.trips}`);
  console.log('\n✅ Banlieue Nabeul seed complete!\n');
  process.exit(0);
}

main().catch(err => {
  console.error('❌ Fatal error:', err);
  process.exit(1);
});
