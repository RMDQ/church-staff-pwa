// firestore.rules 的安全规则测试，跑在 Firestore emulator 上。
//
//   cd firestore-tests && npm install && npm test
//
// 规则是唯一挡得住「绕过 App、直接用公开 web SDK 打 Firestore」的东西，
// 所以每一条授权判断都要有对应的测试。
import assert from 'node:assert';
import defaults from '../worker/generated_config.js';
import { renderRules } from '../scripts/prepare-deployment.mjs';
import { readFileSync } from 'node:fs';
import { after, before, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  arrayUnion,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
} from 'firebase/firestore';

// 预设值要跟 firebase.json 的 emulators.firestore.port 一致。`npm test` 走
// emulators:exec 会自己设好 FIRESTORE_EMULATOR_HOST，但手动起 emulator 再跑
// `node --test rules.test.js` 时只剩这个预设值，写错 port 会变成连不上的怪错误。
const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST ?? '127.0.0.1:8181').split(':');

let testEnv;

const ADMIN = 'admin-1';
const MEMBER = 'member-1';
const OTHER = 'member-2';
// 编辑 group。刻意独立于 OTHER：OTHER 的 role 会被「管理员可以调整别人的
// role」那条测试改掉，借用它会让这里的断言随执行顺序漂移。
//
// 三个人的 role 全都不是 admin，而且 ROSTER_EDITOR 的 role 比 PLAIN_LEADER 还
// 低 —— 这是刻意的，用来钉住「权限看 group 不看 role」。
const ROSTER_EDITOR = 'roster-editor-1'; // 三个牧区都有
// 只属于青崇与儿主的编辑者。整组「编辑权不等于全部聚会别」的断言靠他。
const YOUTH_EDITOR = 'youth-editor-1';
// 有 roster-editors 但一个牧区都没有 —— 也是所有既有帐号（没有 zoneTypes
// 栏位）的形状，用来钉住「没有牧区就什么都改不动」。
const ZONELESS_EDITOR = 'zoneless-editor-1';
const CALENDAR_EDITOR = 'calendar-editor-1';
const PLAIN_LEADER = 'plain-leader-1'; // 身分是小组长，但没有任何 group
const GRANTED = 'granted-1'; // 已经有 group，用来测收回
const DELETED = 'deleted-1'; // 有 Auth token，但 users 文件已被管理员删掉
const LEGACY = 'legacy-1'; // 旧资料：users 文件存在但没有 role 栏位

function userDoc(id, role, groups, zoneTypes) {
  const document = {
    id,
    name: `姓名-${id}`,
    email: `${id}@example.com`,
    username: id,
    role,
    zones: [],
  };
  // 不传就完全不写这个栏位 —— 既有使用者全都是这个形状，规则必须撑得住。
  if (groups !== undefined) document.groups = groups;
  // zones 摊平出来的投影（见 User.zoneTypes）：规则语言没有回圈，读不出 zones
  // 那个 map list 里的 serviceType，所以牧区的判断一律看这个栏位。
  if (zoneTypes !== undefined) document.zoneTypes = zoneTypes;
  return document;
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-church-staff',
    firestore: {
      rules: renderRules(readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'), {
        ...defaults, services: [...defaults.services,
          { id: 'midweek', label: '周中', name: '周中聚会', weekday: 3, enabled: true },
          { id: 'retired', label: '旧聚会', name: '旧聚会', weekday: 1, enabled: false },
        ],
      }),
      host,
      port: Number(port),
    },
  });

  // 一定要先清空：`npm test` 每次都是全新 emulator 所以看不出来，但只要对著
  // 长时间开著的 emulator 重跑，上一轮残留的 users/new-staff 之类文件就会让
  // 「建立帐号」的测试变成在打 update 规则，create 那几条就悄悄失去侦测力。
  await testEnv.clearFirestore();

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', ADMIN), userDoc(ADMIN, 'admin'));
    await setDoc(doc(db, 'users', MEMBER), userDoc(MEMBER, 'member'));
    await setDoc(doc(db, 'users', OTHER), userDoc(OTHER, 'leader'));
    await setDoc(
      doc(db, 'users', ROSTER_EDITOR),
      userDoc(ROSTER_EDITOR, 'staff', ['roster-editors'], [
        'sundayService',
        'youth',
        'children',
      ]),
    );
    await setDoc(
      doc(db, 'users', YOUTH_EDITOR),
      userDoc(YOUTH_EDITOR, 'staff', ['roster-editors'], ['youth', 'children']),
    );
    // zoneTypes 栏位完全不存在：既有帐号的形状。
    await setDoc(
      doc(db, 'users', ZONELESS_EDITOR),
      userDoc(ZONELESS_EDITOR, 'staff', ['roster-editors']),
    );
    await setDoc(
      doc(db, 'users', CALENDAR_EDITOR),
      userDoc(CALENDAR_EDITOR, 'staff', ['calendar-editors']),
    );
    await setDoc(
      doc(db, 'users', PLAIN_LEADER),
      userDoc(PLAIN_LEADER, 'leader'),
    );
    // 「管理员可以把 group 收回成空阵列」要更新的对象。在这里种下去而不是靠
    // 前一条测试留下来的 —— clearFirestore() 只在 before() 跑一次，相依前一条
    // 的话单独执行那一条会 NOT_FOUND，看起来像 rules 坏了。
    await setDoc(
      doc(db, 'users', GRANTED),
      userDoc(GRANTED, 'member', ['calendar-editors']),
    );
    // 注意：DELETED 刻意没有 users 文件。
    const legacy = userDoc(LEGACY, 'member');
    delete legacy.role;
    await setDoc(doc(db, 'users', LEGACY), legacy);
    // users 底下不该有任何子集合可读写，靠最后的 default deny 挡。
    await setDoc(doc(db, 'users', MEMBER, 'private', 'secret'), { pin: '1234' });
    await setDoc(doc(db, 'rosters', 'r1'), {
      serviceName: '主日崇拜',
      type: 'sundayService',
    });
    // r2 专门给 list 查询用：r1 会被「管理员可以改服事表」覆写掉 date 栏位。
    await setDoc(doc(db, 'rosters', 'r2'), {
      serviceName: '青年崇拜',
      type: 'youth',
      date: Timestamp.fromDate(new Date('2030-01-05T00:00:00Z')),
    });
    // 儿主那本，专门留给青崇编辑者写（不跟 r1/r2 的断言互相覆写）。
    await setDoc(doc(db, 'rosters', 'r3'), {
      serviceName: '儿童主日学',
      type: 'children',
    });
    // 没有 type 栏位的旧资料：规则不该爆掉，而是只有 admin 动得了。
    await setDoc(doc(db, 'rosters', 'legacy'), { serviceName: '没有 type 的旧资料' });
    // 删除测试专用，一本一条，避免互相依赖执行顺序。
    await setDoc(doc(db, 'rosters', 'doomed-youth'), {
      serviceName: '青年崇拜',
      type: 'youth',
    });
    await setDoc(doc(db, 'rosters', 'doomed-sunday'), {
      serviceName: '主日崇拜',
      type: 'sundayService',
    });
    await setDoc(doc(db, 'settings', 'roster_templates'), {
      sundayService: ['领会'],
    });
  });
});

