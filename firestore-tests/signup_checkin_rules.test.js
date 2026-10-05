// 自助注册與打卡紀錄的安全規則測試，跑在 Firestore emulator 上。
//
//   cd firestore-tests && npm test
//
// 規則的約定：
// - signup_requests/{uid}：本人只能建立自己的待審申請；申請不能修改；
//   管理員可以讀與刪。待審的人沒有 users 文件，所以讀不到任何其他資料。
// - users/{uid}：仍然只有管理員能建立。通過申請時是管理員建立的。
// - checkins/{id}：只能由 functions/api/checkin.js 寫入（用服務帳號，繞過規則）。
//   客戶端一律不能寫；本人只能讀自己的紀錄。
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

/// 一份符合 App 送出格式的待審申請。
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

/// 管理员通过申请時建立的組員文件。
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
  it('本人可以建立自己的待審申請', async () => {
    await assertSucceeds(setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc()));
  });

  it('不能替別人提交申請', async () => {
    await assertFails(setDoc(doc(asApplicant(), 'signup_requests', OTHER_APPLICANT), requestDoc()));
  });

  it('狀態只能是 pending，不能直接寫成 approved', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ status: 'approved' })),
    );
  });

  it('Email 必須等於登入帳號的 Email，不能用別人的郵箱', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ email: 'someone@else.com' })),
    );
  });

  it('不能夾帶 role 之類的額外欄位', async () => {
    await assertFails(
      setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), requestDoc({ role: 'admin' })),
    );
  });

  it('沒有同意時間就不能提交', async () => {
    const data = requestDoc();
    delete data.consentAt;
    await assertFails(setDoc(doc(asApplicant(), 'signup_requests', APPLICANT), data));
  });

  it('建立時間必須由伺服器給，不能由客戶端自己填', async () => {
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

  it('已經是正式成員的人不能再提交申請', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users', 'already-member'), userDoc('already-member', 'member', []));
    });
    const member = testEnv.authenticatedContext('already-member', { email: 'already-member@example.com' }).firestore();
    await assertFails(
      setDoc(doc(member, 'signup_requests', 'already-member'), requestDoc({ email: 'already-member@example.com' })),
    );
  });
});

describe('signup_requests：讀取、修改、刪除', () => {
  it('本人可以讀自己的申請（用來顯示「等待確認」）', async () => {
    await assertSucceeds(getDoc(doc(asApplicant(), 'signup_requests', APPLICANT)));
  });

  it('不能讀別人的申請', async () => {
    await assertFails(getDoc(doc(asApplicant(), 'signup_requests', OTHER_APPLICANT)));
  });

  it('待審的人讀不到任何正式資料（沒有 users 文件）', async () => {
    await assertFails(getDoc(doc(asApplicant(), 'users', MEMBER)));
    await assertFails(getDoc(doc(asApplicant(), 'rosters', 'anything')));
  });

  it('本人不能修改自己的申請', async () => {
    await assertFails(updateDoc(doc(asApplicant(), 'signup_requests', APPLICANT), { status: 'approved' }));
  });

  it('本人不能刪除自己的申請', async () => {
    await assertFails(deleteDoc(doc(asApplicant(), 'signup_requests', APPLICANT)));
  });

  it('管理員可以讀別人的申請', async () => {
    await assertSucceeds(getDoc(doc(asAdmin(), 'signup_requests', OTHER_APPLICANT)));
  });

  it('一般會眾不能讀別人的申請', async () => {
    await assertFails(getDoc(doc(asMember(), 'signup_requests', OTHER_APPLICANT)));
  });

  it('管理員可以刪除申請（拒絕或通過後）', async () => {
    await assertSucceeds(deleteDoc(doc(asAdmin(), 'signup_requests', OTHER_APPLICANT)));
  });
});

describe('通過申請：管理員建立正式成員', () => {
  it('管理員可以依申請建立組員文件', async () => {
    await assertSucceeds(setDoc(doc(asAdmin(), 'users', APPLICANT), approvedMemberDoc(APPLICANT)));
  });

  it('申請人不能自己建立正式成員文件（即使身份填成組員）', async () => {
    await assertFails(setDoc(doc(asOtherApplicant(), 'users', OTHER_APPLICANT), approvedMemberDoc(OTHER_APPLICANT)));
  });

  it('會眾不能替別人建立成員文件', async () => {
    await assertFails(setDoc(doc(asMember(), 'users', 'someone-new'), approvedMemberDoc('someone-new')));
  });

  it('會眾不能自己加上群組（自助註冊之後也不能）', async () => {
    await assertFails(updateDoc(doc(asMember(), 'users', MEMBER), { groups: ['roster-editors'] }));
  });

  it('會眾不能自己升成管理員', async () => {
    await assertFails(updateDoc(doc(asMember(), 'users', MEMBER), { role: 'admin' }));
  });
});

describe('checkins：只能讀，不能由客戶端寫', () => {
  it('本人可以讀自己的打卡紀錄', async () => {
    await assertSucceeds(getDoc(doc(asMember(), 'checkins', `2026-10-04_${MEMBER}`)));
  });

  it('不能讀別人的打卡紀錄', async () => {
    await assertFails(getDoc(doc(asMember(), 'checkins', `2026-10-04_${OTHER_APPLICANT}`)));
  });

  it('未登入不能讀', async () => {
    await assertFails(getDoc(doc(asAnon(), 'checkins', `2026-10-04_${MEMBER}`)));
  });

  it('本人不能自己寫入打卡紀錄（繞過 functions 的時間與距離判斷）', async () => {
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

  it('管理員也不能由客戶端寫入打卡紀錄', async () => {
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

  it('本人不能修改或刪除自己的打卡紀錄', async () => {
    await assertFails(updateDoc(doc(asMember(), 'checkins', `2026-10-04_${MEMBER}`), { status: 'late' }));
    await assertFails(deleteDoc(doc(asMember(), 'checkins', `2026-10-04_${MEMBER}`)));
  });
});
