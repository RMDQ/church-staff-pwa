import { TEST_CHURCH_CONFIG } from '../worker/church_config.js';
import { ENABLED_CONFIG } from './helpers.js';
// Tests for POST /api/roster/import-image.
//
// Same approach as calendar.test.js: no Miniflare, no wrangler dev. Node 22
// already gives fetch/Response/Headers, which is the surface the Workers
// runtime gives the function, and swapping the global fetch keeps the tests on
// the real wiring instead of a seam production never uses.

import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { onRequestPost, parseImportRequest, rejectOversizedBody } from '../functions/api/roster/import-image.js';
import { callGemini, extractJson, quotaResetText, RETRY_DELAYS_MS } from '../worker/gemini.js';
import {
  ADMIN_UID,
  CALENDAR_EDITOR_UID,
  MEMBER_UID,
  PROJECT_ID,
  ROSTER_EDITOR_UID,
  idToken,
  muteConsoleError,
  request,
  withFetch,
} from './helpers.js';

/// Gemini 免费层每日额度用完时的回应，原样。
const REAL_DAILY_QUOTA_429 = {
  "error": {
    "code": 429,
    "message": "You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits. To monitor your current usage, head to: https://ai.dev/rate-limit. \n* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: gemini-3.6-flash\nPlease retry in 51s.",
    "status": "RESOURCE_EXHAUSTED",
    "details": [
      {
        "@type": "type.googleapis.com/google.rpc.Help",
        "links": [
          {
            "description": "Learn more about Gemini API quotas",
            "url": "https://ai.google.dev/gemini-api/docs/rate-limits"
          }
        ]
      },
      {
        "@type": "type.googleapis.com/google.rpc.QuotaFailure",
        "violations": [
          {
            "quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests",
            "quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
            "quotaDimensions": {
              "model": "gemini-3.6-flash",
              "location": "global"
            },
            "quotaValue": "20"
          }
        ]
      },
      {
        "@type": "type.googleapis.com/google.rpc.RetryInfo",
        "retryDelay": "51s"
      }
    ]
  }
};


const GEMINI_HOST = 'https://generativelanguage.googleapis.com/';

/// 发布出去的是**模板**，不是完成品：{{...}} 那几个由 worker 每次呼叫时从
/// Firestore 现况填。名单烤进模板的话，新同工建完帐号还要有人记得重跑脚本。
const PUBLISHED_TEMPLATE =
  '把服事表照片转成 JSON。\n服事项目：{{ROLES}}\n活动：{{EVENTS}}\n' +
  '同工名单：\n{{NAMES}}\n今天是 {{TODAY}}。范例：{{SAMPLE_ROLE_A}}／{{SAMPLE_ROLE_B}}';
const PIXEL = 'aGVsbG8td29ybGQ=';

const ROLES = ['晨祷', '敬拜主领', 'Vocal'];
const EVENTS = ['圣餐', '爱餐'];
const STAFF = ['陈志明', '李大华'];

const ENV = {
  [TEST_CHURCH_CONFIG]: ENABLED_CONFIG,
  FIREBASE_PROJECT_ID: PROJECT_ID,
  GEMINI_API_KEY: 'test-gemini-key',
};

const ALL_TYPES = ['sundayService', 'youth', 'children'];

/// admin 刻意不给 zoneTypes：firestore.rules 的 canEditRosterType() 说
/// 「admin keeps every type without holding a zone」，这里要守住同一件事。
const USERS = {
  [ADMIN_UID]: { role: 'admin', name: '王管理' },
  [MEMBER_UID]: { role: 'member', name: '路人' },
  [ROSTER_EDITOR_UID]: {
    role: 'staff',
    groups: ['roster-editors'],
    name: '服事表同工',
    zoneTypes: ALL_TYPES,
  },
  [CALENDAR_EDITOR_UID]: { role: 'staff', groups: ['calendar-editors'], name: '行事历同工' },
};

const ROWS = [{ date: '2026-10-04', duties: [{ role: '敬拜主领', people: ['陈志明'] }] }];

/// Gemini 辨识成功的回应：模型把 ROWS 当成 JSON 文字吐回来。
function geminiOk() {
  return Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(ROWS) }] } }] });
}

