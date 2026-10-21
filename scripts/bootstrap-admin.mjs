#!/usr/bin/env node
// 首位管理员的一次性离线预览／create-only 建立工具；不建立或更改 Auth 帐号。
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { validateChurchConfig } from '../worker/church_config.js';

const help = `Usage:
  node scripts/bootstrap-admin.mjs --project PROJECT --uid AUTH_UID --name NAME [--username NAME]
  node scripts/bootstrap-admin.mjs --project PROJECT --email EMAIL --name NAME [--config PATH]

预设 dry-run：完全离线，不读凭证、不查 Auth、不写 Firestore。
先在 Firebase Console 建立并确认属于首位管理员的 Email/Password Auth 帐号。
真正建立时另加 --apply --confirm-project PROJECT --confirm-uid AUTH_UID。
--config PATH 选填：使用与部署相同的完整 church.json 验证，再由 enabled services 建立 zones / zoneTypes。
登入凭证：GOOGLE_OAUTH_ACCESS_TOKEN，或 gcloud auth application-default print-access-token。
`;

export function parseArgs(args) {
  const result = { apply: false };
  const flags = new Set(['project', 'uid', 'email', 'name', 'username', 'config', 'confirm-project', 'confirm-uid']);
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--help') return { help: true };
    if (arg === '--apply') { result.apply = true; continue; }
    const key = arg.slice(2);
    if (!arg.startsWith('--') || !flags.has(key) || !args[i + 1] || args[i + 1].startsWith('--')) {
      throw new Error(`不支援或缺值的参数：${arg}`);
    }
    if (Object.hasOwn(result, key)) throw new Error(`重复参数：${arg}`);
    result[key] = args[++i].trim();
  }
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(result.project ?? '')) {
    throw new Error('请用 --project 明确指定 Firebase project ID（不是 project number）。');
  }
  if (!result.uid && !result.email) throw new Error('必须提供 --uid 或 --email。');
  if (result.uid && !validUid(result.uid)) throw new Error('Auth UID 不可包含斜线或控制字元，长度为 1–128。');
  if (result.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(result.email)) throw new Error('Email 格式不正确。');
  if (!result.name || result.name.length > 100) throw new Error('--name 为必填，且最多 100 字。');
  result.username ??= result.name;
  if (!result.username || result.username.length > 100) throw new Error('--username 最多 100 字。');
  if (result.apply && (result['confirm-project'] !== result.project || !validUid(result['confirm-uid']))) {
    throw new Error('--apply 还必须提供相同的 --confirm-project，以及 Console 中核对过的 --confirm-uid。');
  }
  if (result.apply && result.uid && result.uid !== result['confirm-uid']) throw new Error('确认 UID 与指定 UID 不一致。');
  return result;
}

function validUid(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 128 && !['.', '..'].includes(value) && !/[\/\x00-\x1f\x7f]/.test(value);
}

export function enabledServiceIds(config) {
  if (config === undefined) return [];
  return validateChurchConfig(config).services
    .filter((service) => service.enabled)
    .map((service) => service.id);
}

export function buildAdminProfile(options, authUser, serviceIds = []) {
  if (!validUid(authUser.localId) || !authUser.email) throw new Error('Auth 帐号必须有有效 UID 与 email。');
  if (authUser.disabled) throw new Error('Auth 帐号已停用，拒绝建立管理员。');
  if (options.uid && authUser.localId !== options.uid) throw new Error('Auth 回传 UID 与指定 UID 不一致。');
  if (options.email && authUser.email.toLowerCase() !== options.email.toLowerCase()) throw new Error('Auth 回传 email 与指定 email 不一致。');
  if (options.apply && authUser.localId !== options['confirm-uid']) throw new Error('Auth 帐号与核对过的 UID 不一致；未写入。');
  return {
    id: authUser.localId,
    name: options.name,
    email: authUser.email,
    username: options.username,
    role: 'admin',
    zones: serviceIds.map((id) => ({ serviceType: id, smallGroups: [], ministries: [] })),
    zoneTypes: serviceIds,
    groups: [],
  };
}

