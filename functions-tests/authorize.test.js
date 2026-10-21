// Policy suite for worker/authorize.js — who may do what, asked the way the
// handlers ask it. The handler tests keep only a case or two proving each
// route actually asks; everything about the answer lives here.

import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { authorize } from '../worker/authorize.js';
import {
  ADMIN_NAME,
  ADMIN_UID,
  CALENDAR_EDITOR_NAME,
  CALENDAR_EDITOR_UID,
  MEMBER_UID,
  ROSTER_EDITOR_UID,
  fakeFetch,
  idToken,
  muteConsoleError,
  request,
  testEnv,
} from './helpers.js';

const CALENDAR = { edit: 'calendar' };
const ROSTER = { edit: 'roster' };

const YOUTH_EDITOR_UID = 'youth-editor-uid';
/// 有青崇的牧区，却不在 roster-editors：牧区本身不是授权。
const ZONE_ONLY_UID = 'zone-only-uid';

/// helpers.js 的预设名单，加上两个跟牧区有关的人。admin 刻意不给 zoneTypes：
/// firestore.rules 的 canEditRosterType() 说 admin 不必持有牧区。
const USERS = {
  [ADMIN_UID]: { role: 'admin', name: ADMIN_NAME },
  [MEMBER_UID]: { role: 'member', name: '路人' },
  [CALENDAR_EDITOR_UID]: {
    role: 'staff',
    groups: ['calendar-editors'],
    name: CALENDAR_EDITOR_NAME,
  },
  [ROSTER_EDITOR_UID]: { role: 'staff', groups: ['roster-editors'], name: '服事表同工' },
  [YOUTH_EDITOR_UID]: {
    role: 'staff',
    groups: ['roster-editors'],
    zoneTypes: ['youth'],
    name: '青崇同工',
  },
  [ZONE_ONLY_UID]: { role: 'staff', groups: [], zoneTypes: ['youth'], name: '青崇会友' },
};

/// 服事表分两段：先过 group，再用 forRosterType 问哪一个崇拜。回传的是 token。
async function rosterTokenAs(uid, type, options) {
  return (await authorizeAs(uid, ROSTER, options)).forRosterType(type);
}

async function authorizeAs(uid, action, { users = USERS, fetchImpl, env } = {}) {
  return authorize(
    request('POST', { token: idToken(uid) }),
    env ?? (await testEnv()),
    action,
    fetchImpl ?? fakeFetch({ users }),
  );
}

describe('authorize — 谁在呼叫', () => {
  test('没有 Authorization header 是 401，而且不查 Firestore', async () => {
    const fetchImpl = fakeFetch();
    await assert.rejects(
      authorize(request('POST', { token: null }), await testEnv(), CALENDAR, fetchImpl),
      { status: 401, message: '请先登入' },
    );
    assert.equal(fetchImpl.calls.length, 0);
  });

  test('空白的 bearer token 是 401', async () => {
    await assert.rejects(
      authorize(request('POST', { token: '  ' }), await testEnv(), CALENDAR, fakeFetch()),
      { status: 401 },
    );
  });

  // 从 app 移除的人还拿著有效的 Firebase token，但 users/{uid} 已经不在了。
  test('登入了却没有使用者文件是 403', async () => {
    await assert.rejects(authorizeAs('ghost', CALENDAR), {
      status: 403,
      message: '这个帐号没有权限',
    });
  });

  test('Firestore 拒绝 token 时请人重新登入', async () => {
    const fetchImpl = async () => new Response('{}', { status: 401 });
    await assert.rejects(authorizeAs(ADMIN_UID, CALENDAR, { fetchImpl }), {
      status: 401,
      message: '登入状态已过期，请重新登入',
    });
  });

  test('Firestore 挂了是 502，请人稍后再试', async () => {
    const restore = muteConsoleError();
    try {
      const fetchImpl = async () => new Response('boom', { status: 500 });
      await assert.rejects(authorizeAs(ADMIN_UID, CALENDAR, { fetchImpl }), { status: 502 });
    } finally {
      restore();
    }
  });

  test('没设 project id 时一律拒绝', async () => {
    const restore = muteConsoleError();
    try {
      const env = await testEnv({ FIREBASE_PROJECT_ID: '' });
      await assert.rejects(authorizeAs(ADMIN_UID, CALENDAR, { env }), { status: 500 });
    } finally {
      restore();
    }
  });

  test('通过时回传 uid、名字与呼叫者自己的 token', async () => {
    assert.deepEqual(await authorizeAs(ADMIN_UID, CALENDAR), {
      uid: ADMIN_UID,
      name: ADMIN_NAME,
      token: idToken(ADMIN_UID),
    });
  });

  // 没有 name 的旧帐号照样能用 —— 名字只影响通知长什么样。
  test('没有名字或名字只有空白时 name 是 null', async () => {
    for (const profile of [{ role: 'admin' }, { role: 'admin', name: '   ' }]) {
      const result = await authorizeAs(ADMIN_UID, CALENDAR, { users: { [ADMIN_UID]: profile } });
      assert.equal(result.name, null);
    }
  });

  // 遮罩少一个栏位就等于没读：名字拿不到通知就是匿名的，牧区拿不到就谁都过不了。
  test('向 Firestore 要的栏位包含 name 与 zoneTypes', async () => {
    const fetchImpl = fakeFetch({ users: USERS });
    await authorizeAs(ADMIN_UID, CALENDAR, { fetchImpl });
    const [lookup] = fetchImpl.calls;
    assert.match(lookup.url, /mask\.fieldPaths=name/);
    assert.match(lookup.url, /mask\.fieldPaths=zoneTypes/);
  });

  test('不认得的 action 是程式错误，不是 403', async () => {
    await assert.rejects(authorizeAs(ADMIN_UID, { edit: 'settings' }), (error) => {
      assert.equal(error.status, undefined);
      return true;
    });
  });
});

