// Route-level tests for POST /api/checkin and GET /api/attendance.
//
// Every refusal a member can hit is tested through the real handler, with the
// Firestore reads and the Google token exchange answered by a stub. The service
// account is a real generated RSA key (see helpers.js), so the signing path runs.
// The success path (a check-in actually written) needs the clock to sit in the
// Sunday window, so it is left to the rules tests and the manual preview.
import assert from 'node:assert/strict';
import { beforeEach, describe, test } from 'node:test';

import { onRequestPost as checkinPost } from '../functions/api/checkin.js';
import { onRequestGet as attendanceGet } from '../functions/api/attendance.js';
import { resetServiceAccessTokenCache } from '../worker/service_account.js';
import { muteConsoleError, testEnv, withFetch } from './helpers.js';

beforeEach(() => resetServiceAccessTokenCache());

const MEMBER = 'member-1';
const UNVERIFIED = 'unverified-1';
const ADMIN = 'admin-1';
const LEADER = 'leader-1';
const PENDING = 'pending-1';
const GONE = 'gone-1';

/// A token whose payload carries the uid and the email_verified claim. The
/// signature is not checked by these routes (Firestore does that in production;
/// the stub here accepts any token).
function token(uid, emailVerified = true) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'RS256' })}.${encode({ sub: uid, email_verified: emailVerified })}.sig`;
}

const DOCS = {
  [MEMBER]: { fields: { role: { stringValue: 'member' }, name: { stringValue: '甲' } } },
  [UNVERIFIED]: { fields: { role: { stringValue: 'member' }, name: { stringValue: '乙' } } },
  [ADMIN]: { fields: { role: { stringValue: 'admin' }, name: { stringValue: '管理员' } } },
  [LEADER]: { fields: { role: { stringValue: 'leader' }, name: { stringValue: '小组长' } } },
};

/// Answers the Google token exchange, the users reads and the signup_requests
/// reads. Anything else fails loudly, so an unexpected call is noticed.
function fakeGoogle({ pendingFor = [] } = {}) {
  return async (input) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url.startsWith('https://oauth2.googleapis.com/token')) {
      return Response.json({ access_token: 'svc-token', expires_in: 3600 });
    }
    const users = url.match(/\/documents\/users\/([^?]+)/);
    if (users) {
      const doc = DOCS[decodeURIComponent(users[1])];
      return doc ? Response.json(doc) : new Response('{}', { status: 404 });
    }
    const signup = url.match(/\/documents\/signup_requests\/([^?]+)/);
    if (signup) {
      const uid = decodeURIComponent(signup[1]);
      return pendingFor.includes(uid)
        ? Response.json({ fields: { status: { stringValue: 'pending' } } })
        : new Response('{}', { status: 404 });
    }
    throw new Error(`unexpected fetch in test: ${url}`);
  };
}

function checkinRequest({ uid = MEMBER, verified = true, body = { latitude: 0.5, longitude: 0.5 }, auth = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${token(uid, verified)}`;
  return new Request('https://app.example/api/checkin', {
    method: 'POST',
    headers,
    body: body === null ? undefined : JSON.stringify(body),
  });
}

function attendanceRequest({ uid = ADMIN, date } = {}) {
  const url = new URL('https://app.example/api/attendance');
  if (date !== undefined) url.searchParams.set('date', date);
  return new Request(url, { headers: { authorization: `Bearer ${token(uid)}` } });
}

async function call(handler, request, { pendingFor, env } = {}) {
  const restore = muteConsoleError();
  try {
    return await withFetch(fakeGoogle({ pendingFor }), async () =>
      handler({ request, env: env ?? (await testEnv()) }),
    );
  } finally {
    restore();
  }
}

describe('POST /api/checkin: who may check in', () => {
  test('no sign-in at all is 401', async () => {
    const response = await call(checkinPost, checkinRequest({ auth: false }));
    assert.equal(response.status, 401);
  });

  test('a member whose email is not verified is refused, with what to do next', async () => {
    const response = await call(checkinPost, checkinRequest({ uid: UNVERIFIED, verified: false }));
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, '请先到邮箱点击验证链接，再打卡');
  });

  test('a pending sign-up is told it is waiting for approval, not that it has no access', async () => {
    const response = await call(
      checkinPost,
      checkinRequest({ uid: PENDING }),
      { pendingFor: [PENDING] },
    );
    assert.equal(response.status, 403);
    assert.match((await response.json()).error, /等待管理员确认/);
  });

  test('a signed-in uid with neither a member nor a pending sign-up gets the plain refusal', async () => {
    const response = await call(checkinPost, checkinRequest({ uid: GONE }));
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, '这个帐号没有权限');
  });
});

describe('POST /api/checkin: what the body may contain', () => {
  test('a missing or non-numeric location is 400 before any time or distance check', async () => {
    const missing = await call(checkinPost, checkinRequest({ body: {} }));
    assert.equal(missing.status, 400);
    const text = await call(checkinPost, checkinRequest({ body: { latitude: '41.9', longitude: 12.5 } }));
    assert.equal(text.status, 400);
  });

  test('a location out of range is 400', async () => {
    const response = await call(checkinPost, checkinRequest({ body: { latitude: 120, longitude: 0 } }));
    assert.equal(response.status, 400);
  });

  test('a phone far from the church is refused (the deployment has no church location here)', async () => {
    // The public example config sets the church location to 0,0 on purpose, so a
    // real phone is always far away and the server must say so.
    const response = await call(checkinPost, checkinRequest({ body: { latitude: 41.9, longitude: 12.5 } }));
    assert.equal(response.status, 403);
  });
});

describe('GET /api/attendance: who may read it', () => {
  test('a plain member is refused, even for today', async () => {
    const response = await call(attendanceGet, attendanceRequest({ uid: MEMBER }));
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, '只有管理员和小组长可以查看出勤');
  });

  test('a leader and an admin get past the role check', async () => {
    const leader = await call(attendanceGet, attendanceRequest({ uid: LEADER, date: 'not-a-date' }));
    assert.equal(leader.status, 400, 'a leader is allowed; the bad date is what stops them');
    const admin = await call(attendanceGet, attendanceRequest({ uid: ADMIN, date: 'not-a-date' }));
    assert.equal(admin.status, 400);
  });

  test('the date must look like YYYY-MM-DD', async () => {
    for (const date of ['2026-1-4', '04/10/2026', '2026-10-04T00:00', "2026-10-04'; DROP"]) {
      const response = await call(attendanceGet, attendanceRequest({ uid: ADMIN, date }));
      assert.equal(response.status, 400, `date ${date} must be refused`);
    }
  });

  test('no sign-in is 401', async () => {
    const request = new Request('https://app.example/api/attendance');
    const response = await call(attendanceGet, request);
    assert.equal(response.status, 401);
  });
});