/// Routes the two upstreams this function talks to and records every call, so a
/// test can assert what actually went to Gemini rather than only what came back.
function fakeFetch({
  prompts = { youth: PUBLISHED_TEMPLATE },
  gemini,
  roles = { youth: ROLES, children: ROLES, sundayService: ROLES },
  events = { youth: EVENTS },
  staff = STAFF,
  // 覆写服事表同工的牧区，用来测「有编辑权但没有那个牧区」。
  zones,
} = {}) {
  const calls = [];
  const impl = async (url, init = {}) => {
    const target = String(url);
    calls.push({ url: target, method: init.method ?? 'GET', body: init.body, init });

    // 列出整个 users 集合（没有 /{uid}），跟下面读单一使用者是两回事。
    if (target.includes('/documents/users?')) {
      return Response.json({
        documents: staff.map((name) => ({
          name: `users/${name}`,
          fields: { name: { stringValue: name } },
        })),
      });
    }

    if (target.includes('/documents/settings/roster_templates')) {
      return Response.json({
        fields: Object.fromEntries(
          Object.entries(roles).map(([type, list]) => [
            type,
            { arrayValue: { values: list.map((r) => ({ stringValue: r })) } },
          ]),
        ),
      });
    }

    if (target.includes('/documents/settings/event_options')) {
      return Response.json({
        fields: Object.fromEntries(
          Object.entries(events).map(([type, list]) => [
            type,
            {
              arrayValue: {
                values: list.map((name) => ({
                  mapValue: { fields: { name: { stringValue: name } } },
                })),
              },
            },
          ]),
        ),
      });
    }

    if (target.includes('/documents/users/')) {
      const uid = decodeURIComponent(target.split('/documents/users/')[1].split('?')[0]);
      if (!(uid in USERS)) return new Response('{}', { status: 404 });
      const profile = USERS[uid];
      const fields = {};
      if (profile.role != null) fields.role = { stringValue: profile.role };
      if (profile.name != null) fields.name = { stringValue: profile.name };
      if (profile.groups != null) {
        fields.groups = { arrayValue: { values: profile.groups.map((g) => ({ stringValue: g })) } };
      }
      const zoneTypes = uid === ROSTER_EDITOR_UID && zones ? zones : profile.zoneTypes;
      if (zoneTypes != null) {
        fields.zoneTypes = {
          arrayValue: { values: zoneTypes.map((t) => ({ stringValue: t })) },
        };
      }
      return Response.json({ name: `users/${uid}`, fields });
    }

    if (target.includes('/documents/settings/services')) return new Response('{}', { status: 404 });

    if (target.includes('/documents/settings/import_prompts')) {
      if (prompts === null) return new Response('{}', { status: 404 });
      const fields = Object.fromEntries(
        Object.entries(prompts).map(([type, body]) => [type, { stringValue: body }]),
      );
      return Response.json({ name: 'settings/import_prompts', fields });
    }

    if (target.startsWith(GEMINI_HOST)) {
      if (typeof gemini === 'function') return gemini(target, init, calls);
      return geminiOk();
    }

    throw new Error(`unexpected fetch to ${target}`);
  };
  impl.calls = calls;
  impl.geminiCalls = () => calls.filter((call) => call.url.startsWith(GEMINI_HOST));
  return impl;
}

function validBody(overrides = {}) {
  return { type: 'youth', images: [{ mimeType: 'image/png', data: PIXEL }], ...overrides };
}

/// body 与 token 都给预设值，这样只关心权限或上游的案例不必每次重写它们。
async function post(impl, { env = ENV, body = validBody(), ...init } = {}) {
  return withFetch(impl, () =>
    onRequestPost({
      request: request('POST', {
        token: idToken(ROSTER_EDITOR_UID),
        ...init,
        body,
        path: '/api/roster/import-image',
      }),
      env,
    }),
  );
}

