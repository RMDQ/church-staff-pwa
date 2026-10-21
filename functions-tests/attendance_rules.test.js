import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { attendanceFor, attendanceRows } from '../worker/attendance_rules.js';
import { decodeFields } from '../worker/firestore_admin.js';

const SERVICE = 'sundayService';

const users = new Map([
  ['admin', { id: 'admin', role: 'admin', zones: [] }],
  ['leaderA', { id: 'leaderA', role: 'leader', zones: [{ serviceType: SERVICE, smallGroups: ['小组甲'], ministries: [] }] }],
  ['memberA', { id: 'memberA', role: 'member', zones: [{ serviceType: SERVICE, smallGroups: ['小组甲'], ministries: [] }] }],
  ['memberB', { id: 'memberB', role: 'member', zones: [{ serviceType: SERVICE, smallGroups: ['小组乙'], ministries: [] }] }],
  ['memberNoZone', { id: 'memberNoZone', role: 'member', zones: [] }],
  ['leaderNoZone', { id: 'leaderNoZone', role: 'leader', zones: [] }],
]);

const records = [
  { uid: 'memberA', name: '甲', serviceId: SERVICE, time: '13:10', status: 'onTime', distanceMeters: 22 },
  { uid: 'memberB', name: '乙', serviceId: SERVICE, time: '13:40', status: 'late', distanceMeters: 30 },
  { uid: 'memberNoZone', name: '丙', serviceId: SERVICE, time: '13:20', status: 'onTime', distanceMeters: 12 },
  { uid: 'memberA', name: '甲', serviceId: 'youth', time: '18:10', status: 'onTime', distanceMeters: 20 },
];

describe('attendanceFor', () => {
  test('admin sees every check-in for the service, not other services', () => {
    const seen = attendanceFor({ viewer: users.get('admin'), users, records, serviceId: SERVICE });
    assert.equal(seen.length, 3);
    assert.ok(seen.every((r) => r.serviceId === SERVICE));
  });

  test('leader sees only people who share a small group with them', () => {
    const seen = attendanceFor({ viewer: users.get('leaderA'), users, records, serviceId: SERVICE });
    assert.deepEqual(seen.map((r) => r.name), ['甲']);
  });

  test('leader with no small group sees nothing', () => {
    const seen = attendanceFor({ viewer: users.get('leaderNoZone'), users, records, serviceId: SERVICE });
    assert.deepEqual(seen, []);
  });

  test('a plain member sees nothing, even in their own group', () => {
    const seen = attendanceFor({ viewer: users.get('memberA'), users, records, serviceId: SERVICE });
    assert.deepEqual(seen, []);
  });

  test('a viewer without a role sees nothing', () => {
    assert.deepEqual(attendanceFor({ viewer: undefined, users, records, serviceId: SERVICE }), []);
  });
});

describe('attendanceRows', () => {
  test('shows the small group, sorted by the time the server wrote', () => {
    const rows = attendanceRows({ records, users, serviceId: SERVICE });
    assert.deepEqual(rows.map((r) => r.time), ['13:10', '13:20', '13:40']);
    assert.deepEqual(rows[0].smallGroups, ['小组甲']);
    assert.deepEqual(rows[1].smallGroups, []);
  });

  test('a missing name is shown as unknown, not blank', () => {
    const rows = attendanceRows({
      records: [{ uid: 'memberA', serviceId: SERVICE, time: '13:00', status: 'onTime' }],
      users,
      serviceId: SERVICE,
    });
    assert.equal(rows[0].name, '（未知）');
  });

  test('an unexpected status is treated as late, never as on time', () => {
    const rows = attendanceRows({
      records: [{ uid: 'memberA', name: '甲', serviceId: SERVICE, time: '13:00', status: 'weird' }],
      users,
      serviceId: SERVICE,
    });
    assert.equal(rows[0].status, 'late');
  });
});

describe('decodeFields', () => {
  test('reads the typed values the app writes', () => {
    const decoded = decodeFields({
      name: { stringValue: '甲' },
      distanceMeters: { integerValue: '22' },
      latitude: { doubleValue: 41.8919 },
      ok: { booleanValue: true },
      createdAt: { timestampValue: '2026-10-04T11:10:00Z' },
      note: { nullValue: null },
      zones: {
        arrayValue: {
          values: [{ mapValue: { fields: { serviceType: { stringValue: SERVICE }, smallGroups: { arrayValue: { values: [{ stringValue: '小组甲' }] } } } } }],
        },
      },
    });
    assert.equal(decoded.name, '甲');
    assert.equal(decoded.distanceMeters, 22);
    assert.equal(decoded.latitude, 41.8919);
    assert.equal(decoded.ok, true);
    assert.equal(decoded.note, null);
    assert.deepEqual(decoded.zones, [{ serviceType: SERVICE, smallGroups: ['小组甲'] }]);
  });

  test('an unknown value type reads as null instead of throwing', () => {
    assert.deepEqual(decodeFields({ weird: { geoPointValue: {} } }), { weird: null });
  });
});
