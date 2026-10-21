// Backfill `zoneTypes` onto every users/{uid} document.
//
// Why the field exists: firestore.rules limits roster writes to the editor's
// own 牧区, and `zones` is a list of maps — the rules language has no loops and
// no map/filter, so it cannot read serviceType out of it. The app therefore
// writes a flattened projection next to it (see User.zoneTypes), and the rules
// read that. This script computes the same projection for documents written
// before the field existed.
//
// Run it BEFORE deploying the new rules. Until a user document has the field,
// `data.get('zoneTypes', [])` reads as "no 牧区" and every roster write by that
// person is denied — admin excepted, since admin is root.
//
// Usage:
//     node scripts/backfill-user-zone-types.mjs           # dry run, writes nothing
//     node scripts/backfill-user-zone-types.mjs --apply   # actually writes
//     node scripts/backfill-user-zone-types.mjs --check   # audit only, exits 1 on drift
//
// --check is the standing answer to "zoneTypes is a second copy of zones, what
// stops them drifting?". Through the app they cannot: User.toJson() recomputes
// the projection from zones on every write. What can drift is a document
// written some other way — Firebase console, an Admin SDK script, this one.
// Drift is invisible in the UI (it reads zones) and only shows up as a roster
// write that fails, or as a roster type the rules let through that the tabs
// never offered. Run --check to see it directly; it is safe to run any time.
//
// Auth reuses the Firebase CLI login that deploying the rules already needs
// (`~/.config/configstore/firebase-tools.json`), so there is nothing extra to
// log into. FIREBASE_TOKEN and a gcloud login both work as fallbacks. Whoever
// it resolves to needs datastore write access on the project.
//
// The project id comes from .local/project-id (gitignored),
// GOOGLE_CLOUD_PROJECT, or gcloud's config.

import { execFileSync } from 'node:child_process';
import { readChurchConfig } from './read-church-config.mjs';
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Must stay in sync with ServiceType (lib/core/types/service_type.dart) and
// with hasValidZoneTypes() in firestore.rules. Order matters: it is the order
// User.zoneTypes writes, and writing the same set in a different order is a
// Firestore write with no actual change in it.
const SERVICE_TYPES = readChurchConfig().services.map((service) => service.id);

const APPLY = process.argv.includes('--apply');
const CHECK = process.argv.includes('--check');