// 谁可以转哪一个崇拜，由 authorize.test.js 逐条测。这里只证明这条路由真的有问、
// 问的是照片上的那个崇拜、顺序对（先认人，再读 body，再问牧区），而且被挡下来
// 的人不会花掉辨识额度。
describe('POST /api/roster/import-image — 权限', () => {
  test('roster-editors 可以转换', async () => {
    const impl = fakeFetch();
    const response = await post(impl);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { entries: ROWS });
  });

  test('有编辑权但没有那个牧区的人被挡下来，而且不花额度', async () => {
    const impl = fakeFetch({ zones: ['youth'] });
    const response = await post(impl, { body: validBody({ type: 'sundayService' }) });
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, '没有编辑这个崇拜服事表的权限');
    assert.equal(impl.geminiCalls().length, 0);
  });

  test('没带 token 就是 401', async () => {
    const impl = fakeFetch();
    const response = await post(impl, { token: null });
    assert.equal(response.status, 401);
    assert.equal(impl.geminiCalls().length, 0);
  });

  // 先认人再读 body：没登入的人送什么来都是 401，worker 也不替他解析 4MB 的 JSON。
  test('没登入又送坏掉的 body，一样是 401 不是 400', async () => {
    for (const body of ['{not json', validBody({ type: 'wedding', images: [] })]) {
      const response = await post(fakeFetch(), { token: null, body });
      assert.equal(response.status, 401);
    }
  });

  test('不在 roster-editors 的人送坏掉的 body，是 403 不是 400', async () => {
    const response = await post(fakeFetch(), {
      token: idToken(CALENDAR_EDITOR_UID),
      body: '{not json',
    });
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, '没有编辑服事表的权限');
  });
});

describe('POST /api/roster/import-image — 送出去的东西', () => {
  test('带著发布好的 prompt 与照片，key 走 header 不走 query string', async () => {
    const impl = fakeFetch();
    await post(impl, { body: validBody() });

    const [call] = impl.geminiCalls();
    assert.equal(call.method, 'POST');
    assert.ok(
      !call.url.includes('key='),
      'API key 不可以出现在网址里 —— query string 会进存取日志',
    );
    assert.equal(call.init.headers['X-goog-api-key'], 'test-gemini-key');

    const sent = JSON.parse(call.body);
    const prompt = sent.contents[0].parts[0].text;
    assert.ok(!prompt.includes('{{'), `送出去的 prompt 还有没填的栏位：${prompt}`);
    assert.ok(prompt.includes('晨祷、敬拜主领、Vocal'));
    // 排序后的顺序是名单决定的，这里在意的是「两个都在」而不是谁先谁后。
    for (const name of STAFF) assert.ok(prompt.includes(name), `名单少了 ${name}`);
    assert.deepEqual(sent.contents[0].parts[1], {
      inline_data: { mime_type: 'image/png', data: PIXEL },
    });
    // 同一张表每次都要转出同一份，这里没有创意的空间。
    assert.equal(sent.generationConfig.temperature, 0);
    assert.equal(sent.generationConfig.responseMimeType, 'application/json');
  });

  test('用的是该崇拜自己的 prompt，不是随便一个', async () => {
    const impl = fakeFetch({
      prompts: {
        youth: `青崇用的 ${PUBLISHED_TEMPLATE}`,
        children: `儿主用的 ${PUBLISHED_TEMPLATE}`,
        sundayService: `主日用的 ${PUBLISHED_TEMPLATE}`,
      },
    });
    await post(impl, { body: validBody({ type: 'children' }) });
    assert.ok(JSON.parse(impl.geminiCalls()[0].body).contents[0].parts[0].text.startsWith('儿主用的'));
  });

  test('多张照片照顺序一起送', async () => {
    const impl = fakeFetch();
    await post(impl, {
      body: validBody({
        images: [
          { mimeType: 'image/png', data: 'AAAA' },
          { mimeType: 'image/jpeg', data: 'BBBB' },
        ],
      }),
    });
    const parts = JSON.parse(impl.geminiCalls()[0].body).contents[0].parts;
    assert.equal(parts.length, 3, 'prompt 一份加上两张图');
    assert.equal(parts[1].inline_data.data, 'AAAA');
    assert.equal(parts[2].inline_data.data, 'BBBB');
  });

  test('读 Firestore 用的是呼叫者自己的 token', async () => {
    const impl = fakeFetch();
    const token = idToken(ROSTER_EDITOR_UID);
    await post(impl, { token, body: validBody() });
    const reads = impl.calls.filter((c) => c.url.includes('/documents/'));
    assert.ok(reads.length >= 2);
    for (const read of reads) {
      assert.equal(
        read.init.headers.Authorization,
        `Bearer ${token}`,
        'worker 不该用自己的权限读 —— firestore.rules 要继续是唯一的裁判',
      );
    }
  });
});