after(async () => {
  await testEnv?.cleanup();
});

const asAdmin = () => testEnv.authenticatedContext(ADMIN).firestore();
const asMember = () => testEnv.authenticatedContext(MEMBER).firestore();
const asRosterEditor = () =>
  testEnv.authenticatedContext(ROSTER_EDITOR).firestore();
const asYouthEditor = () =>
  testEnv.authenticatedContext(YOUTH_EDITOR).firestore();
const asZonelessEditor = () =>
  testEnv.authenticatedContext(ZONELESS_EDITOR).firestore();
const asCalendarEditor = () =>
  testEnv.authenticatedContext(CALENDAR_EDITOR).firestore();
const asPlainLeader = () =>
  testEnv.authenticatedContext(PLAIN_LEADER).firestore();
const asDeleted = () => testEnv.authenticatedContext(DELETED).firestore();
const asAnon = () => testEnv.unauthenticatedContext().firestore();

describe('rosters / settings 读取', () => {
  it('一般同工读得到服事表', async () => {
    await assertSucceeds(getDoc(doc(asMember(), 'rosters', 'r1')));
  });

  it('一般同工读得到 settings', async () => {
    await assertSucceeds(
      getDoc(doc(asMember(), 'settings', 'roster_templates')),
    );
  });

  // 这是 isActiveUser() 存在的理由：后台删帐号只删 Firestore 文件，
  // Firebase Auth 帐号还活著，token 仍然有效。
  it('被删掉的帐号读不到服事表', async () => {
    await assertFails(getDoc(doc(asDeleted(), 'rosters', 'r1')));
  });

  it('被删掉的帐号读不到 settings', async () => {
    await assertFails(
      getDoc(doc(asDeleted(), 'settings', 'roster_templates')),
    );
  });

  it('未登入读不到服事表', async () => {
    await assertFails(getDoc(doc(asAnon(), 'rosters', 'r1')));
  });

  it('未登入读不到 settings', async () => {
    await assertFails(getDoc(doc(asAnon(), 'settings', 'roster_templates')));
  });

  // App 真正的读取路径是 collection query，不是单笔 getDoc
  // （FirestoreRosterRepository.getUpcomingRosters）。只测 getDoc 的话，
  // 把 rules 的 `allow read` 收窄成 `allow get` 也不会被抓到，但整个服事表
  // 画面会直接 permission-denied。
  it('一般同工可以用 App 的查询条件列出服事表', async () => {
    const snapshot = await assertSucceeds(
      getDocs(
        query(
          collection(asMember(), 'rosters'),
          where('date', '>=', Timestamp.fromDate(new Date('2020-01-01Z'))),
          orderBy('date'),
        ),
      ),
    );
    // 真的有读到资料，而不是「查询通过但结果为空」。
    assert.ok(snapshot.size >= 1, '应该至少读到一笔有 date 的 roster');
  });

  it('被删掉的帐号不能列出服事表', async () => {
    await assertFails(getDocs(collection(asDeleted(), 'rosters')));
  });

  it('未登入不能列出服事表', async () => {
    await assertFails(getDocs(collection(asAnon(), 'rosters')));
  });
});

