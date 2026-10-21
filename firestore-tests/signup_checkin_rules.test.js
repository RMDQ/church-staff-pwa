// 自助注册与打卡纪录的安全规则测试，跑在 Firestore emulator 上。
//
//   cd firestore-tests && npm test
//
// 规则的约定：
// - signup_requests/{uid}：本人只能建立自己的待审申请；申请不能修改；
//   管理员可以读与删。待审的人没有 users 文件，所以读不到任何其他资料。
// - users/{uid}：仍然只有管理员能建立。通过申请时是管理员建立的。
// - checkins/{id}：只能由 functions/api/checkin.js 写入（用服务帐号，绕过规则）。
//   客户端一律不能写；本人只能读自己的纪录。
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
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} from 'firebase/firestore';

const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST ?? '127.0.0.1:8181').split(':');

let testEnv;

const ADMIN = 'admin-signup';
const MEMBER = 'member-signup';
const APPLICANT = 'applicant-1';
const APPLICANT_EMAIL = 'applicant@example.com';
const OTHER_APPLICANT = 'applicant-2';

function userDoc(id, role, groups) {
  const document = {
    id,
    name: `姓名-${id}`,
    email: `${id}@example.com`,
    username: id,
    role,
    zones: [],
  };
  if (groups !== undefined) document.groups = groups;
  return document;
}

/// 一份符合 App 送出格式的待审申请。
function requestDoc(overrides = {}) {
  return {
    name: '王小明',
    email: APPLICANT_EMAIL,
    consentAt: serverTimestamp(),
    consentVersion: '2026-10',
    status: 'pending',
    createdAt: serverTimestamp(),
    ...overrides,
  };
}

/// 管理员通过申请时建立的组员文件。
function approvedMemberDoc(uid) {
  return {
    id: uid,
    name: '王小明',
    email: APPLICANT_EMAIL,
    username: '王小明',
    role: 'member',
    zones: [],
    groups: [],
  };
}

function asApplicant() {
  return testEnv.authenticatedContext(APPLICANT, { email: APPLICANT_EMAIL }).firestore();
}
function asOtherApplicant() {
  return testEnv.authenticatedContext(OTHER_APPLICANT, { email: 'other@example.com' }).firestore();
}
function asAdmin() {
  return testEnv.authenticatedContext(ADMIN).firestore();
}
function asMember() {
  return testEnv.authenticatedContext(MEMBER).firestore();
}
function asAnon() {
  return testEnv.unauthenticatedContext().firestore();
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-church-signup',
    firestore: {
      rules: renderRules(readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'), defaults),
      host,
      port: Number(port),
    },
  });

  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', ADMIN), userDoc(ADMIN, 'admin'));
    await setDoc(doc(db, 'users', MEMBER), userDoc(MEMBER, 'member', []));
    await setDoc(doc(db, 'checkins', `2026-10-04_${MEMBER}`), {
      uid: MEMBER,
      name: '姓名',
      serviceId: 'sundayService',
      date: '2026-10-04',
      time: '13:10',
      status: 'onTime',
      distanceMeters: 22,
      latitude: 41.8919,
      longitude: 12.4839,
      createdAt: Timestamp.now(),
    });
    await setDoc(doc(db, 'checkins', `2026-10-04_${OTHER_APPLICANT}`), {
      uid: OTHER_APPLICANT,
      name: '别人',
      serviceId: 'sundayService',
      date: '2026-10-04',
      time: '13:20',
      status: 'onTime',
      distanceMeters: 20,
      latitude: 41.8919,
      longitude: 12.4839,
      createdAt: Timestamp.now(),
    });
    await setDoc(doc(db, 'signup_requests', OTHER_APPLICANT), requestDoc({ email: 'other@example.com', name: '别人' }));
  });
});

after(async () => {
  await testEnv?.cleanup();
});

describe('signup_requests：提交申请', () => {
  it('本人可以建立自己的待审申请', async () => {
    await assertSucceeds(setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc()));
  });

  it('不能替别人提交申请', async () => {
    await assertFails(setDoc(doc(asApplicant(), 'signup_requests', OTHER_APPLICANT), requestDoc()));
  });

  it('状态只能是 pending，不能直接写成 approved', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ status: 'approved' })),
    );
  });

  it('Email 必须等于登入帐号的 Email，不能用别人的邮箱', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ email: 'someone@else.com' })),
    );
  });

  it('不能夹带 role 之类的额外栏位', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ role: 'admin' })),
    );
  });

  it('没有同意时间就不能提交', async () => {
    const data = requestDoc();
    delete data.consentAt;
    await assertFails(setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), data));
  });

  it('建立时间必须由伺服器给，不能由客户端自己填', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ createdAt: new Date(0) })),
    );
  });

  it('姓名不能是空的', async () => {
    await assertFails(setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ name: '' })));
  });

  it('未登入不能提交', async () => {
    await assertFails(setDoc(doc(asAnon(), 'signup_requests', APPLICANT), requestDoc()));
  });

  it('已经是正式成员的人不能再提交申请', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users', 'already-member'), userDoc('already-member', 'member', []));
    });
    const member = testEnv.authenticatedContext('already-member', { email: 'already-member@example.com' }).firestore();
    await assertFails(
      setDoc(doc(member, 'signup_requests', 'already-member'), requestDoc({ email: 'already-member@example.com' })),
    );
  });
});