describe('POST /api/roster/import-image — 名单是活的', () => {
  // 这一组是这个设计存在的理由。名单烤进发布的模板里的话，新同工建完帐号
  // 还要有人记得回来重跑脚本 —— 而没有人会记得。
  test('新同工建了帐号就会出现在白名单，不必重新发布', async () => {
    const impl = fakeFetch({ staff: [...STAFF, '黄雅婷'] });
    await post(impl);
    const prompt = JSON.parse(impl.geminiCalls()[0].body).contents[0].parts[0].text;
    assert.ok(prompt.includes('黄雅婷'), '名单是每次呼叫才读的，不是发布当下的快照');
  });

  test('新增的服事项目与活动同样即时生效', async () => {
    const impl = fakeFetch({
      roles: { youth: [...ROLES, '报告'] },
      events: { youth: [...EVENTS, '福音 BIG DAY'] },
    });
    await post(impl);
    const prompt = JSON.parse(impl.geminiCalls()[0].body).contents[0].parts[0].text;
    assert.ok(prompt.includes('报告'));
    assert.ok(prompt.includes('福音 BIG DAY'));
  });

  // users 文件里还有 email 与 FCM token，那些没有理由进到送去 Google 的
  // prompt 里 —— 所以只跟 Firestore 要 name。
  test('读名单时只要 name 这个栏位', async () => {
    const impl = fakeFetch();
    await post(impl);
    const listing = impl.calls.find((c) => c.url.includes('/documents/users?'));
    assert.ok(listing, '应该要列一次 users');
    assert.ok(listing.url.includes('mask.fieldPaths=name'));
    assert.ok(!listing.url.includes('email'));
  });

  test('这个崇拜还没有服事项目时挡下来，不浪费一次辨识', async () => {
    const impl = fakeFetch({ roles: {} });
    const restore = muteConsoleError();
    try {
      const response = await post(impl);
      assert.equal(response.status, 500);
      assert.equal((await response.json()).error, '这个崇拜还没有服事项目设定，请管理员先新增');
      assert.equal(impl.geminiCalls().length, 0);
    } finally {
      restore();
    }
  });

  // 模板改了但 fillPrompt 没跟上时，带著 {{...}} 的字面值送出去，模型会把
  // 那串括号当成指令的一部分 —— 错得不明显，比直接失败糟。
  test('模板有 worker 不认得的栏位时，宁可失败也不送出去', async () => {
    const impl = fakeFetch({ prompts: { youth: `${PUBLISHED_TEMPLATE}\n{{SOMETHING_NEW}}` } });
    const restore = muteConsoleError();
    try {
      const response = await post(impl);
      assert.equal(response.status, 500);
      assert.equal(impl.geminiCalls().length, 0);
    } finally {
      restore();
    }
  });
});