describe('rosters / settings 写入', () => {
  it('一般同工不能改服事表', async () => {
    await assertFails(
      setDoc(doc(asMember(), 'rosters', 'r1'), {
        serviceName: '乱改',
        type: 'sundayService',
      }),
    );
  });

  it('管理员可以改服事表', async () => {
    await assertSucceeds(
      setDoc(doc(asAdmin(), 'rosters', 'r1'), {
        serviceName: '主日崇拜',
        type: 'sundayService',
      }),
    );
  });

  // role 只有 staff，靠 group 放行。牧区涵盖主日，所以动得了 r1。
  it('roster-editors 可以改自己牧区的服事表', async () => {
    await assertSucceeds(
      setDoc(doc(asRosterEditor(), 'rosters', 'r1'), {
        serviceName: '主日崇拜',
        type: 'sundayService',
      }),
    );
  });

  // 反过来：身分是小组长但没有 group，一样不能改。少了这条，把 inGroup() 误写
  // 回看 role 也不会有任何测试变红。
  it('没有 group 的小组长不能改服事表', async () => {
    await assertFails(
      setDoc(doc(asPlainLeader(), 'rosters', 'r1'), {
        serviceName: '乱改',
        type: 'sundayService',
      }),
    );
  });

  // 两个 group 正交：行事历编辑者碰不到服事表。
  it('calendar-editors 不能改服事表', async () => {
    await assertFails(
      setDoc(doc(asCalendarEditor(), 'rosters', 'r1'), {
        serviceName: '乱改',
        type: 'sundayService',
      }),
    );
  });

  it('一般同工不能改 settings', async () => {
    await assertFails(
      setDoc(doc(asMember(), 'settings', 'roster_templates'), { x: 1 }),
    );
  });

  // 范本是所有服事表的骨架，改坏会影响到每一个人，所以留在 admin。
  it('roster-editors 不能改 settings', async () => {
    await assertFails(
      setDoc(doc(asRosterEditor(), 'settings', 'roster_templates'), { x: 1 }),
    );
  });

  it('被删掉的帐号不能改服事表', async () => {
    await assertFails(
      setDoc(doc(asDeleted(), 'rosters', 'r1'), {
        serviceName: '乱改',
        type: 'sundayService',
      }),
    );
  });
});

// 编辑权（group）与牧区（zoneTypes）是两个轴：group 说「可以改服事表」，
// zoneTypes 说「可以改哪一本」。两个都要过。
//
// 这一组钉住的是实际发生过的问题：只属于青崇与儿主的人被加进 roster-editors
// 之后，连主日那本都动得了。
describe('rosters 的牧区范围', () => {
  it('青崇编辑者改得动自己牧区的服事表', async () => {
    await assertSucceeds(
      setDoc(doc(asYouthEditor(), 'rosters', 'r3'), {
        serviceName: '儿童主日学',
        type: 'children',
      }),
    );
  });

  it('青崇编辑者改不动主日的服事表', async () => {
    await assertFails(
      setDoc(doc(asYouthEditor(), 'rosters', 'r1'), {
        serviceName: '乱改',
        type: 'sundayService',
      }),
    );
  });

  // 只检查写进去的 type 是不够的：那样可以把主日那本「改标成」青崇，一次写入
  // 就把它整本吃下来。旧的 type 也要在自己的牧区内。
  it('青崇编辑者不能把主日那本改标成青崇', async () => {
    await assertFails(
      setDoc(doc(asYouthEditor(), 'rosters', 'r1'), {
        serviceName: '偷天换日',
        type: 'youth',
      }),
    );
  });

  it('青崇编辑者建得出新的青崇服事表', async () => {
    await assertSucceeds(
      setDoc(doc(asYouthEditor(), 'rosters', 'new-youth'), {
        serviceName: '青年崇拜',
        type: 'youth',
      }),
    );
  });

  it('青崇编辑者建不出新的主日服事表', async () => {
    await assertFails(
      setDoc(doc(asYouthEditor(), 'rosters', 'new-sunday'), {
        serviceName: '主日崇拜',
        type: 'sundayService',
      }),
    );
  });

  it('青崇编辑者删得掉自己牧区的服事表', async () => {
    await assertSucceeds(deleteDoc(doc(asYouthEditor(), 'rosters', 'doomed-youth')));
  });

  it('青崇编辑者删不掉主日的服事表', async () => {
    await assertFails(deleteDoc(doc(asYouthEditor(), 'rosters', 'doomed-sunday')));
  });

  // 既有帐号全都是这个形状（没有 zoneTypes 栏位）。`data.get('zoneTypes', [])`
  // 让它们读成「没有牧区」而不是规则报错，结果是什么都改不动 —— 所以上线前要
  // 先跑 scripts/backfill-user-zone-types.mjs 把栏位补上。
  it('没有牧区的编辑者什么都改不动', async () => {
    await assertFails(
      setDoc(doc(asZonelessEditor(), 'rosters', 'r3'), {
        serviceName: '乱改',
        type: 'children',
      }),
    );
  });

  it('编辑者动不了没有 type 的旧资料', async () => {
    await assertFails(
      setDoc(doc(asRosterEditor(), 'rosters', 'legacy'), { serviceName: '乱改' }),
    );
  });

  // admin 是 root：没有 type 的旧资料要有人修得动，否则就没人修得动了。
  it('管理员动得了没有 type 的旧资料', async () => {
    await assertSucceeds(
      setDoc(doc(asAdmin(), 'rosters', 'legacy'), { serviceName: '补上 type', type: 'youth' }),
    );
  });

  // 一个牧区都没有的 admin 照样是 root。
  it('管理员不必有牧区也改得动全部', async () => {
    await assertSucceeds(
      setDoc(doc(asAdmin(), 'rosters', 'r3'), {
        serviceName: '儿童主日学',
        type: 'children',
      }),
    );
  });
});