export function firestoreValue(value) {
  if (typeof value === 'string') return { stringValue: value };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(firestoreValue) } };
  if (value && typeof value === 'object') return { mapValue: { fields: firestoreFields(value) } };
  throw new Error('不支援的 Firestore 栏位型别。');
}

function firestoreFields(object) {
  return Object.fromEntries(Object.entries(object).map(([key, value]) => [key, firestoreValue(value)]));
}

export async function bootstrap(options, {
  fetchImpl = globalThis.fetch,
  getAccessToken = () => process.env.GOOGLE_OAUTH_ACCESS_TOKEN || execFileSync(
    'gcloud', ['auth', 'application-default', 'print-access-token'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
  ).trim(),
  readConfig = (path) => JSON.parse(readFileSync(path, 'utf8')),
  log = console.log,
} = {}) {
  // 验证也在这层执行，避免程式化呼叫绕过 CLI 的确认旗标。
  const validated = parseArgs([
    '--project', options.project, '--name', options.name,
    ...Object.entries(options).filter(([key]) => !['project', 'name', 'apply'].includes(key))
      .flatMap(([key, value]) => [`--${key}`, String(value)]),
    ...(options.apply ? ['--apply'] : []),
  ]);
  const serviceIds = enabledServiceIds(validated.config ? readConfig(validated.config) : undefined);
  log(`目标 project=${validated.project}; database=(default); Auth=${validated.uid ?? validated.email}; name=${validated.name}`);
  log(`操作：只建立 users/{Auth UID}，role=admin；不修改 Auth、不覆写既有 profile。zones=${JSON.stringify(serviceIds)}`);
  if (!validated.apply) {
    log('DRY RUN（离线）：尚未验证 Auth 身分、IAM 权限或 profile 是否存在；没有任何 API 呼叫。');
    return { applied: false, project: validated.project, serviceIds };
  }
  const token = await getAccessToken();
  if (!token || typeof token !== 'string' || /\s/.test(token)) throw new Error('无法取得有效 OAuth access token。');
  const headers = {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
    'x-goog-user-project': validated.project,
  };
  const request = (url, init = {}) => fetchImpl(url, { ...init, headers, redirect: 'error', signal: AbortSignal.timeout(30_000) });
  const lookup = await request(`https://identitytoolkit.googleapis.com/v1/projects/${validated.project}/accounts:lookup`, {
    method: 'POST',
    body: JSON.stringify(validated.uid ? { localId: [validated.uid] } : { email: [validated.email] }),
  });
  if (!lookup.ok) throw new Error(`Firebase Auth lookup 失败（HTTP ${lookup.status}）；未写入。`);
  const { users } = await lookup.json();
  if (!Array.isArray(users) || users.length !== 1) throw new Error('找不到唯一的 Firebase Auth 帐号；请先在 Console 建立并核对。');
  const profile = buildAdminProfile(validated, users[0], serviceIds);
  const documentName = `projects/${validated.project}/databases/(default)/documents/users/${profile.id}`;
  const existing = await request(`https://firestore.googleapis.com/v1/projects/${validated.project}/databases/(default)/documents/users/${encodeURIComponent(profile.id)}`);
  if (existing.ok) throw new Error('users profile 已存在；不覆写、不升权。请由既有管理员处理。');
  if (existing.status !== 404) throw new Error(`无法确认 profile 不存在（HTTP ${existing.status}）；未写入。`);
  log(`已核对 Auth uid=${profile.id}; email=${profile.email}。准备 create-only 写入 ${documentName}。`);
  const committed = await request(`https://firestore.googleapis.com/v1/projects/${validated.project}/databases/(default)/documents:commit`, {
    method: 'POST',
    body: JSON.stringify({ writes: [{ update: { name: documentName, fields: firestoreFields(profile) }, currentDocument: { exists: false } }] }),
  });
  if (!committed.ok) throw new Error(`建立失败（HTTP ${committed.status}）；若文件已存在，create-only 条件会拒绝，不会覆写。`);
  log('已建立管理员 profile。请用 Console 建立的 Auth email/password 登入并验证权限。');
  return { applied: true, profile };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) console.log(help);
    else await bootstrap(options);
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Bootstrap failed.');
    process.exitCode = 1;
  }
}