describe('POST /api/roster/import-image — 请求验证', () => {
  const cases = [
    ['没有照片', validBody({ images: [] }), 400, '请先选一张服事表照片'],
    ['images 不是阵列', validBody({ images: 'nope' }), 400, '请先选一张服事表照片'],
    [
      '照片太多张',
      validBody({ images: Array.from({ length: 4 }, () => ({ mimeType: 'image/png', data: PIXEL })) }),
      400,
      '一次最多 3 张照片',
    ],
    [
      '格式不支援',
      validBody({ images: [{ mimeType: 'application/pdf', data: PIXEL }] }),
      400,
      '照片的格式不支援，请用 JPG 或 PNG',
    ],
    ['照片没有内容', validBody({ images: [{ mimeType: 'image/png', data: '' }] }), 400, '照片读不到内容，请重新选一次'],
  ];

  for (const [name, body, status, message] of cases) {
    test(name, () => {
      assert.throws(() => parseImportRequest(body), { status, message });
    });
  }

  test('太大的照片挡在前面，不会先送上去才失败', () => {
    const tooBig = 'A'.repeat(3 * 1024 * 1024);
    assert.throws(() => parseImportRequest(validBody({ images: [{ mimeType: 'image/png', data: tooBig }] })), {
      status: 413,
    });
  });

  test('整个请求太大时不读内容就挡掉', () => {
    // 读进来再挡就太晚了：解析一个几 MB 的 body 本身就会用完 CPU 额度，
    // Cloudflare 会先把 worker 砍掉，使用者只看得到「忙碌中」。
    const big = new Request('https://app.example/api/roster/import-image', {
      method: 'POST',
      headers: { 'content-length': String(5 * 1024 * 1024) },
    });
    assert.throws(() => rejectOversizedBody(big), { status: 413 });

    const small = new Request('https://app.example/api/roster/import-image', {
      method: 'POST',
      headers: { 'content-length': String(900 * 1024) },
    });
    assert.doesNotThrow(() => rejectOversizedBody(small));
  });

  test('多张时讯息会讲是第几张', () => {
    assert.throws(
      () =>
        parseImportRequest(
          validBody({
            images: [
              { mimeType: 'image/png', data: PIXEL },
              { mimeType: 'text/plain', data: PIXEL },
            ],
          }),
        ),
      { message: '第 2 张照片的格式不支援，请用 JPG 或 PNG' },
    );
  });

  test('坏掉的请求不会花掉辨识额度', async () => {
    const impl = fakeFetch();
    const restore = muteConsoleError();
    try {
      const response = await post(impl, { body: validBody({ type: 'wedding' }) });
      assert.equal(response.status, 400);
      assert.equal(impl.geminiCalls().length, 0);
    } finally {
      restore();
    }
  });
});

describe('POST /api/roster/import-image — prompt 还没发布', () => {
  test('没有那份文件时说去找管理员，而且不呼叫 Gemini', async () => {
    const impl = fakeFetch({ prompts: null });
    const restore = muteConsoleError();
    try {
      const response = await post(impl);
      assert.equal(response.status, 500);
      assert.equal((await response.json()).error, '辨识设定还没建立，请联络管理员');
      assert.equal(impl.geminiCalls().length, 0);
    } finally {
      restore();
    }
  });

  test('文件在但少了这个崇拜，一样挡下来', async () => {
    const impl = fakeFetch({ prompts: { youth: PUBLISHED_TEMPLATE } });
    const restore = muteConsoleError();
    try {
      const response = await post(impl, { body: validBody({ type: 'children' }) });
      assert.equal(response.status, 500);
      assert.equal(impl.geminiCalls().length, 0);
    } finally {
      restore();
    }
  });
});

