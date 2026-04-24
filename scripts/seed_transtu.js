#!/usr/bin/env node
/**
 * Seed ALL TRANSTU data from the 17 JSON files in scripts/data/.
 * All files are Format A: { stations[], routes[{ id, trips[], ... }], routeStops[] }
 *
 * Place all transtu*.json files in:  scripts/data/
 * Place this file in:                scripts/
 * Run:  node seed_transtu.js
 */

const path  = require('path');
const fs    = require('fs');
const admin = require('firebase-admin');
const serviceAccount = require('C:/Users/Snaws/Desktop/serviceAccount.json.json');

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

// ─── BatchWriter ─────────────────────────────────────────────────────────────

const BATCH_LIMIT = 490;

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

// ─── Seed one Format-A file ───────────────────────────────────────────────────

async function seedFile(d, bw, stats) {
  const { stations = [], routes = [], routeStops = [] } = d;

  // 1. Stations
  for (const s of stations) {
    bw.set(db.collection('stations').doc(s.id), {
      name:           s.name,
      nameAr:         s.nameAr ?? s.name,
      cityId:         s.cityId ?? 'tunis',
      latitude:       s.lat  ?? s.latitude  ?? null,
      longitude:      s.lng  ?? s.longitude ?? null,
      isMainHub:      s.isMainHub ?? false,
      transportTypes: s.transportTypes ?? ['bus'],
      operatorsHere:  s.operatorsHere  ?? ['transtu'],
    });
    await bw.flushIfFull();
    stats.stations++;
  }

  // 2. Routes
  for (const r of routes) {
    bw.set(db.collection('routes').doc(r.id), {
      lineNumber:               r.lineNumber               ?? null,
      name:                     r.name                     ?? null,
      direction:                r.direction                ?? 'forward',
      operatorId:               'transtu',
      transportType:            'bus',
      originStationId:          r.originStationId          ?? null,
      destinationStationId:     r.destinationStationId     ?? null,
      firstDepartureFromHub:    r.firstDepartureFromHub    ?? null,
      lastDepartureFromHub:     r.lastDepartureFromHub     ?? null,
      firstDepartureFromSuburb: r.firstDepartureFromSuburb ?? null,
      lastDepartureFromSuburb:  r.lastDepartureFromSuburb  ?? null,
      peakFrequencyMinutes:     r.peakFrequencyMinutes     ?? null,
      zone:                     r.zone                     ?? 'urbaine',
      price:                    r.price                    ?? 0.5,
      isActive:                 true,
    });
    await bw.flushIfFull();
    stats.routes++;

    // Also write to bus_services collection (read by BusServiceRepository in the app).
    // Only forward-direction routes become bus_services entries (one per line per hub).
    if ((r.direction ?? 'forward') === 'forward' && r.originStationId) {
      // Derive Arabic direction name from destination station name in the stations list
      const destStation = (d.stations ?? []).find(s => s.id === r.destinationStationId);
      const directionAr = destStation?.nameAr ?? r.name ?? '';
      const destinationNameFr = destStation?.name ?? null;

      const serviceDocId = `bus_svc_${r.id}`;
      bw.set(db.collection('bus_services').doc(serviceDocId), {
        routeId:                  r.id,
        hubStationId:             r.originStationId,
        lineNumber:               r.lineNumber               ?? null,
        directionAr:              directionAr,
        destinationNameFr:        destinationNameFr,
        firstDepartureFromHub:    r.firstDepartureFromHub    ?? null,
        lastDepartureFromHub:     r.lastDepartureFromHub     ?? null,
        firstDepartureFromSuburb: r.firstDepartureFromSuburb ?? null,
        lastDepartureFromSuburb:  r.lastDepartureFromSuburb  ?? null,
        peakFrequencyMinutes:     r.peakFrequencyMinutes     ?? null,
        operatingDays:            r.operatingDays            ?? [0,1,2,3,4,5,6],
        season:                   'winter_2025_2026',
        zone:                     r.zone                     ?? 'urbaine',
        price:                    r.price                    ?? 0.5,
        isActive:                 true,
      });
      await bw.flushIfFull();
      stats.busServices = (stats.busServices ?? 0) + 1;
    }

    // 3. Inline trips (may be empty array — skip gracefully)
    for (const t of r.trips ?? []) {
      if (!t.tripNumber) continue;
      const tripId = `trip_transtu_${r.id.replace('route_transtu_', '')}_${t.tripNumber}`;
      bw.set(db.collection('trips').doc(tripId), {
        routeId:       r.id,
        operatorId:    'transtu',
        tripNumber:    t.tripNumber,
        departureTime: t.departureTime    ?? null,
        operatingDays: t.operatingDays   ?? [0, 1, 2, 3, 4, 5, 6],
        terminatesAt:  t.terminatesAtStationId ?? null,
        isActive:      true,
      });
      await bw.flushIfFull();
      stats.trips++;
    }

    // 4. Synthesise a representative trip when trips[] is empty
    //    (uses firstDepartureFromHub so the route has at least one trip)
    if ((r.trips ?? []).length === 0 && r.firstDepartureFromHub) {
      const lineSlug = String(r.lineNumber ?? 'x').replace(/[^a-z0-9]/gi, '_');
      const tripId   = `trip_transtu_${r.id.replace('route_transtu_', '')}_1`;
      bw.set(db.collection('trips').doc(tripId), {
        routeId:       r.id,
        operatorId:    'transtu',
        tripNumber:    `${lineSlug}_1`,
        departureTime: r.firstDepartureFromHub,
        operatingDays: r.operatingDays ?? [0, 1, 2, 3, 4, 5, 6],
        terminatesAt:  r.destinationStationId ?? null,
        isActive:      true,
      });
      await bw.flushIfFull();
      stats.trips++;
    }
  }

  // 5. Route stops
  for (const rs of routeStops) {
    if (!rs.routeId || !rs.stationId) continue;
    const docId = `${rs.routeId}_stop_${rs.stopOrder}_${rs.stationId}`;
    bw.set(db.collection('route_stops').doc(docId), {
      routeId:                     rs.routeId,
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
  const dataDir = path.join(__dirname, 'data');

  if (!fs.existsSync(dataDir)) {
    console.error(`❌ Folder not found: ${dataDir}`);
    console.error('   Create a "data" folder inside scripts/ and put all transtu*.json files there.');
    process.exit(1);
  }

  const files = fs.readdirSync(dataDir)
    .filter(f => f.startsWith('transtu') && f.endsWith('.json'))
    .sort();

  if (files.length === 0) {
    console.error('❌ No transtu*.json files found in scripts/data/');
    process.exit(1);
  }

  console.log(`🚌 Seeding TRANSTU data from ${files.length} JSON files...\n`);

  // Upsert operator
  await db.collection('operators').doc('transtu').set({
    id:        'transtu',
    name:      'TRANSTU - Société de Transport de Tunis',
    shortName: 'TRANSTU',
    phone:     '+216 71 102 000',
    typeId:    'bus',
    color:     '#E53935',
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

    await seedFile(d, bw, stats);
    await bw.flush();

    console.log(
      `  ✓ ${file.padEnd(32)}` +
      `  stations=${String(stats.stations).padStart(3)}` +
      `  routes=${String(stats.routes).padStart(3)}` +
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
  console.log('\n✅ TRANSTU seed complete!\n');
  process.exit(0);
}

main().catch(err => {
  console.error('❌ Fatal error:', err);
  process.exit(1);
});