function die(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function projectId() {
  const fromFile = (() => {
    try {
      return readFileSync(path.join(ROOT, '.local', 'project-id'), 'utf8').trim();
    } catch {
      return '';
    }
  })();
  if (fromFile) return fromFile;
  if (process.env.GOOGLE_CLOUD_PROJECT) return process.env.GOOGLE_CLOUD_PROJECT;
  try {
    const configured = execFileSync('gcloud', ['config', 'get-value', 'project'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (configured && configured !== '(unset)') return configured;
  } catch {
    // fall through to the error below
  }
  return die(
    '找不到 project id。建立 .local/project-id，或设 GOOGLE_CLOUD_PROJECT，' +
      '或先跑 gcloud config set project <id>。',
  );
}

// firebase-tools 的 OAuth client。这两个值是公开的（安装在每个人机器上的
// CLI 里就有），refresh token 才是秘密 —— 没有它们光有 client id 什么都换不到。
const FIREBASE_CLI_CLIENT_ID =
  '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com';
const FIREBASE_CLI_CLIENT_SECRET = 'j9iVZfS8kkCEFUPaAeJV0sAi';

function firebaseToolsConfig() {
  const base =
    process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  try {
    return JSON.parse(
      readFileSync(path.join(base, 'configstore', 'firebase-tools.json'), 'utf8'),
    );
  } catch {
    return null;
  }
}

async function exchangeRefreshToken(refreshToken) {
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: FIREBASE_CLI_CLIENT_ID,
      client_secret: FIREBASE_CLI_CLIENT_SECRET,
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.access_token) {
    return die(
      `refresh token 换不到 access token（${response.status}）：` +
        `${body.error_description ?? body.error ?? '未知错误'}\n` +
        '  重新登入：cd firestore-tests && npx firebase login --reauth',
    );
  }
  return body.access_token;
}

function gcloudToken() {
  try {
    return execFileSync('gcloud', ['auth', 'print-access-token'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (error) {
    // gcloud 的讯息要原封不动印出来：「凭证过期要重新登入」跟「这个帐号没权限」
    // 是两件事，吞掉之后只剩一句没有指向性的提示。
    const detail = (error.stderr ?? '').toString().trim();
    return die(
      '拿不到凭证。任一种都可以：\n' +
        '  cd firestore-tests && npx firebase login   （部署规则本来就要登这个）\n' +
        '  gcloud auth login\n' +
        `${detail}`,
    );
  }
}

// 凭证来源，由近到远：CI 的 FIREBASE_TOKEN、本机的 firebase CLI 登入、gcloud。
// 排在最前面的两个都是部署规则本来就会用到的那份登入，不必为了这支脚本再登一次。
async function accessToken() {
  if (process.env.FIREBASE_TOKEN) {
    console.log('凭证来源：FIREBASE_TOKEN');
    return exchangeRefreshToken(process.env.FIREBASE_TOKEN);
  }

  const config = firebaseToolsConfig();
  const tokens = config?.tokens;
  if (tokens?.refresh_token) {
    const who = config.user?.email ?? '（不明帐号）';
    // 快取的 access token 还没过期就直接用。留 60 秒缓冲，免得在请求途中过期。
    if (tokens.access_token && tokens.expires_at > Date.now() + 60_000) {
      console.log(`凭证来源：firebase CLI（${who}）`);
      return tokens.access_token;
    }
    console.log(`凭证来源：firebase CLI（${who}，refresh 后）`);
    return exchangeRefreshToken(tokens.refresh_token);
  }

  console.log('凭证来源：gcloud');
  return gcloudToken();
}

const PROJECT = projectId();
const TOKEN = await accessToken();
const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;

async function firestore(url, init = {}) {
  const response = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
  const body = await response.text();
  if (!response.ok) {
    die(`Firestore ${response.status}: ${body}`);
  }
  return body ? JSON.parse(body) : {};
}

async function listUsers() {
  const documents = [];
  let pageToken = '';
  do {
    const url = new URL(`${BASE}/users`);
    url.searchParams.set('pageSize', '300');
    if (pageToken) url.searchParams.set('pageToken', pageToken);
    const page = await firestore(url.toString());
    documents.push(...(page.documents ?? []));
    pageToken = page.nextPageToken ?? '';
  } while (pageToken);
  return documents;
}

// zones → the same projection User.zoneTypes computes: declaration order,
// deduplicated, unknown values dropped (they match no roster anyway, and
// hasValidZoneTypes() would reject them on the next write from the app).
function zoneTypesOf(document) {
  const zones = document.fields?.zones?.arrayValue?.values ?? [];
  const present = new Set(
    zones
      .map((zone) => zone.mapValue?.fields?.serviceType?.stringValue)
      .filter(Boolean),
  );
  return SERVICE_TYPES.filter((type) => present.has(type));
}

function currentZoneTypes(document) {
  const field = document.fields?.zoneTypes;
  if (!field) return null; // field absent — every pre-migration document
  return (field.arrayValue?.values ?? []).map((value) => value.stringValue ?? '');
}

const users = await listUsers();
if (users.length === 0) die('users collection 是空的 —— project id 对吗？');

const pending = [];
for (const document of users) {
  const id = document.name.split('/').pop();
  const wanted = zoneTypesOf(document);
  const current = currentZoneTypes(document);
  const name = document.fields?.name?.stringValue ?? id;
  if (current !== null && JSON.stringify(current) === JSON.stringify(wanted)) {
    continue;
  }
  pending.push({ id, name, wanted, current });
}

const noun = CHECK ? '和 zones 不一致' : '需要补 zoneTypes';
console.log(`专案 ${PROJECT}：${users.length} 个帐号，${pending.length} 个${noun}。`);
for (const { id, name, wanted, current } of pending) {
  const before = current === null ? '（没有栏位）' : `[${current.join(', ')}]`;
  console.log(`  ${name} (${id}): ${before} → [${wanted.join(', ')}]`);
}

// 有服事表编辑权但一个牧区都没有的人，补完之后会变成「什么都改不动」。规则
// 上这是对的（牧区决定改哪一本），但那是一个人的权限实质变了，要讲出来而不是
// 让他下次进编辑模式才发现。
const strandedEditors = users.filter((document) => {
  const groups = (document.fields?.groups?.arrayValue?.values ?? []).map(
    (value) => value.stringValue,
  );
  const role = document.fields?.role?.stringValue;
  return (
    role !== 'admin' &&
    groups.includes('roster-editors') &&
    zoneTypesOf(document).length === 0
  );
});
if (strandedEditors.length > 0) {
  console.log('\n⚠ 这几位有 roster-editors 但没有任何牧区，补完后改不动任何服事表：');
  for (const document of strandedEditors) {
    const id = document.name.split('/').pop();
    console.log(`  ${document.fields?.name?.stringValue ?? id} (${id})`);
  }
  console.log('  要让他们继续编辑，先到后台把对应的牧区加上去。');
}

if (pending.length === 0) {
  console.log(CHECK ? '✓ zoneTypes 与 zones 完全一致。' : '✓ 没有要改的。');
  process.exit(0);
}

if (CHECK) {
  // 非 0 退出，这样挂进 CI 或排程才有意义 —— 印出来没人看的检查等于没有检查。
  console.log('\n✗ 上面这些人的 zoneTypes 对不上 zones。用 --apply 修好。');
  process.exit(1);
}

if (!APPLY) {
  console.log('\n这是 dry run，什么都没写。确认上面的清单没问题后加上 --apply。');
  process.exit(0);
}

for (const { id, name, wanted } of pending) {
  const url = new URL(`${BASE}/users/${encodeURIComponent(id)}`);
  // updateMask 只点名 zoneTypes：PATCH 没有 mask 会把文件其他栏位清掉。
  url.searchParams.set('updateMask.fieldPaths', 'zoneTypes');
  await firestore(url.toString(), {
    method: 'PATCH',
    body: JSON.stringify({
      fields: {
        zoneTypes: {
          arrayValue: { values: wanted.map((type) => ({ stringValue: type })) },
        },
      },
    }),
  });
  console.log(`✓ ${name} (${id})`);
}

console.log(`\n✓ 补完 ${pending.length} 个帐号。`);