describe('callGemini — 上游的各种回法', () => {
  const images = [{ mimeType: 'image/png', data: PIXEL }];

  async function call(gemini) {
    const impl = fakeFetch({ gemini });
    return callGemini(ENV, {
      prompt: PUBLISHED_TEMPLATE,
      images,
      fetchImpl: impl,
      // 正式环境会一路等 2 到 20 秒；测试不必真的等。
      retryDelaysMs: [0, 0],
    });
  }

  test('503 重试两次就停，不会一直重试下去', async () => {
    let attempts = 0;
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          call(() => {
            attempts += 1;
            return new Response('busy', { status: 503 });
          }),
        { status: 503, message: 'Gemini 免费版现在太多人用，过几分钟再试一次' },
      );
    } finally {
      restore();
    }
    assert.equal(attempts, 3, '一次原始呼叫加两次重试');
  });

  test('时间快用完就不再开始新的一次', async () => {
    // 一次成功要一分钟左右；太晚才开始的那一次，app 等不到它回来。
    let clock = 0;
    let attempts = 0;
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          callGemini(ENV, {
            prompt: 'x',
            images,
            retryDelaysMs: [0, 0, 0, 0],
            lastAttemptStartMs: 75000,
            now: () => clock,
            fetchImpl: async () => {
              attempts += 1;
              clock += 30000; // 每次 503 都拖 30 秒
              return new Response('busy', { status: 503 });
            },
          }),
        { status: 503 },
      );
    } finally {
      restore();
    }
    // 0 秒、30 秒、60 秒各开始一次；第 90 秒已经超过 75 秒，不再开始。
    assert.equal(attempts, 3);
  });

  test('连两次 503、第三次成功就当作成功', async () => {
    // 2026-09-23 实际碰到的就是这个顺序。
    let attempts = 0;
    const rows = await call(() => {
      attempts += 1;
      if (attempts <= 2) return new Response('busy', { status: 503 });
      return geminiOk();
    });
    assert.deepEqual(rows, ROWS);
  });

  test('每日额度用完时叫人明天再来，而不是「稍后」', async () => {
    // Gemini 真的回的，2026-09-23 原样贴上（retry 秒数除外，那个每次不同）。
    // 要原样：额度名称在第一千个字左右，一份截短的假回应测不出「读一半就判断」。
    const body = JSON.stringify(REAL_DAILY_QUOTA_429, null, 2);
    assert.ok(body.indexOf('PerDay') > 500, '这份样本要能测出截断的问题');
    const restore = muteConsoleError();
    try {
      await assert.rejects(() => call(() => new Response(body, { status: 429 })), {
        status: 429,
        message: /今天的免费辨识次数用完了/,
      });
    } finally {
      restore();
    }
  });

  test('正式设定最多试三次：每次 503 都算一次每日额度', () => {
    // 2026-09-24 两次塞车的汇入各重试五、六次，把当天 40 次用完。
    assert.equal(RETRY_DELAYS_MS.length, 2);
  });

  describe('额度重置时间（太平洋时间半夜）', () => {
    const at = (iso) => Date.parse(iso);
    test('夏令时间是台湾下午三点', () => {
      assert.equal(quotaResetText(at('2026-09-24T02:15:00Z')), '今天 15:00（Asia/Taipei）'); // 台湾 10:15
    });
    test('过了三点就是明天', () => {
      assert.equal(quotaResetText(at('2026-09-24T08:00:00Z')), '2026-09-25 15:00（Asia/Taipei）'); // 台湾 16:00
    });
    test('夏令时间结束当天还是三点，隔天起变四点', () => {
      // 美国 2026-11-01 02:00 结束夏令时间；11/1 的半夜还是 PDT。
      assert.equal(quotaResetText(at('2026-10-31T08:00:00Z')), '2026-11-01 15:00（Asia/Taipei）');
      assert.equal(quotaResetText(at('2026-11-01T08:00:00Z')), '2026-11-02 16:00（Asia/Taipei）');
      assert.equal(quotaResetText(at('2026-11-02T02:00:00Z')), '今天 16:00（Asia/Taipei）');
    });
    test('冬令时间跨年也照算', () => {
      assert.equal(quotaResetText(at('2026-12-31T23:00:00Z')), '今天 16:00（Asia/Taipei）'); // 台湾 1/1 07:00
    });
  });

  /// 从请求网址取出打的是哪个模型。
  const modelOf = (url) => /models\/([^:]+):/.exec(url)[1];

  test('429 不在同一个模型上重试，换下一个；全部用完才放弃', async () => {
    const used = [];
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          call((url) => {
            used.push(modelOf(url));
            return new Response(JSON.stringify(REAL_DAILY_QUOTA_429), { status: 429 });
          }),
        { status: 429, message: /今天的免费辨识次数用完了/ },
      );
    } finally {
      restore();
    }
    assert.deepEqual(used, ['gemini-3.6-flash', 'gemini-3.7-flash']);
  });

  test('第一个模型额度用完，第二个成功就当作成功', async () => {
    // 2026-09-23 实际碰到的：3.6 回 429，3.7 一分钟后辨识成功。
    const restore = muteConsoleError();
    try {
      const rows = await call((url) =>
        modelOf(url) === 'gemini-3.6-flash'
          ? new Response(JSON.stringify(REAL_DAILY_QUOTA_429), { status: 429 })
          : geminiOk(),
      );
      assert.deepEqual(rows, ROWS);
    } finally {
      restore();
    }
  });

  test('503 重试时两个模型轮流用', async () => {
    const used = [];
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          call((url) => {
            used.push(modelOf(url));
            return new Response('busy', { status: 503 });
          }),
        { status: 503 },
      );
    } finally {
      restore();
    }
    assert.deepEqual(used, ['gemini-3.6-flash', 'gemini-3.7-flash', 'gemini-3.6-flash']);
  });

  test('一个额度用完、另一个忙碌时，说的是忙碌', async () => {
    // 忙碌过几分钟会好，额度要等到明天 —— 还有一个模型可能会好，就不要叫人等到明天。
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          call((url) =>
            modelOf(url) === 'gemini-3.6-flash'
              ? new Response(JSON.stringify(REAL_DAILY_QUOTA_429), { status: 429 })
              : new Response('busy', { status: 503 }),
          ),
        { status: 503, message: 'Gemini 免费版现在太多人用，过几分钟再试一次' },
      );
    } finally {
      restore();
    }
  });

  test('一个模型下架（404）时换下一个，不是整个放弃', async () => {
    const used = [];
    const restore = muteConsoleError();
    try {
      const rows = await call((url) => {
        used.push(modelOf(url));
        return modelOf(url) === 'gemini-3.6-flash'
          ? new Response('', { status: 404 })
          : geminiOk();
      });
      assert.deepEqual(rows, ROWS);
    } finally {
      restore();
    }
    assert.deepEqual(used, ['gemini-3.6-flash', 'gemini-3.7-flash']);
  });

  test('一个额度用完、另一个下架时，说的是额度，不是设定有误', async () => {
    // 最后一个回的是 404，但这次请求失败的原因是额度 —— 叫人找管理员修设定是错的方向。
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          call((url) =>
            modelOf(url) === 'gemini-3.6-flash'
              ? new Response(JSON.stringify(REAL_DAILY_QUOTA_429), { status: 429 })
              : new Response('', { status: 404 }),
          ),
        { status: 429, message: /今天的免费辨识次数用完了/ },
      );
    } finally {
      restore();
    }
  });

  test('换模型也受时间上限约束：过了就不再开始新的一次', async () => {
    // 503 拖到第 80 秒，另一个模型就算还能用也来不及了。
    let clock = 0;
    const used = [];
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          callGemini(ENV, {
            prompt: 'x',
            images,
            retryDelaysMs: [0, 0],
            lastAttemptStartMs: 75000,
            now: () => clock,
            fetchImpl: async (url) => {
              used.push(modelOf(url));
              clock += 80000;
              return new Response(JSON.stringify(REAL_DAILY_QUOTA_429), { status: 429 });
            },
          }),
        { status: 429 },
      );
    } finally {
      restore();
    }
    assert.deepEqual(used, ['gemini-3.6-flash']);
  });

  test('三个模型时，拿掉一个之后其余照顺序轮，不会漏掉', async () => {
    const used = [];
    const impl = fakeFetch({
      gemini: (url) => {
        const model = modelOf(url);
        used.push(model);
        if (model === 'm-a') return new Response(JSON.stringify(REAL_DAILY_QUOTA_429), { status: 429 });
        return new Response('busy', { status: 503 });
      },
    });
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          callGemini(
            { ...ENV, GEMINI_MODEL: 'm-a,m-b,m-c' },
            { prompt: 'x', images, fetchImpl: impl, retryDelaysMs: [0, 0, 0] },
          ),
        { status: 503 },
      );
    } finally {
      restore();
    }
    assert.deepEqual(used, ['m-a', 'm-b', 'm-c', 'm-b', 'm-c']);
  });

  test('GEMINI_MODEL 可以用逗号换掉整份清单', async () => {
    const used = [];
    const impl = fakeFetch({
      gemini: (url) => {
        used.push(modelOf(url));
        return geminiOk();
      },
    });
    const restore = muteConsoleError();
    try {
      await callGemini(
        { ...ENV, GEMINI_MODEL: ' gemini-9-flash , gemini-8-flash ' },
        { prompt: 'x', images, fetchImpl: impl, retryDelaysMs: [0, 0] },
      );
    } finally {
      restore();
    }
    assert.deepEqual(used, ['gemini-9-flash']);
  });

  test('每分钟的限制说等一下就好', async () => {
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () =>
          call(
            () =>
              new Response(JSON.stringify({ error: { details: [{ violations: [{ quotaId: 'GenerateRequestsPerMinutePerProjectPerModel-FreeTier' }] }] } }), {
                status: 429,
              }),
          ),
        { status: 429, message: '辨识太频繁了，等一分钟再试' },
      );
    } finally {
      restore();
    }
  });

  test('模型名称设错时是伺服器设定问题，不是使用者的错', async () => {
    const restore = muteConsoleError();
    try {
      await assert.rejects(() => call(() => new Response('{}', { status: 404 })), { status: 500 });
    } finally {
      restore();
    }
  });

  test('等太久是逾时，不是「连不上」', async () => {
    // 真的 fetch 被 abort 时就是这样：带著 signal 的请求 reject。
    const hang = (url, init) =>
      new Promise((_, reject) => {
        init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
      });
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () => callGemini(ENV, { prompt: 'x', images, fetchImpl: hang, timeoutMs: 5 }),
        { status: 504, message: '辨识太久了，请把照片裁到只剩表格再试' },
      );
    } finally {
      restore();
    }
  });

  test('没设 GEMINI_API_KEY 就不会送出任何东西', async () => {
    const impl = fakeFetch();
    const restore = muteConsoleError();
    try {
      await assert.rejects(
        () => callGemini({ ...ENV, GEMINI_API_KEY: undefined }, { prompt: 'x', images, fetchImpl: impl }),
        { status: 500 },
      );
      assert.equal(impl.geminiCalls().length, 0);
    } finally {
      restore();
    }
  });
});