describe('authorize — 编辑行事历', () => {
  test('admin 可以（admin 是 root）', async () => {
    assert.equal((await authorizeAs(ADMIN_UID, CALENDAR)).uid, ADMIN_UID);
  });

  // 权限看 group，不看 role：这个人的 role 只是 staff。
  test('calendar-editors 可以，不管 role 是什么', async () => {
    const result = await authorizeAs(CALENDAR_EDITOR_UID, CALENDAR);
    assert.deepEqual(result, {
      uid: CALENDAR_EDITOR_UID,
      name: CALENDAR_EDITOR_NAME,
      token: idToken(CALENDAR_EDITOR_UID),
    });
  });

  // 两个 group 正交：服事表编辑者碰不到行事历。
  test('只有 roster-editors 的人被挡，讯息讲的是行事历', async () => {
    await assert.rejects(authorizeAs(ROSTER_EDITOR_UID, CALENDAR), {
      status: 403,
      message: '没有编辑行事历的权限',
    });
  });

  test('一般会众被挡', async () => {
    await assert.rejects(authorizeAs(MEMBER_UID, CALENDAR), {
      status: 403,
      message: '没有编辑行事历的权限',
    });
  });

  const shapes = [
    // 没有 groups 栏位的旧帐号 —— 全部既有使用者都是这个形状。
    ['没有 groups 栏位', { role: 'leader' }],
    // Firestore 对空阵列回的是 { arrayValue: {} }，没有 values。
    ['groups 是空阵列', { role: 'staff', groups: [] }],
    // 名字打错不能当成某种权限放行。
    ['group 名字打错', { role: 'staff', groups: ['calendar-editor'] }],
    ['文件一个栏位都没有', null],
  ];
  for (const [name, profile] of shapes) {
    test(`${name}时被挡`, async () => {
      await assert.rejects(
        authorizeAs(MEMBER_UID, CALENDAR, { users: { [MEMBER_UID]: profile } }),
        { status: 403 },
      );
    });
  }
});