describe('signup_requests：读取、修改、删除', () => {
  it('本人可以读自己的申请（用来显示「等待确认」）', async () => {
    await assertSucceeds(getDoc(doc(asApplicant(), 'signup_requests', APPLICANT)));
  });

  it('不能读别人的申请', async () => {
    await assertFails(getDoc(doc(asApplicant(), 'signup_requests', OTHER_APPLICANT)));
  });

  it('待审的人读不到任何正式资料（没有 users 文件）', async () => {
    await assertFails(getDoc(doc(asApplicant(), 'users', MEMBER)));
    await assertFails(getDoc(doc(asApplicant(), 'rosters', 'anything')));
  });

  it('本人不能修改自己的申请', async () => {
    await assertFails(updateDoc(doc(asApplicant(), 'signup_requests', APPLICANT), { status: 'approved' }));
  });

  it('本人不能删除自己的申请', async () => {
    await assertFails(deleteDoc(doc(asApplicant(), 'signup_requests', APPLICANT)));
  });

  it('管理员可以读别人的申请', async () => {
    await assertSucceeds(getDoc(doc(asAdmin(), 'signup_requests', OTHER_APPLICANT)));
  });

  it('一般会众不能读别人的申请', async () => {
    await assertFails(getDoc(doc(asMember(), 'signup_requests', OTHER_APPLICANT)));
  });

  it('管理员可以删除申请（拒绝或通过后）', async () => {
    await assertSucceeds(deleteDoc(doc(asAdmin(), 'signup_requests', OTHER_APPLICANT)));
  });
});

describe('通过申请：管理员建立正式成员', () => {
  it('管理员可以依申请建立组员文件', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'users', APPLICANT), approvedMemberDoc(APPLICANT)));
  });

  it('申请人不能自己建立正式成员文件（即使身份填成组员）', async () => {
    await assertFails(setDoc(doc(asOtherApplicant(), 'users', OTHER_APPLICANT), approvedMemberDoc(OTHER_APPLICANT)));
  });

  it('会众不能替别人建立成员文件', async () => {
    await assertFails(setDoc(doc(asMember(), 'users', 'someone-new'), approvedMemberDoc('someone-new')));
  });

  it('会众不能自己加上群组（自助注册之后也不能）', async () => {
    await assertFails(updateDoc(doc(asMember(), 'users', MEMBER), { groups: ['roster-editors'] }));
  });

  it('会众不能自己升成管理员', async () => {
    await assertFails(updateDoc(doc(asMember(), 'users', MEMBER), { role: 'admin' }));
  });
});

describe('checkins：只能读，不能由客户端写', () => {
  it('本人可以读自己的打卡纪录', async () => {
    await assertSucceeds(getDoc(doc(asMember(), 'checkins', `2026-10-04_${MEMBER}`)));
  });

  it('不能读别人的打卡纪录', async () => {
    await assertFails(getDoc(doc(asMember(), 'checkins', `2026-10-04_${OTHER_APPLICANT}`)));
  });

  it('未登入不能读', async () => {
    await assertFails(getDoc(doc(asAnon(), 'checkins', `2026-10-04_${MEMBER}`)));
  });

  it('本人不能自己写入打卡纪录（绕过 functions 的时间与距离判断）', async () => {
    await assertFails(
      setDoc(doc(asMember(), 'checkins', `2026-10-05_${MEMBER}`), {
        uid: MEMBER,
        status: 'onTime',
        distanceMeters: 0,
        date: '2026-10-05',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('管理员也不能由客户端写入打卡纪录', async () => {
    await assertFails(
      setDoc(doc(asAdmin(), 'checkins', `2026-10-05_${ADMIN}`), {
        uid: ADMIN,
        status: 'onTime',
        distanceMeters: 0,
        date: '2026-10-05',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('本人不能修改或删除自己的打卡纪录', async () => {
    await assertFails(updateDoc(doc(asMember(), 'checkins', `2026-10-04_${MEMBER}`), { status: 'late' }));
    await assertFails(deleteDoc(doc(asMember(), 'checkins', `2026-10-04_${MEMBER}`)));
  });
});
