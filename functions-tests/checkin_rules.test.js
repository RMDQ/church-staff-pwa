import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { distanceMeters, evaluateCheckin, rulesFromConfig, zoneClock } from '../worker/checkin_rules.js';
import { encodeFields } from '../worker/firestore_admin.js';

const TIME_ZONE = 'Europe/Rome';
// 2026-10-04 is a Sunday. Rome is on CEST (UTC+2) until 25 October.
const sundayService = { id: 'sundayService', label: '主日', name: '主日崇拜', weekday: 7, enabled: true };
// The same shape the deployment's church config provides.
const RULES = rulesFromConfig({
  serviceId: 'sundayService',
  start: '13:00',
  end: '15:30',
  onTimeBefore: '13:30',
  allowedMeters: 100,
  latitude: 41.8919,
  longitude: 12.4839,
});
const church = RULES.church;
const atChurch = { latitude: church.lat + 0.0002, longitude: church.lng };   // about 22 m away
const farAway = { latitude: church.lat + 0.01, longitude: church.lng };      // about 1.1 km away

function decide(romeTimeUtc, overrides = {}) {
  return evaluateCheckin({
    instant: new Date(romeTimeUtc),
    timeZone: TIME_ZONE,
    service: sundayService,
    rules: RULES,
    ...atChurch,
    ...overrides,
  });
}

describe('zoneClock', () => {
  test('reads the church time zone, not UTC', () => {
    // 13:10 in Rome on 4 October is 11:10 UTC.
    const clock = zoneClock(new Date('2026-10-04T11:10:00Z'), TIME_ZONE);
    assert.equal(clock.dateKey, '2026-10-04');
    assert.equal(clock.weekday, 7);
    assert.equal(clock.time, '13:10');
    assert.equal(clock.minutes, 13 * 60 + 10);
  });
});

describe('distanceMeters', () => {
  test('is zero for the same point and about 22 m for the nearby point', () => {
    assert.equal(distanceMeters(church.lat, church.lng, church.lat, church.lng), 0);
    const d = distanceMeters(church.lat, church.lng, atChurch.latitude, atChurch.longitude);
    assert.ok(d >= 20 && d <= 25, `got ${d}`);
  });
});

describe('evaluateCheckin', () => {
  test('on time before 13:30 inside the window and inside the distance', () => {
    const result = decide('2026-10-04T11:10:00Z');
    assert.equal(result.ok, true);
    assert.equal(result.status, 'onTime');
    assert.equal(result.dateKey, '2026-10-04');
    assert.equal(result.time, '13:10');
  });

  test('late from 13:30 on', () => {
    const result = decide('2026-10-04T11:45:00Z');
    assert.equal(result.ok, true);
    assert.equal(result.status, 'late');
  });

  test('accepts the first and last minute of the window', () => {
    assert.equal(decide('2026-10-04T11:00:00Z').ok, true);   // 13:00
    assert.equal(decide('2026-10-04T13:30:00Z').ok, true);   // 15:30
  });

  test('refuses one minute before 13:00', () => {
    const result = decide('2026-10-04T10:59:00Z');           // 12:59
    assert.equal(result.ok, false);
    assert.match(result.message, /13:00/);
  });

  test('refuses one minute after 15:30', () => {
    assert.equal(decide('2026-10-04T13:31:00Z').ok, false);  // 15:31
  });

  test('refuses on a day that is not the service day', () => {
    const result = decide('2026-10-03T11:10:00Z');           // Saturday 13:10
    assert.equal(result.ok, false);
    assert.match(result.message, /主日崇拜/);
  });

  test('refuses when the phone is too far from the church', () => {
    const result = decide('2026-10-04T11:10:00Z', farAway);
    assert.equal(result.ok, false);
    assert.ok(result.distanceMeters > 100);
  });

  test('refuses a disabled service', () => {
    const result = decide('2026-10-04T11:10:00Z', { service: { ...sundayService, enabled: false } });
    assert.equal(result.ok, false);
  });

  test('refuses when the service is missing from church config', () => {
    const result = decide('2026-10-04T11:10:00Z', { service: undefined });
    assert.equal(result.ok, false);
  });
});

describe('encodeFields', () => {
  test('encodes the types the check-in record uses', () => {
    const fields = encodeFields({
      uid: 'abc',
      distanceMeters: 22,
      latitude: 41.8919,
      ok: true,
      note: null,
      createdAt: new Date('2026-10-04T11:10:00Z'),
    });
    assert.deepEqual(fields.uid, { stringValue: 'abc' });
    assert.deepEqual(fields.distanceMeters, { integerValue: '22' });
    assert.deepEqual(fields.latitude, { doubleValue: 41.8919 });
    assert.deepEqual(fields.ok, { booleanValue: true });
    assert.deepEqual(fields.note, { nullValue: null });
    assert.deepEqual(fields.createdAt, { timestampValue: '2026-10-04T11:10:00.000Z' });
  });

  test('refuses a value Firestore cannot store, rather than writing it silently', () => {
    assert.throws(() => encodeFields({ bad: undefined }), TypeError);
    assert.throws(() => encodeFields({ bad: Number.NaN }), TypeError);
  });
});