describe('extractJson', () => {
  const ok = (text) => ({ candidates: [{ content: { parts: [{ text }] } }] });

  test('一般情况', () => {
    assert.deepEqual(extractJson(ok(JSON.stringify(ROWS))), ROWS);
  });

  // prompt 明讲不要围栏，但模型还是会加。为这个让整份转换失败不划算。
  test('模型自己加了程式码围栏也接得住', () => {
    assert.deepEqual(extractJson(ok('```json\n' + JSON.stringify(ROWS) + '\n```')), ROWS);
  });

  test('分段回来的文字会接起来', () => {
    const payload = { candidates: [{ content: { parts: [{ text: '[{"date":' }, { text: '"2026-10-04"}]' }] } }] };
    assert.deepEqual(extractJson(payload), [{ date: '2026-10-04' }]);
  });

  test('被安全过滤挡掉时给的是可以照做的讯息', () => {
    const restore = muteConsoleError();
    try {
      assert.throws(() => extractJson({ promptFeedback: { blockReason: 'SAFETY' } }), {
        status: 502,
        message: '辨识没有产生结果，请换一张照片再试',
      });
    } finally {
      restore();
    }
  });

  // 截断的输出是最容易误会的一种失败：看起来像模型坏了，其实是表太大。
  test('输出被长度截断时叫人裁成两半分两次', () => {
    const restore = muteConsoleError();
    try {
      assert.throws(() => extractJson({ candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [] } }] }), {
        message: '服事表太大，请把照片裁成上下两半，分两次辨识',
      });
    } finally {
      restore();
    }
  });

  test('不是 JSON 时不会把 SyntaxError 丢给使用者', () => {
    const restore = muteConsoleError();
    try {
      assert.throws(() => extractJson(ok('抱歉，我看不懂这张表')), { status: 502 });
    } finally {
      restore();
    }
  });

  // parseRosterImportJson 的最外层要求是阵列；不是阵列的话那边会直接挡，
  // 但在这里就说清楚，讯息才会是「再试一次」而不是「JSON 最外层需为阵列」。
  test('回的是物件而不是阵列时挡在这里', () => {
    const restore = muteConsoleError();
    try {
      assert.throws(() => extractJson(ok('{"date":"2026-10-04"}')), { status: 502 });
    } finally {
      restore();
    }
  });
});