describe('users 读取', () => {
  it('读得到自己的资料', async () => {
    await assertSucceeds(getDoc(doc(asMember(), 'users', MEMBER)));
  });

  // 收窄前：任何登入者都读得到全部人的 email 与 fcm token。
  it('一般同工读不到别人的资料', async () => {
    await assertFails(getDoc(doc(asMember(), 'users', OTHER)));
  });

  it('管理员读得到别人的资料', async () => {
    await assertSucceeds(getDoc(doc(asAdmin(), 'users', OTHER)));
  });

  it('被删掉的帐号读不到别人的资料', async () => {
    await assertFails(getDoc(doc(asDeleted(), 'users', MEMBER)));
  });

  it('未登入读不到任何人的资料', async () => {
    await assertFails(getDoc(doc(asAnon(), 'users', MEMBER)));
  });

  // 以下四条是「users 读取收窄」真正的重点。收窄前后 getDoc 自己那笔都会成功，
  // 差别只出现在 list：只测 getDoc 的话，有人加一条 `allow list: if isActiveUser()`
  // 就等于把全体同工的 email 与 fcm token 重新对所有登入者开放，而测试全绿。
  it('管理员可以列出整个 users collection（后台人员选择器走这条）', async () => {
    const snapshot = await assertSucceeds(
      getDocs(collection(asAdmin(), 'users')),
    );
    assert.ok(snapshot.size >= 3, '管理员应该读得到所有使用者');
  });

  // 服事表的人员选择器走 getUsers()，所以 roster-editors 必须列得到整个
  // collection。代价是他也看得到所有人的 email 与 fcm token —— Firestore rules
  // 没有栏位级读取限制，开这个 group 就是连带开这些。
  it('roster-editors 可以列出整个 users collection（服事表人员选择器走这条）', async () => {
    const snapshot = await assertSucceeds(
      getDocs(collection(asRosterEditor(), 'users')),
    );
    assert.ok(snapshot.size >= 3, 'roster-editors 应该读得到所有使用者');
  });

  it('一般同工不能列出 users collection', async () => {
    await assertFails(getDocs(collection(asMember(), 'users')));
  });

  // 只有行事历权限的人没有理由读通讯录，所以 users 读取绑的是 roster-editors
  // 而不是「任何 group」。
  it('calendar-editors 不能列出 users collection', async () => {
    await assertFails(getDocs(collection(asCalendarEditor(), 'users')));
  });

  // 加上 where 条件也不行：rules 不是过滤器，list 一律整批拒绝。
  it('一般同工不能用 where 条件迂回列出 users', async () => {
    await assertFails(
      getDocs(query(collection(asMember(), 'users'), where('id', '==', MEMBER))),
    );
    await assertFails(
      getDocs(
        query(collection(asMember(), 'users'), where('role', '==', 'admin')),
      ),
    );
  });

  it('被删掉的帐号不能列出 users collection', async () => {
    await assertFails(getDocs(collection(asDeleted(), 'users')));
  });

  // users/{uid} 的 match 不涵盖子集合，只靠最后的 default deny 挡。
  it('users 底下的子集合连本人与管理员都读不到', async () => {
    await assertFails(
      getDoc(doc(asMember(), 'users', MEMBER, 'private', 'secret')),
    );
    await assertFails(
      getDoc(doc(asAdmin(), 'users', MEMBER, 'private', 'secret')),
    );
  });
});