describe('authorize — 编辑服事表', () => {
  for (const type of ['sundayService', 'youth', 'children']) {
    test(`admin 不必持有牧区也能编 ${type}`, async () => {
      assert.equal(await rosterTokenAs(ADMIN_UID, type), idToken(ADMIN_UID));
    });
  }

  test('有编辑权又有那个牧区的可以，拿到的是自己的 token', async () => {
    assert.equal(await rosterTokenAs(YOUTH_EDITOR_UID, 'youth'), idToken(YOUTH_EDITOR_UID));
  });

  // token 只能从 forRosterType 拿：handler 要读 Firestore 就一定得先问过牧区。
  test('通过 group 只拿到 uid 与名字，没有 token', async () => {
    const permit = await authorizeAs(YOUTH_EDITOR_UID, ROSTER);
    assert.equal(permit.uid, YOUTH_EDITOR_UID);
    assert.equal(permit.name, '青崇同工');
    assert.equal('token' in permit, false);
  });

  // group 说「可以改服事表」，zone 说「哪一个」—— 跟 canEditRosterType() 同一套。
  test('有编辑权但不是那个牧区的被挡，讯息讲的是这个崇拜', async () => {
    await assert.rejects(rosterTokenAs(YOUTH_EDITOR_UID, 'sundayService'), {
      status: 403,
      message: '没有编辑这个崇拜服事表的权限',
    });
  });

  test('zoneTypes 栏位不存在时当作没有牧区', async () => {
    await assert.rejects(rosterTokenAs(ROSTER_EDITOR_UID, 'youth'), {
      status: 403,
      message: '没有编辑这个崇拜服事表的权限',
    });
  });

  test('zoneTypes 是空阵列时当作没有牧区', async () => {
    const users = { [YOUTH_EDITOR_UID]: { ...USERS[YOUTH_EDITOR_UID], zoneTypes: [] } };
    await assert.rejects(rosterTokenAs(YOUTH_EDITOR_UID, 'youth', { users }), { status: 403 });
  });

  // group 在读 body 之前就挡：不在 roster-editors 的人连哪一个崇拜都不必问。
  test('有牧区但不在 roster-editors 的被挡，讯息讲的是服事表', async () => {
    await assert.rejects(authorizeAs(ZONE_ONLY_UID, ROSTER), {
      status: 403,
      message: '没有编辑服事表的权限',
    });
  });

  test('只有 calendar-editors 的人被挡', async () => {
    await assert.rejects(authorizeAs(CALENDAR_EDITOR_UID, ROSTER), {
      status: 403,
      message: '没有编辑服事表的权限',
    });
  });

  test('一般会众被挡', async () => {
    await assert.rejects(authorizeAs(MEMBER_UID, ROSTER), { status: 403 });
  });

  // 不存在的崇拜谁都不能编，admin 也一样；问牧区不会再查一次 Firestore。
  for (const [name, type] of [
    ['不认得的崇拜', 'wedding'],
    ['没有 type', undefined],
    ['type 不是字串', 7],
  ]) {
    test(`${name}是 400，连 admin 也一样`, async () => {
      const fetchImpl = fakeFetch({ users: USERS });
      const permit = await authorizeAs(ADMIN_UID, ROSTER, { fetchImpl });
      const lookups = fetchImpl.calls.length;
      assert.throws(() => permit.forRosterType(type), {
        status: 400,
        message: '不知道这是哪一个崇拜的服事表',
      });
      assert.equal(fetchImpl.calls.length, lookups);
    });
  }

  // 没有牧区的人送不存在的崇拜，说的是「不知道是哪一个」而不是「没有权限」。
  test('不认得的崇拜比牧区先检查', async () => {
    const permit = await authorizeAs(YOUTH_EDITOR_UID, ROSTER);
    assert.throws(() => permit.forRosterType('wedding'), { status: 400 });
  });
});

describe('App 里新增的聚会', () => {
  // 管理员在「聚会设定」新增的聚会存在 settings/services；照片汇入也要认得。
  test('settings/services 里的聚会可以编，不在里面的照样是 400', async () => {
    const fetchImpl = fakeFetch({ users: USERS, services: ['sundayService', 'prayer'] });
    const permit = await authorizeAs(ADMIN_UID, ROSTER, { fetchImpl });
    assert.ok(permit.forRosterType('prayer'));
    assert.throws(() => permit.forRosterType('wedding'), { status: 400 });
  });

  test('读聚会设定用的是呼叫者自己的 token，只在服事表的授权时读', async () => {
    const fetchImpl = fakeFetch({ users: USERS, services: ['prayer'] });
    await authorizeAs(ADMIN_UID, ROSTER, { fetchImpl });
    const read = fetchImpl.calls.find((call) => call.url.includes('/documents/settings/services'));
    assert.equal(read.init.headers.Authorization, `Bearer ${idToken(ADMIN_UID)}`);
    const calendar = fakeFetch({ users: USERS, services: ['prayer'] });
    await authorizeAs(ADMIN_UID, CALENDAR, { fetchImpl: calendar });
    assert.ok(!calendar.calls.some((call) => call.url.includes('/documents/settings/services')));
  });
});