describe('users 自我更新', () => {
  // PushNotificationService._saveToken 走的就是这条（set + merge）。
  it('可以写自己的 fcm token', async () => {
    await assertSucceeds(
      setDoc(
        doc(asMember(), 'users', MEMBER),
        { fcm: { webTokens: ['token-abc'] } },
        { merge: true },
      ),
    );
  });

  it('可以写自己的 notificationPrefs', async () => {
    await assertSucceeds(
      setDoc(
        doc(asMember(), 'users', MEMBER),
        { notificationPrefs: { weeklyRosterReminder: true } },
        { merge: true },
      ),
    );
  });

  it('不能把自己升成管理员', async () => {
    await assertFails(
      updateDoc(doc(asMember(), 'users', MEMBER), { role: 'admin' }),
    );
  });

  // group 模型最关键的一条：能自己加 group 的话，整个授权模型就等于不存在。
  it('不能把自己加进任何 group', async () => {
    await assertFails(
      updateDoc(doc(asMember(), 'users', MEMBER), {
        groups: ['roster-editors'],
      }),
    );
  });

  // 已经在某个 group 里的人也不能自己再多拿一个。
  it('group 成员不能自己再加别的 group', async () => {
    await assertFails(
      updateDoc(doc(asCalendarEditor(), 'users', CALENDAR_EDITOR), {
        groups: ['calendar-editors', 'roster-editors'],
      }),
    );
  });

  it('不能改自己的姓名或 zones（要透过管理员）', async () => {
    await assertFails(
      updateDoc(doc(asMember(), 'users', MEMBER), { name: '自己改的' }),
    );
    await assertFails(
      updateDoc(doc(asMember(), 'users', MEMBER), {
        zones: [{ serviceType: 'sundayService', ministries: [], smallGroups: [] }],
      }),
    );
  });

  it('不能改别人的 fcm', async () => {
    await assertFails(
      setDoc(
        doc(asMember(), 'users', OTHER),
        { fcm: { webTokens: ['token-xyz'] } },
        { merge: true },
      ),
    );
  });

  // selfUpdateOnlyTouches 的重点在 hasOnly，不在「有没有碰到 role」。
  // 只写 role 的攻击上面已经测了，但那条测试挡不住 hasOnly 被写成 hasAny：
  // hasAny 之下「只写 role」仍然会被拒绝（测试照样绿），而「fcm + role 一起写」
  // 就会过关，一次请求把自己升成 admin。这几条就是补那个洞。
  it('不能把 role 夹带在合法栏位里一起写入', async () => {
    await assertFails(
      setDoc(
        doc(asMember(), 'users', MEMBER),
        { fcm: { webTokens: ['token-evil'] }, role: 'admin' },
        { merge: true },
      ),
    );
    await assertFails(
      setDoc(
        doc(asMember(), 'users', MEMBER),
        { notificationPrefs: { weeklyRosterReminder: true }, role: 'admin' },
        { merge: true },
      ),
    );
  });

  it('不能把姓名夹带在合法栏位里一起写入', async () => {
    await assertFails(
      updateDoc(doc(asMember(), 'users', MEMBER), {
        fcm: { webTokens: ['token-evil'] },
        name: '自己改的',
      }),
    );
  });

  // 同时写两个合法栏位要放行：App 的通知开关流程就是先写 fcm 再写
  // notificationPrefs，若哪天合并成一次写入也不该被挡。
  it('可以一次写入 fcm 与 notificationPrefs', async () => {
    await assertSucceeds(
      setDoc(
        doc(asMember(), 'users', MEMBER),
        {
          fcm: { webTokens: ['token-both'] },
          notificationPrefs: { weeklyRosterReminder: false },
        },
        { merge: true },
      ),
    );
  });

  // PushNotificationService._saveToken 的实际写法：arrayUnion + serverTimestamp。
  // 上面那条用的是普通阵列，挡不住「未来加了 fcm 栏位型别验证却没考虑
  // sentinel 值」而让真正的 App 写入失败。
  it('可以用 App 实际的 arrayUnion + serverTimestamp 写法存 fcm token', async () => {
    await assertSucceeds(
      setDoc(
        doc(asMember(), 'users', MEMBER),
        {
          fcm: {
            webTokens: arrayUnion('token-real'),
            lastUpdatedAt: serverTimestamp(),
          },
        },
        { merge: true },
      ),
    );
  });

  // 管理员自己也会跑 _saveToken。这条走的是 update 规则的 isAdmin 分支，
  // 而该分支带著 hasValidRole()，所以要确认 merge 写入不会被自己的验证挡掉。
  it('管理员也可以写自己的 fcm token', async () => {
    await assertSucceeds(
      setDoc(
        doc(asAdmin(), 'users', ADMIN),
        {
          fcm: {
            webTokens: arrayUnion('admin-token'),
            lastUpdatedAt: serverTimestamp(),
          },
        },
        { merge: true },
      ),
    );
  });

  it('不能整份覆写自己的文件（set 不带 merge）', async () => {
    await assertFails(
      setDoc(doc(asMember(), 'users', MEMBER), userDoc(MEMBER, 'admin')),
    );
  });

  // 被删掉的帐号对自己的文件做 set(merge) 会落在 create 规则（文件不存在），
  // 而 create 只开给管理员 —— 所以无法自己把自己救回来重新取得读取权。
  it('被删掉的帐号不能用 set(merge) 把自己的文件写回来', async () => {
    await assertFails(
      setDoc(
        doc(asDeleted(), 'users', DELETED),
        { fcm: { webTokens: ['revive'] } },
        { merge: true },
      ),
    );
    await assertFails(
      setDoc(doc(asDeleted(), 'users', DELETED), userDoc(DELETED, 'member')),
    );
  });
});

describe('users 管理员操作与 role 验证', () => {
  it('管理员可以用合法 role 建立帐号', async () => {
    await assertSucceeds(
      setDoc(doc(asAdmin(), 'users', 'new-staff'), userDoc('new-staff', 'staff')),
    );
  });

  it('管理员不能写入不合法的 role', async () => {
    await assertFails(
      setDoc(
        doc(asAdmin(), 'users', 'new-bogus'),
        userDoc('new-bogus', 'superuser'),
      ),
    );
  });

  it('管理员不能把既有帐号改成不合法的 role', async () => {
    await assertFails(
      updateDoc(doc(asAdmin(), 'users', OTHER), { role: 'root' }),
    );
  });

  // 唯一的管理员删掉或降级自己，就没有人能再管这个网站。
  it('管理员不能删除自己', async () => {
    await assertFails(deleteDoc(doc(asAdmin(), 'users', ADMIN)));
  });

  it('管理员不能把自己降成非管理员', async () => {
    await assertFails(updateDoc(doc(asAdmin(), 'users', ADMIN), { role: 'staff' }));
  });

  it('管理员可以改自己的其他资料', async () => {
    await assertSucceeds(updateDoc(doc(asAdmin(), 'users', ADMIN), { name: '管理员改名' }));
  });

  // 只挡自己：有两位以上管理员时，可以互相降级或删除（例如交接给别人）。
  it('管理员可以把另一位管理员降成组员', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'users', 'second-admin'), userDoc('second-admin', 'admin')));
    await assertSucceeds(updateDoc(doc(asAdmin(), 'users', 'second-admin'), { role: 'member' }));
  });

  it('管理员可以删除另一位管理员', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'users', 'third-admin'), userDoc('third-admin', 'admin')));
    await assertSucceeds(deleteDoc(doc(asAdmin(), 'users', 'third-admin')));
  });

  it('管理员可以删除别人', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'users', 'to-remove'), userDoc('to-remove', 'staff')));
    await assertSucceeds(deleteDoc(doc(asAdmin(), 'users', 'to-remove')));
  });

  it('管理员可以调整别人的 role', async () => {
    await assertSucceeds(
      updateDoc(doc(asAdmin(), 'users', OTHER), { role: 'staff' }),
    );
  });

  it('管理员可以授予 group', async () => {
    await assertSucceeds(
      setDoc(
        doc(asAdmin(), 'users', 'granted-new'),
        userDoc('granted-new', 'member', ['calendar-editors']),
      ),
    );
  });

  // 名字打错会变成一个看起来像授权、实际上什么都不对应的栏位。
  it('管理员不能写入不存在的 group 名称', async () => {
    await assertFails(
      setDoc(
        doc(asAdmin(), 'users', 'granted-bogus'),
        userDoc('granted-bogus', 'member', ['calendar-editor']),
      ),
    );
  });

  it('管理员可以授予牧区', async () => {
    await assertSucceeds(
      setDoc(
        doc(asAdmin(), 'users', 'zoned-new'),
        userDoc('zoned-new', 'member', ['roster-editors'], ['youth']),
      ),
    );
  });

  // 同 group：打错的聚会别会变成一个看起来像授权、实际上对不到任何服事表的栏位。
  it('管理员不能写入不存在的聚会别', async () => {
    await assertFails(
      setDoc(
        doc(asAdmin(), 'users', 'zoned-bogus'),
        userDoc('zoned-bogus', 'member', ['roster-editors'], ['sunday']),
      ),
    );
  });

  it('管理员可以把 group 收回成空阵列', async () => {
    await assertSucceeds(
      updateDoc(doc(asAdmin(), 'users', GRANTED), { groups: [] }),
    );
  });

  it('一般同工不能建立帐号', async () => {
    await assertFails(
      setDoc(doc(asMember(), 'users', 'sneaky'), userDoc('sneaky', 'admin')),
    );
  });

  it('一般同工不能删帐号', async () => {
    await assertFails(deleteDoc(doc(asMember(), 'users', OTHER)));
  });

  // 自己准备要被删的文件，不要依赖上面「管理员可以用合法 role 建立帐号」
  // 留下来的 new-staff：那种隐性顺序相依会让单独跑一条测试时整个爆掉。
  it('管理员可以删帐号', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'users', 'doomed-1'),
        userDoc('doomed-1', 'member'),
      );
    });
    await assertSucceeds(deleteDoc(doc(asAdmin(), 'users', 'doomed-1')));
  });

  // 旧资料可能没有 role 栏位。hasValidRole() 读的是「写入后的完整文件」，
  // 所以只改 name 会因为 role 不存在而被挡；管理员必须顺手补上 role。
  // 后台的 updateUser 走的是 user.toJson() 全栏位覆写，一定带 role，所以
  // 正常操作不受影响 —— 这条是把这个边界行为钉住，避免有人误判成 rules 坏了。
  it('没有 role 栏位的旧资料：只改其他栏位会被挡，补上 role 才能改', async () => {
    await assertFails(
      updateDoc(doc(asAdmin(), 'users', LEGACY), { name: '只改名字' }),
    );
    await assertSucceeds(
      updateDoc(doc(asAdmin(), 'users', LEGACY), {
        name: '补上 role',
        role: 'member',
      }),
    );
  });

  // role 栏位不能被删掉：删掉之后 hasValidRole() 会直接评估失败，
  // 该使用者的文件就再也不能用「只改一半栏位」的方式维护了。
  it('管理员不能删掉 role 栏位', async () => {
    await assertFails(
      updateDoc(doc(asAdmin(), 'users', OTHER), { role: deleteField() }),
    );
  });
});

describe('staff_orders 同工排序', () => {
  const ranking = { roles: { 招待: ['甲', '乙'] } };

  it('一般同工读得到', async () => {
    await assertSucceeds(getDoc(doc(asMember(), 'staff_orders', 'youth')));
  });

  it('被删掉的帐号读不到', async () => {
    await assertFails(getDoc(doc(asDeleted(), 'staff_orders', 'youth')));
  });

  it('一般同工改不动', async () => {
    await assertFails(setDoc(doc(asMember(), 'staff_orders', 'youth'), ranking));
  });

  // 排序是在选人视窗里拖的，编辑者一定要写得动自己牧区那份 —— 放在
  // settings/ 底下就会卡在这里。
  it('青崇编辑者改得动青崇的排序', async () => {
    await assertSucceeds(setDoc(doc(asYouthEditor(), 'staff_orders', 'youth'), ranking));
  });

  it('青崇编辑者改不动主日的排序', async () => {
    await assertFails(
      setDoc(doc(asYouthEditor(), 'staff_orders', 'sundayService'), ranking),
    );
  });

  it('没有牧区的编辑者什么都改不动', async () => {
    await assertFails(
      setDoc(doc(asZonelessEditor(), 'staff_orders', 'children'), ranking),
    );
  });

  it('管理员改得动任何崇拜的排序', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'staff_orders', 'sundayService'), ranking));
  });

  // App 只写有变的服事项目（merge），不整份覆写：别人刚改过的其他项目不能
  // 被盖掉，拿掉的项目用 deleteField()。
  it('merge 写入只动提到的服事项目', async () => {
    const ref = doc(asYouthEditor(), 'staff_orders', 'children');
    await assertSucceeds(
      setDoc(ref, { roles: { 招待: ['甲', '乙'], 司琴: ['丙'] } }),
    );
    await assertSucceeds(
      setDoc(ref, { roles: { 招待: ['乙', '甲'], 司琴: deleteField() } }, { merge: true }),
    );
    await assertSucceeds(
      setDoc(ref, { roles: { 敬拜: ['丁'] } }, { merge: true }),
    );
    const snapshot = await getDoc(ref);
    assert.deepEqual(snapshot.data(), { roles: { 招待: ['乙', '甲'], 敬拜: ['丁'] } });
  });

  it('不是崇拜的文件 id 连管理员都写不进去', async () => {
    await assertFails(setDoc(doc(asAdmin(), 'staff_orders', 'sundaySevice'), ranking));
  });
});

describe('生成设定：自订第四聚会、停用聚会与日期格式', () => {
  it('第四聚会保持 admin / roster-editors + zone 的授权边界', async () => {
    const uid = 'midweek-editor';
    await assertSucceeds(setDoc(doc(asAdmin(), 'users', uid),
      userDoc(uid, 'staff', ['roster-editors'], ['midweek', 'retired'])));
    const db = testEnv.authenticatedContext(uid).firestore();
    const roster = { type: 'midweek', dateKey: '2030-01-02', date: Timestamp.fromDate(new Date('2030-01-02T00:00:00Z')) };
    await assertSucceeds(setDoc(doc(db, 'rosters', '2030-01-02_midweek'), roster));
    await assertSucceeds(setDoc(doc(db, 'staff_orders', 'midweek'), { roles: {} }));
    await assertSucceeds(getDoc(doc(asMember(), 'rosters', '2030-01-02_midweek')));
    await assertFails(updateDoc(doc(asYouthEditor(), 'rosters', '2030-01-02_midweek'), { type: 'youth' }));
    await assertFails(setDoc(doc(asYouthEditor(), 'rosters', 'another-midweek'), roster));
    await assertFails(setDoc(doc(db, 'rosters', 'another-sunday'), { type: 'sundayService' }));
    await assertFails(setDoc(doc(asMember(), 'rosters', 'member-midweek'), roster));
    // Hiding an ID is not deleting its historical records or permission grants.
    await assertSucceeds(setDoc(doc(db, 'rosters', 'old-retired'), { type: 'retired', dateKey: '2030-01-07' }));
    await assertSucceeds(getDoc(doc(asMember(), 'rosters', 'old-retired')));
    await assertSucceeds(updateDoc(doc(db, 'rosters', 'old-retired'), { serviceName: '旧聚会' }));
  });

  it('未知 incoming type 连 admin 也不能建立或改写', async () => {
    await assertFails(setDoc(doc(asAdmin(), 'rosters', 'unknown-type'), { type: 'not-configured' }));
    await assertFails(updateDoc(doc(asAdmin(), 'rosters', 'r2'), { type: 'not-configured' }));
    await assertFails(setDoc(doc(asAdmin(), 'users', 'unknown-zone'), userDoc('unknown-zone', 'staff', [], ['not-configured'])));
  });

  it('dateKey 有正确格式，旧 Timestamp-only 仍可读写', async () => {
    const ref = doc(asAdmin(), 'rosters', 'date-key-test');
    await assertSucceeds(setDoc(ref, { type: 'midweek', dateKey: '2030-01-02' }));
    for (const dateKey of ['2030-13-02', '2030-01-00', '2030/01/02', '2030-1-2', 20300102, null]) {
      await assertFails(updateDoc(ref, { dateKey }));
    }
    await assertSucceeds(setDoc(doc(asAdmin(), 'rosters', '2030-01-09_midweek'), {
      type: 'midweek', date: Timestamp.fromDate(new Date('2030-01-09T00:00:00Z')),
    }));
    await assertSucceeds(getDoc(doc(asMember(), 'rosters', '2030-01-09_midweek')));
  });
});

describe('预设拒绝', () => {
  it('未定义的 collection 一律拒绝，连管理员也是', async () => {
    await assertFails(getDoc(doc(asAdmin(), 'anything', 'x')));
    await assertFails(setDoc(doc(asAdmin(), 'anything', 'x'), { a: 1 }));
  });
});


// Dart 的 rosterWeekDocumentIds 测试钉住相同的七个 ID；这里验证实际
// Firestore optimistic transaction 在两个不同目标日期之间仍会冲突并重试。
describe('排表并行建立', () => {
  it('不同星期设定同时看到空周，也只会建立一场', { timeout: 20_000 }, async () => {
    const ids = [
      '20260928_midweek', '20260929_midweek', '20260930_midweek',
      '20261001_midweek', '20261002_midweek', '20261003_midweek', '20261004_midweek',
    ];
    let arrivals = 0;
    let attempts = 0;
    let release;
    const bothHaveRead = new Promise((resolve) => { release = resolve; });
    const create = (targetIndex) => {
      const db = testEnv.authenticatedContext(ADMIN).firestore();
      let firstAttempt = true;
      return runTransaction(db, async (transaction) => {
        attempts++;
        const snapshots = await Promise.all(ids.map((id) => transaction.get(doc(db, 'rosters', id))));
        if (firstAttempt) {
          firstAttempt = false;
          if (++arrivals === 2) release();
          await bothHaveRead;
        }
        if (snapshots.some((snapshot) => snapshot.exists())) return false;
        const key = ids[targetIndex].slice(0, 8);
        const dateKey = key.slice(0, 4) + '-' + key.slice(4, 6) + '-' + key.slice(6, 8);
        transaction.set(doc(db, 'rosters', ids[targetIndex]), {
          type: 'midweek', dateKey, date: Timestamp.fromDate(new Date(dateKey + 'T00:00:00Z')),
          serviceName: '周间聚会', duties: [],
        });
        return true;
      });
    };
    try {
      const results = await Promise.all([create(4), create(6)]);
      assert.equal(results.filter(Boolean).length, 1);
      assert.ok(attempts >= 3, '第二个 transaction 必须因相同周的读取冲突而重试');
      const snapshots = await Promise.all(ids.map((id) => getDoc(doc(asAdmin(), 'rosters', id))));
      assert.equal(snapshots.filter((snapshot) => snapshot.exists()).length, 1);
    } finally {
      const snapshots = await Promise.all(ids.map((id) => getDoc(doc(asAdmin(), 'rosters', id))));
      await Promise.all(snapshots.filter((snapshot) => snapshot.exists()).map((snapshot) => deleteDoc(snapshot.ref)));
    }
  });
});

// 管理员在 App 里新增的聚会（settings/services）。ids 只能增加：删掉一个 ID，
// 用过它的服事表和牧区权限就对不回去了。
describe('App 里设定的聚会', () => {
  const services = (...ids) => ids.map((id) => ({ id, label: id, name: id, weekday: 3, enabled: true }));

  it('一般同工不能改聚会设定', async () => {
    await assertFails(setDoc(doc(asRosterEditor(), 'settings', 'services'), { services: services('prayer'), ids: ['prayer'] }));
  });

  it('管理员新增聚会后，那个聚会的服事表才写得进去', async () => {
    const roster = { type: 'prayer', dateKey: '2030-01-02', serviceName: '祷告会' };
    await assertFails(setDoc(doc(asAdmin(), 'rosters', '20300102_prayer'), roster));
    await assertSucceeds(setDoc(doc(asAdmin(), 'settings', 'services'), {
      services: services('sundayService', 'prayer'), ids: ['sundayService', 'youth', 'children', 'prayer'],
    }));
    await assertSucceeds(setDoc(doc(asAdmin(), 'rosters', '20300102_prayer'), roster));
    // 同工的牧区也可以设到新的聚会。
    await assertSucceeds(updateDoc(doc(asAdmin(), 'users', OTHER), { zoneTypes: ['prayer'] }));
  });

  it('ids 只能增加，不能拿掉用过的聚会', async () => {
    await assertFails(setDoc(doc(asAdmin(), 'settings', 'services'), {
      services: services('sundayService'), ids: ['sundayService'],
    }));
    await assertSucceeds(setDoc(doc(asAdmin(), 'settings', 'services'), {
      services: services('sundayService'), ids: ['sundayService', 'youth', 'children', 'prayer', 'choir'],
    }));
  });

  it('聚会设定不能删除，也不能塞别的栏位或空清单', async () => {
    await assertFails(deleteDoc(doc(asAdmin(), 'settings', 'services')));
    await assertFails(setDoc(doc(asAdmin(), 'settings', 'services'), {
      services: services('sundayService'), ids: ['sundayService', 'youth', 'children', 'prayer', 'choir'], extra: true,
    }));
    await assertFails(setDoc(doc(asAdmin(), 'settings', 'services'), {
      services: [], ids: ['sundayService', 'youth', 'children', 'prayer', 'choir'],
    }));
  });

  it('没在 ids 里的聚会还是写不进去', async () => {
    await assertFails(setDoc(doc(asAdmin(), 'rosters', '20300102_wedding'), { type: 'wedding', dateKey: '2030-01-02' }));
  });

  it('其他设定照旧只有管理员能写、也能删', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'settings', 'scratch'), { x: 1 }));
    await assertSucceeds(deleteDoc(doc(asAdmin(), 'settings', 'scratch')));
    await assertFails(setDoc(doc(asMember(), 'settings', 'scratch'), { x: 1 }));
  });
});
