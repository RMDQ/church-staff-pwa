import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, readdir, realpath, rename, rm, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { validateChurchConfig } from '../../worker/church_config.js';
import { checkPng, CORE_ICONS, fingerprint, ICON_SIZES, installationError, isPrivateDirectory, normalizeCustomDomain, projectIdFor, STEPS, UPDATE_STEPS } from './shared.mjs';

export { installationError, STEPS, UPDATE_STEPS };

export const REGIONS = [
  ['asia-east1', '台湾'], ['asia-east2', '香港'],
  ['asia-northeast1', '东京'], ['asia-southeast1', '新加坡'],
  ['australia-southeast1', '雪梨'], ['europe-west1', '比利时'],
  ['us-central1', '美国中部'], ['us-east1', '美国东部'],
];

// Churches rarely know which data center suits them, and the choice is
// permanent, so by default the plan picks the one nearest the church's time
// zone: exact places first, then the continent, then the standard UTC offset.
const REGION_BY_ZONE = {
  'Asia/Taipei': 'asia-east1', 'Asia/Shanghai': 'asia-east1', 'Asia/Manila': 'asia-east1',
  'Asia/Hong_Kong': 'asia-east2', 'Asia/Macau': 'asia-east2',
  // Indonesia and East Timor reach east to UTC+9, still nearest Singapore.
  'Asia/Jakarta': 'asia-southeast1', 'Asia/Pontianak': 'asia-southeast1', 'Asia/Makassar': 'asia-southeast1',
  'Asia/Jayapura': 'asia-southeast1', 'Asia/Dili': 'asia-southeast1',
  // Western Pacific islands nearer Tokyo than Sydney (Intl may spell Chuuk and Pohnpei the old way).
  'Pacific/Guam': 'asia-northeast1', 'Pacific/Saipan': 'asia-northeast1', 'Pacific/Palau': 'asia-northeast1',
  'Pacific/Chuuk': 'asia-northeast1', 'Pacific/Truk': 'asia-northeast1', 'Pacific/Pohnpei': 'asia-northeast1',
  'Pacific/Ponape': 'asia-northeast1', 'Pacific/Kosrae': 'asia-northeast1', 'Pacific/Wake': 'asia-northeast1',
};

function standardOffsetHours(timeZone) {
  // The smaller of January and July is standard time in either hemisphere.
  // A fixed year keeps the answer the same from one run to the next.
  const offsets = [0, 6].map((month) => {
    const name = new Intl.DateTimeFormat('en-US', { timeZone, timeZoneName: 'longOffset' })
      .formatToParts(Date.UTC(2026, month, 15)).find((part) => part.type === 'timeZoneName').value;
    const match = /GMT([+-])(\d{2}):(\d{2})/.exec(name);
    return match ? (match[1] === '-' ? -1 : 1) * (Number(match[2]) + Number(match[3]) / 60) : 0;
  });
  return Math.min(...offsets);
}

// The offered region nearest a UTC offset, for zones that name no continent
// (UTC, Etc/GMT+8, Antarctica/…) or span an ocean.
function regionForOffset(offset) {
  if (offset < -5) return 'us-central1';
  if (offset < -2) return 'us-east1';
  if (offset < 5) return 'europe-west1';
  if (offset < 8) return 'asia-southeast1';
  if (offset < 9) return 'asia-east1';
  return offset < 10 ? 'asia-northeast1' : 'australia-southeast1';
}

export function regionForTimeZone(timeZone) {
  if (REGION_BY_ZONE[timeZone]) return REGION_BY_ZONE[timeZone];
  const area = timeZone.split('/')[0];
  const offset = standardOffsetHours(timeZone);
  if (area === 'Europe' || area === 'Africa') return 'europe-west1';
  if (area === 'America') return offset >= -5 ? 'us-east1' : 'us-central1';
  if (area === 'Australia') return 'australia-southeast1';
  if (area === 'Pacific') return offset > 0 ? 'australia-southeast1' : 'us-central1';
  if (area === 'Indian') return 'asia-southeast1';
  if (area === 'Asia') {
    if (offset >= 9) return 'asia-northeast1';
    return offset >= 5 ? 'asia-southeast1' : 'europe-west1';
  }
  return regionForOffset(offset);
}

const RUN_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// The Pages project name becomes <name>.pages.dev, which staff type and share,
// so the church picks it. Cloudflare allows up to 58; 40 leaves room for the
// suffix it adds when the name is taken on another account.
export const SITE_NAME = /^[a-z][a-z0-9-]{1,38}[a-z0-9]$/;
const PRIVATE_KEY = /^(?:access_?token|refresh_?token|token|secret|client_?secret|password|passwordHash|salt|api_?key|authorization|oobCode|oobLink|firebaseConfig)$/i;
const clone = (value) => JSON.parse(JSON.stringify(value));

// Validate a required single-line field and return it trimmed.
function requireText(value, label, max = 100) {
  if (typeof value !== 'string' || !value.trim() || value.length > max || /[\x00-\x1f]/.test(value)) {
    throw installationError(`${label}未填写或格式不正确`, 'INVALID_INPUT');
  }
  return value.trim();
}

function requireEmail(value, label) {
  const result = requireText(value, label, 254);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(result)) throw installationError(`${label}格式不正确`, 'INVALID_INPUT');
  return result;
}

// The only church config an installer site ever has: core features, neutral
// icon paths. Shared by a first install (from the form) and an update (from
// the site's own /church-config.json, whose service ids are kept as they are).
export function coreChurchConfig({ appName, shortName, timeZone, services }) {
  return validateChurchConfig({
    schemaVersion: 1, appName, shortName, timeZone: canonicalTimeZone(timeZone), services,
    features: { calendar: false, photoImport: false, pushNotifications: false, lineNotifications: false },
    devotional: { enabled: false, dataUrl: '', linkUrl: '', sourceName: '每日灵粮', fetchUrl: '', fetchFormat: 'json' },
    icons: { ...CORE_ICONS },
  });
}

// Intl takes a time zone in any letter case (europe/amsterdam), the app only
// in its exact IANA spelling, so the config stores the name Intl resolves to.
// An unknown zone is left as typed for validateChurchConfig to reject.
function canonicalTimeZone(value) {
  try {
    return new Intl.DateTimeFormat('en-US', { timeZone: value }).resolvedOptions().timeZone;
  } catch {
    return value;
  }
}

// A small JSON file from a site this wizard published. Pages answers unknown
// paths with the app's index.html, so anything that is not JSON reads as missing.
async function fetchSiteJson(url, { signal } = {}) {
  try {
    const response = await fetch(url, {
      redirect: 'error', headers: { 'Cache-Control': 'no-cache' },
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : AbortSignal.timeout(15_000),
    });
    if (!response.ok) return null;
    const text = await response.text();
    return text.length > 256 * 1024 ? null : JSON.parse(text);
  } catch { return null; }
}

// The icons a live site serves, so an update keeps a logo set earlier.
async function fetchSiteBytes(url, { signal } = {}) {
  try {
    const response = await fetch(url, {
      redirect: 'error', headers: { 'Cache-Control': 'no-cache' },
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : AbortSignal.timeout(15_000),
    });
    if (!response.ok) return null;
    const bytes = Buffer.from(await response.arrayBuffer());
    return bytes.length > 1024 * 1024 ? null : bytes;
  } catch { return null; }
}

// Only a complete, correctly sized set is accepted; anything else means neutral icons.
function iconSet(files) {
  const icons = {};
  for (const [name, size] of Object.entries(ICON_SIZES)) {
    const bytes = checkPng(files?.[name], size);
    if (!bytes) return null;
    icons[name] = bytes;
  }
  return icons;
}

// The page sends the five PNGs it drew from the church's image, base64 encoded.
function decodeIcons(icons) {
  const decoded = {};
  for (const name of Object.keys(ICON_SIZES)) {
    decoded[name] = typeof icons?.[name] === 'string' && /^[A-Za-z0-9+/]+={0,2}$/.test(icons[name]) ? Buffer.from(icons[name], 'base64') : undefined;
  }
  const set = iconSet(decoded);
  if (!set) throw installationError('Logo 图片转换失败，请换一张 PNG 或 JPG 再试', 'INVALID_INPUT');
  return set;
}

// A first install's logo lives as files next to its record; the plan keeps
// their hashes, so its digest covers them and a resume builds the same icons.
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const iconHashes = (icons) => Object.fromEntries(Object.keys(ICON_SIZES).map((name) => [name, sha256(icons[name])]));
const isIconHashes = (value) => Boolean(value) && typeof value === 'object' &&
  Object.keys(value).sort().join() === Object.keys(ICON_SIZES).sort().join() &&
  Object.values(value).every((hash) => /^[0-9a-f]{64}$/.test(hash));
const logoDirectory = (runDir) => path.join(runDir, 'logo');
const logoFile = (runDir, name) => path.join(logoDirectory(runDir), name.replace('/', '_'));
async function writePlanIcons(runDir, icons) {
  await privateDirectory(logoDirectory(runDir));
  for (const name of Object.keys(ICON_SIZES)) await writeFile(logoFile(runDir, name), icons[name], { mode: 0o600, flag: 'wx' });
}
async function readPlanIcons(runDir, hashes) {
  if (!hashes) return undefined;
  const files = {};
  for (const name of Object.keys(ICON_SIZES)) {
    let bytes;
    try { bytes = await readPrivateFile(logoFile(runDir, name)); } catch { /* Reported below like a changed file. */ }
    if (!bytes || sha256(bytes) !== hashes[name]) {
      throw installationError('这次安装的教会 Logo 档案遗失或被更改，已停止；不会自动改用预设图示。');
    }
    files[name] = bytes;
  }
  const icons = iconSet(files);
  if (!icons) throw installationError('这次安装的教会 Logo 档案遗失或被更改，已停止；不会自动改用预设图示。');
  return icons;
}

export function createInstallationPlan(input, identity, {
  runId = randomUUID(), sourceRevision = 'development', mode = 'cloud', iconHashes,
} = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw installationError('请填写教会设定', 'INVALID_INPUT');
  const allowed = new Set(['appName', 'shortName', 'siteName', 'timeZone', 'region', 'services', 'adminName', 'adminEmail', 'cloudflareAccountId']);
  if (Object.keys(input).some((key) => !allowed.has(key))) throw installationError('设定包含不支援的栏位', 'INVALID_INPUT');
  if (!RUN_ID.test(runId)) throw installationError('安装识别码不正确', 'INVALID_INPUT');
  const googleEmail = requireEmail(identity?.googleEmail, 'Google 帐号');
  if (!/^[0-9a-f]{32}$/i.test(input.cloudflareAccountId ?? '') ||
      !identity?.accounts?.some((account) => account.id === input.cloudflareAccountId)) {
    throw installationError('请选择已授权的 Cloudflare 帐号', 'INVALID_INPUT');
  }
  // Empty means automatic; a region is only sent when the church chose one.
  if (input.region && !REGIONS.some(([id]) => id === input.region)) throw installationError('资料库地区不正确，请重新选择', 'INVALID_INPUT');
  const siteName = typeof input.siteName === 'string' ? input.siteName.trim().toLowerCase() : '';
  if (!SITE_NAME.test(siteName) || siteName.includes('--')) {
    throw installationError('网站名称只能用 3–40 个英文小写字母、数字和连字号（-），并以字母开头', 'INVALID_INPUT');
  }
  if (!Array.isArray(input.services) || input.services.length < 1 || input.services.length > 20) {
    throw installationError('请设定 1 至 20 种聚会', 'INVALID_INPUT');
  }
  let churchConfig;
  try {
    churchConfig = coreChurchConfig({
      appName: requireText(input.appName, '教会名称'),
      shortName: requireText(input.shortName, '显示简称', 20),
      timeZone: requireText(input.timeZone, '时区'),
      services: input.services.map((service, index) => ({
        id: `service${index + 1}`,
        label: requireText(service?.label, '聚会简称', 20),
        name: requireText(service?.name, '聚会名称'),
        weekday: service?.weekday,
        enabled: true,
      })),
    });
  } catch (error) {
    if (error.safeToDisplay) throw error;
    throw installationError(`教会设定不正确：${error.message}`, 'INVALID_INPUT');
  }
  const projectId = projectIdFor(runId);
  const adminName = requireText(input.adminName, '管理员姓名');
  const plan = {
    schemaVersion: 1, runId, sourceRevision, mode,
    projectId, pagesProject: siteName,
    cloudflareAccountId: input.cloudflareAccountId,
    googleEmail, region: input.region || regionForTimeZone(churchConfig.timeZone), churchConfig,
    ...(iconHashes ? { icons: { ...iconHashes } } : {}),
    // Sign-in uses the email; like bootstrap-admin, the username defaults to the name.
    admin: { name: adminName, email: requireEmail(input.adminEmail, '管理员 email'), username: adminName },
  };
  return { ...plan, digest: fingerprint(plan) };
}

// resumable: the program versions whose records this one can safely continue
// (see scripts/installer/RESUMES_FROM), always including its own.
function validateStoredPlan(plan, resumable, mode) {
  if (!plan || plan.schemaVersion !== 1 || !RUN_ID.test(plan.runId ?? '')) throw installationError('安装纪录格式不正确');
  const { digest, ...fields } = plan;
  if (fingerprint(fields) !== digest) throw installationError('安装设定已被更改，拒绝接续');
  const config = validateChurchConfig(plan.churchConfig);
  if (Object.values(config.features).some(Boolean) || config.devotional.enabled ||
      plan.projectId !== projectIdFor(plan.runId) || !SITE_NAME.test(plan.pagesProject ?? '') ||
      !REGIONS.some(([id]) => id === plan.region)) throw installationError('纪录不是核心首次安装设定');
  if (!resumable.has(plan.sourceRevision)) throw installationError('程式版本与这次安装不相容；请使用原版本接续，不要重新建立专案');
  if (plan.mode !== mode) throw installationError('示范安装与真实安装不可互相接续');
  if (plan.icons !== undefined && !isIconHashes(plan.icons)) throw installationError('安装纪录格式不正确');
  requireEmail(plan.googleEmail, 'Google 帐号');
  requireEmail(plan.admin?.email, '管理员 email');
}

function assertCheckpointSafe(value, depth = 0) {
  if (depth > 30) throw new Error('Checkpoint nesting exceeds limit');
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (['__proto__', 'prototype', 'constructor'].includes(key) || PRIVATE_KEY.test(key)) {
      throw new Error('Credentials or unsafe keys must not be persisted');
    }
    assertCheckpointSafe(child, depth + 1);
  }
}

async function privateDirectory(directory) {
  await mkdir(directory, { mode: 0o700 }).catch((error) => { if (error.code !== 'EEXIST') throw error; });
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Installer directory must not be a link');
  if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) throw installationError('安装纪录目录权限过宽，请先限制为只有本人可存取');
}

async function assertRegular(file) {
  const stat = await lstat(file).catch((error) => { if (error.code !== 'ENOENT') throw error; });
  if (stat && (!stat.isFile() || stat.isSymbolicLink() || (process.platform !== 'win32' && (stat.nlink !== 1 || (stat.mode & 0o077) !== 0)))) {
    throw new Error('Installer state must be a private regular file');
  }
  return stat;
}

// A private regular file, never followed through a link; undefined when absent.
async function readPrivateFile(file) {
  if (!(await assertRegular(file))) return undefined;
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try { return await handle.readFile(); } finally { await handle.close(); }
}

async function openStore(rootDir, runId) {
  if (!RUN_ID.test(runId)) throw installationError('安装识别码不正确', 'INVALID_INPUT');
  const root = await realpath(rootDir);
  const local = path.join(root, '.local');
  // Existing .local may contain unrelated operator files. Never change its permissions.
  const localStat = await lstat(local).catch((error) => { if (error.code !== 'ENOENT') throw error; });
  if (localStat && (!localStat.isDirectory() || localStat.isSymbolicLink())) throw new Error('.local must be a real directory');
  if (!localStat) await mkdir(local, { mode: 0o700 });
  const base = path.join(local, 'install');
  await privateDirectory(base);
  const runDir = path.join(base, runId);
  await privateDirectory(runDir);
  const file = path.join(runDir, 'state.json');
  return {
    runDir,
    async read() {
      const stat = await assertRegular(file);
      if (!stat || stat.size > 2 * 1024 * 1024) throw installationError('找不到有效的安装纪录');
      return JSON.parse((await readPrivateFile(file)).toString('utf8'));
    },
    async write(value, initial = false) {
      assertCheckpointSafe(value);
      const body = JSON.stringify(value, null, 2) + '\n';
      if (Buffer.byteLength(body) > 2 * 1024 * 1024) throw new Error('Installer state exceeds size limit');
      if (initial) {
        const handle = await open(file, 'wx', 0o600);
        try { await handle.writeFile(body); await handle.sync(); } finally { await handle.close(); }
        return;
      }
      await assertRegular(file);
      const temporary = path.join(runDir, `.state-${randomUUID()}.tmp`);
      const handle = await open(temporary, 'wx', 0o600);
      try {
        await handle.writeFile(body);
        await handle.sync();
        await handle.close();
        await rename(temporary, file);
      } catch (error) {
        await handle.close().catch(() => {});
        await unlink(temporary).catch(() => {});
        throw error;
      }
    },
  };
}

function verifiedWebsite(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname.endsWith('.pages.dev') && url.pathname === '/' && !url.search ? url.href : undefined;
  } catch { return undefined; }
}

export function publicError(error) {
  const result = {
    code: typeof error?.code === 'string' && /^[A-Z_]{2,80}$/.test(error.code) ? error.code : 'INSTALLATION_ERROR',
    message: error?.safeToDisplay === true ? String(error.message).slice(0, 1_000) : '操作未完成。请确认授权与工具状态后重试；原始输出不会公开，以免泄漏凭证。',
  };
  const action = error?.action ?? (error?.helpUrl ? { title: '开启官方设定页', url: error.helpUrl } : undefined);
  if (action?.url) {
    try {
      const url = new URL(action.url);
      if (url.protocol === 'https:' && !url.username && !url.password &&
          ['console.firebase.google.com', 'console.cloud.google.com', 'dash.cloudflare.com'].includes(url.hostname)) {
        result.action = { title: String(action.title ?? '开启官方设定页').slice(0, 100), url: url.href };
      }
    } catch { /* Never echo an untrusted diagnostic URL. */ }
  }
  return result;
}

// Update builds get their own private directory; they never touch install records.
async function updateDirectory(rootDir, runId) {
  if (!RUN_ID.test(runId)) throw installationError('安装识别码不正确', 'INVALID_INPUT');
  const root = await realpath(rootDir);
  const local = path.join(root, '.local');
  const localStat = await lstat(local).catch((error) => { if (error.code !== 'ENOENT') throw error; });
  if (localStat && (!localStat.isDirectory() || localStat.isSymbolicLink())) throw new Error('.local must be a real directory');
  if (!localStat) await mkdir(local, { mode: 0o700 });
  const base = path.join(local, 'update');
  await privateDirectory(base);
  const runDir = path.join(base, runId);
  await privateDirectory(runDir);
  return runDir;
}

// Account management: a Google service account that may create and remove
// staff sign-ins, its key stored as the site's secret. Google and Cloudflare
// each do their half; the key passes between them in memory and is never
// written anywhere else.
//
// A stored key reaches the site only with its next deployment. A first install
// has not published yet (the Google half makes sure), so old keys go at once.
// An update sets transient.retireAccountAdminKeys instead, and the old keys go
// once the new deployment is live; until then the site still runs on them.
export async function setUpAccountAdmin({ google, cloudflare, context, update = false }) {
  const site = await cloudflare.accountAdminKeyState(context, { update });
  const key = await google.newAccountAdminKey(context, { update, configured: site.stored });
  if (key) {
    await cloudflare.storeAccountAdminKey(context, key.json, { update });
    // Names the deployment that carries this key (see publishUpdate).
    context.transient.accountAdminRedeploy = `key-${key.id.slice(0, 12)}`;
    if (update) context.transient.retireAccountAdminKeys = key.id;
    else await google.retireOtherAccountAdminKeys(context, { keep: key.id });
    return;
  }
  // Stored by an earlier update whose deployment never went through.
  if (update && site.stored && site.live === false) context.transient.accountAdminRedeploy = 'key';
}

export function createInstallationManager({ rootDir, google, cloudflare, build, sourceRevision = 'development', resumableRevisions = [], demo = false, report = () => {}, release, fetchSite = fetchSiteJson, fetchAsset = fetchSiteBytes }) {
  const mode = demo ? 'demo' : 'cloud';
  const resumable = new Set([sourceRevision, ...resumableRevisions]);
  const count = (event, fields) => { try { report(event, fields); } catch { /* Counting never affects the install. */ } };
  let state;
  let store;
  let busy = false;
  let controller;
  let lastError;
  let message = '';
  let device;
  let googleIdentity;
  let cloudflareIdentity;
  let transient = {};
  let writeQueue = Promise.resolve();
  // Update mode lives only in memory: every run re-reads the truth from
  // Cloudflare, Google and the live site, so there is nothing to resume.
  let installs;
  let update;

  const emit = (event) => {
    if (typeof event?.message === 'string') message = event.message.slice(0, 1_000);
    const candidate = event?.verificationUrl ?? event?.verificationUri ?? event?.url;
    if (candidate) {
      try {
        const url = new URL(candidate);
        if (url.protocol === 'https:' && url.hostname === 'dash.cloudflare.com' && !url.username && !url.password) {
          const lifetimeMs = Number.isFinite(event.expiresInMs) ? Math.min(Math.max(event.expiresInMs, 0), 15 * 60_000) : undefined;
          device = { url: url.href, code: String(event.userCode ?? event.code ?? '').slice(0, 50),
            ...(lifetimeMs === undefined ? {} : { expiresAt: Date.now() + lifetimeMs }) };
        }
      } catch { /* Auth providers may only link to their official host. */ }
    }
  };
  const save = (patch) => {
    writeQueue = writeQueue.then(async () => {
      const next = clone(state);
      for (const key of ['resources', 'intents', 'backups']) {
        if (patch[key]) next[key] = { ...next[key], ...clone(patch[key]) };
      }
      await store.write(next);
      Object.assign(state, next);
    });
    return writeQueue;
  };
  const exclusive = async (operation) => {
    if (busy) throw installationError('另一个步骤仍在执行，请等待或停止', 'BUSY');
    busy = true;
    lastError = undefined;
    controller = new AbortController();
    try { return await operation(controller.signal); }
    catch (error) { lastError = publicError(error); throw error; }
    finally { busy = false; controller = undefined; }
  };
  const verifyIdentity = async (plan, signal) => {
    googleIdentity = await google.inspectIdentity({ signal });
    cloudflareIdentity = await cloudflare.inspectIdentity({ signal });
    if (googleIdentity.email !== plan.googleEmail ||
        !cloudflareIdentity.accounts?.some((account) => account.id === plan.cloudflareAccountId)) {
      throw installationError('目前授权帐号与安装纪录不符，已停止，没有切换到其他专案', 'IDENTITY_MISMATCH');
    }
  };

  return {
    async listRuns() {
      const root = await realpath(rootDir);
      const local = path.join(root, '.local');
      const base = path.join(local, 'install');
      for (const directory of [local, base]) {
        const stat = await lstat(directory).catch((error) => { if (error.code !== 'ENOENT') throw error; });
        if (!stat) return [];
        if (!stat.isDirectory() || stat.isSymbolicLink()) throw installationError('安装纪录目录不正确');
      }
      const candidates = (await readdir(base)).filter((name) => RUN_ID.test(name)).slice(0, 100);
      const results = [];
      for (const runId of candidates) {
        try {
          const candidate = await openStore(rootDir, runId);
          const record = await candidate.read();
          validateStoredPlan(record.plan, resumable, mode);
          results.push({ runId, appName: record.plan.churchConfig.appName, projectId: record.plan.projectId, status: record.status });
        } catch { /* Invalid or different-version records cannot become resume targets. */ }
      }
      return results;
    },
    snapshot() {
      return {
        demo, busy, message, error: lastError,
        // Relative time, so the page's countdown does not depend on its clock.
        device: device && { url: device.url, code: device.code,
          ...(device.expiresAt ? { expiresInMs: Math.max(0, device.expiresAt - Date.now()) } : {}) },
        identity: {
          googleEmail: googleIdentity?.email,
          cloudflareEmail: cloudflareIdentity?.email,
          accounts: (cloudflareIdentity?.accounts ?? []).map(({ id, name }) => ({ id, name })),
        },
        plan: state?.plan,
        status: state?.status ?? 'setup',
        steps: STEPS.map(({ id, label }) => ({ id, label, status: state?.steps?.[id] ?? 'pending' })),
        website: state?.status === 'complete' ? verifiedWebsite(state.resources?.website) : undefined,
        regions: REGIONS,
        release,
        installs: installs?.map(({ accountId, accountName, pagesProject, website, appName, readable, currentRelease }) =>
          ({ accountId, accountName, pagesProject, website, appName, readable, currentRelease })),
        update: update && {
          status: update.status,
          pagesProject: update.plan.pagesProject, cloudflareAccountId: update.plan.cloudflareAccountId,
          appName: update.plan.churchConfig.appName, website: update.target.website,
          currentRelease: update.target.currentRelease, release: update.plan.release,
          steps: UPDATE_STEPS.filter(({ id }) => id !== 'domain' || update.plan.customDomain || update.steps.domain)
            .map(({ id, label }) => ({ id, label, status: update.steps[id] ?? 'pending' })),
          unchanged: update.result?.unchanged,
          iconSource: update.icons ? 'new' : update.liveIcons ? 'live' : 'neutral',
          customDomain: update.plan.customDomain,
          domain: update.domain && { status: update.domain.status, cname: update.domain.cname },
        },
      };
    },
    findInstalls() {
      return exclusive(async (signal) => {
        if (state?.approved && state.status !== 'complete') throw installationError('目前有一个安装还没完成；请先完成或停止它，再更新网站');
        if (!googleIdentity?.email || !cloudflareIdentity?.accounts?.length) throw installationError('请先连接 Google 与 Cloudflare', 'CONFIRMATION_REQUIRED');
        message = '正在寻找这组帐号装过的网站…';
        update = undefined;
        const found = await cloudflare.listInstalls({ signal });
        const next = [];
        for (const item of found.slice(0, 20)) {
          const website = `https://${item.subdomain}/`;
          const [config, version] = await Promise.all([
            fetchSite(`${website}church-config.json`, { signal }), fetchSite(`${website}version.json`, { signal }),
          ]);
          let churchConfig;
          try { churchConfig = config && coreChurchConfig(config); } catch { /* Unreadable: listed, but cannot update. */ }
          next.push({
            ...item, website, churchConfig, readable: Boolean(churchConfig), appName: churchConfig?.appName,
            currentRelease: typeof version?.release === 'string' ? version.release.slice(0, 20) : undefined,
            liveBuildVersion: typeof version?.version === 'string' ? version.version.slice(0, 200) : undefined,
          });
        }
        installs = next;
        message = installs.length ? '请选择要更新的网站' : '这组 Google／Cloudflare 帐号底下，找不到安装精灵装过的网站';
      });
    },
    planUpdate({ pagesProject, accountId } = {}) {
      return exclusive(async (signal) => {
        const target = installs?.find((item) => item.pagesProject === pagesProject && item.accountId === accountId);
        if (!target) throw installationError('请先按「寻找已安装的网站」，再选择一个', 'INVALID_INPUT');
        if (!target.readable) throw installationError('这个网站是旧版精灵装的，读不到教会设定，没办法自动更新。', 'UPDATE_UNSUPPORTED');
        update = {
          plan: {
            schemaVersion: 1, kind: 'update', mode, runId: target.runId, projectId: target.projectId,
            pagesProject: target.pagesProject, cloudflareAccountId: target.accountId, googleEmail: googleIdentity.email,
            churchConfig: target.churchConfig, createdAt: new Date().toISOString(), release: release?.version,
          },
          target, status: 'ready', steps: {},
        };
        const live = {};
        await Promise.all(Object.keys(ICON_SIZES).map(async (name) => { live[name] = await fetchAsset(`${target.website}${name}`, { signal }); }));
        update.liveIcons = iconSet(live) ?? undefined;
        message = '请核对要更新的网站，再按「开始更新」';
      });
    },
    // A new logo (five PNGs the page drew from the church's image), or back to neutral.
    setUpdateIcons({ icons, reset } = {}) {
      return exclusive(async () => {
        if (!update || update.status === 'running') throw installationError('请先选择要更新的网站', 'INVALID_INPUT');
        if (reset) {
          update.icons = undefined;
          update.liveIcons = undefined;
          message = '这次更新会改回预设图示';
          return;
        }
        update.icons = decodeIcons(icons);
        message = '已套用新的 Logo，会在这次更新一起发布';
      });
    },
    applyUpdate({ confirm, customDomain } = {}) {
      return exclusive(async (signal) => {
        if (!update || confirm !== update.plan.pagesProject) throw installationError('请勾选确认要更新的网站', 'CONFIRMATION_REQUIRED');
        const domain = customDomain ? normalizeCustomDomain(customDomain) : undefined;
        if (customDomain && !domain) throw installationError('自订网址要是你们拥有的子网域，例如 staff.hope-church.org（不能只填 hope-church.org）', 'INVALID_INPUT');
        update.plan.customDomain = domain;
        update.domain = undefined;
        await verifyIdentity(update.plan, signal);
        const runDir = await updateDirectory(rootDir, update.plan.runId);
        const checkpoint = { resources: {}, intents: {} };
        const context = {
          plan: clone(update.plan), runDir, checkpoint, emit, signal, transient: {},
          liveBuildVersion: update.target.liveBuildVersion, icons: update.icons ?? update.liveIcons,
          save: async (patch) => { for (const key of ['resources', 'intents']) Object.assign(checkpoint[key], clone(patch[key] ?? {})); },
        };
        update.status = 'running';
        update.steps = {};
        update.result = undefined;
        try {
          for (const step of UPDATE_STEPS) {
            signal.throwIfAborted();
            if (step.id === 'domain' && !domain) continue;
            update.steps[step.id] = 'running';
            message = step.label;
            if (step.provider === 'build') await build(context);
            else if (step.provider === 'accounts') await setUpAccountAdmin({ google, cloudflare, context, update: true });
            else if (step.provider === 'google') await google.update(step.id, context);
            else if (step.provider === 'domain') {
              update.domain = await cloudflare.addCustomDomain(context);
              await google.update('domain', context);
            } else {
              update.result = await cloudflare.publishUpdate(context);
              // The site now runs on the key stored above; the old ones can go.
              const keep = context.transient.retireAccountAdminKeys;
              if (keep) await google.retireOtherAccountAdminKeys(context, { update: true, keep });
            }
            update.steps[step.id] = context.transient.unchanged && ['build', 'publish'].includes(step.id) ? 'skipped' : 'complete';
          }
          update.status = 'complete';
          message = update.result?.unchanged ? '网站程式已经是最新版本，不需要重新发布。' : '更新完成。同工下次打开 App 就会换到新版。';
        } catch (error) {
          const current = UPDATE_STEPS.find((step) => update.steps[step.id] === 'running');
          if (current) update.steps[current.id] = signal.aborted ? 'paused' : 'failed';
          update.status = 'paused';
          throw error;
        }
      });
    },
    connectGoogle() {
      return exclusive(async (signal) => {
        message = '请切到 Cloud Shell 分页：若出现「Authorize Cloud Shell」，按 Authorize 并选择这次要用的 Google 帐号';
        googleIdentity = await (google.authorize ?? google.inspectIdentity)({ signal });
        message = 'Google 帐号已连接';
      });
    },
    connectCloudflare() {
      return exclusive(async (signal) => {
        device = undefined;
        message = '正在开启 Cloudflare 官方授权';
        await cloudflare.startLogin({ emit, signal });
        cloudflareIdentity = await cloudflare.inspectIdentity({ signal });
        device = undefined;
        message = 'Cloudflare 帐号已连接';
      });
    },
    plan(input) {
      return exclusive(async (signal) => {
        if (state?.approved) throw installationError('这次安装已开始，不能更改设定或另建专案；请接续原安装');
        // The optional logo travels with the form but is stored beside the record.
        const form = input && typeof input === 'object' && !Array.isArray(input);
        const { icons: iconInput, ...fields } = form ? input : {};
        const icons = iconInput == null ? undefined : decodeIcons(iconInput);
        const plan = createInstallationPlan(form ? fields : input, {
          googleEmail: googleIdentity?.email, accounts: cloudflareIdentity?.accounts,
        }, { sourceRevision, mode, iconHashes: icons && iconHashes(icons) });
        // Read-only checks before anything is recorded or confirmed. Google
        // offers no read-only quota/terms check; those surface at the first
        // step, before any other resource exists.
        message = '正在检查帐号与网站名称…';
        await verifyIdentity(plan, signal);
        await cloudflare.preflight?.(plan, { signal });
        const nextStore = await openStore(rootDir, plan.runId);
        const next = { schemaVersion: 1, plan, approved: false, status: 'ready', steps: {}, resources: {}, intents: {}, backups: {} };
        // The logo first, so a record never points at files that were not written.
        try {
          if (icons) await writePlanIcons(nextStore.runDir, icons);
          await nextStore.write(next, true);
        } catch (error) {
          await rm(logoDirectory(nextStore.runDir), { recursive: true, force: true });
          throw error;
        }
        state = next;
        store = nextStore;
        transient = {};
        message = '请核对新专案、资料地区与管理员，再确认安装';
        return plan;
      });
    },
    load(runId) {
      return exclusive(async () => {
        if (state?.approved && state.plan.runId !== runId) throw installationError('请先完成或停止目前的安装，不可在执行期间切换目标');
        const nextStore = await openStore(rootDir, runId);
        const next = await nextStore.read();
        validateStoredPlan(next.plan, resumable, mode);
        if (next.schemaVersion !== 1 || typeof next.approved !== 'boolean') throw installationError('安装纪录格式不正确');
        assertCheckpointSafe(next);
        state = next;
        state.status = state.status === 'complete' ? 'complete' : 'paused';
        store = nextStore;
        transient = {};
        writeQueue = Promise.resolve();
        message = '已载入纪录；请重新连接相同帐号，再确认接续';
      });
    },
    apply({ digest, confirmProject, confirmAdmin, acknowledgeRegion, acknowledgeEmail } = {}) {
      return exclusive(async (signal) => {
        if (!state || digest !== state.plan.digest || confirmProject !== state.plan.projectId ||
            confirmAdmin !== state.plan.admin.email || acknowledgeRegion !== true || acknowledgeEmail !== true) {
          throw installationError('请明确核对新专案、管理员、资料地区与寄信，再确认安装', 'CONFIRMATION_REQUIRED');
        }
        validateStoredPlan(state.plan, resumable, mode);
        await verifyIdentity(state.plan, signal);
        // Before anything is marked as started: a missing logo stops here.
        const icons = await readPlanIcons(store.runDir, state.plan.icons);
        state.approved = true;
        state.status = 'running';
        await store.write(state);
        const runId = state.plan.runId;
        count('started', { runId });
        const context = {
          plan: { ...clone(state.plan), activationEmailConfirmed: true },
          runDir: store.runDir, checkpoint: state, save, emit, signal, transient,
          icons,
        };
        try {
          for (const step of STEPS) {
            signal.throwIfAborted();
            // Providers re-inspect previously completed steps; checkpoints are not authority.
            state.steps[step.id] = 'running';
            message = step.label;
            await store.write(state);
            if (step.provider === 'build') await build(context);
            else if (step.provider === 'accounts') await setUpAccountAdmin({ google, cloudflare, context });
            else await (step.provider === 'google' ? google : cloudflare).execute(step.id, context);
            await writeQueue;
            state.steps[step.id] = 'complete';
            await store.write(state);
          }
          state.status = 'complete';
          count('completed', { runId });
          message = '部署步骤已完成。请查看管理员信箱并实际登入验收；规则可能需要几分钟生效。';
        } catch (error) {
          const current = STEPS.find((step) => state.steps[step.id] === 'running');
          if (current) state.steps[current.id] = signal.aborted ? 'paused' : error.actionRequired ? 'waiting' : 'failed';
          count('stopped', { runId, step: current?.id, code: signal.aborted ? 'CANCELLED' : error.code ?? 'UNEXPECTED' });
          state.status = 'paused';
          await store.write(state);
          throw error;
        } finally {
          await store.write(state);
        }
      });
    },
    cancel() {
      controller?.abort();
      message = '正在停止；已建立的云端资源不会删除，之后可核对状态再接续';
    },
    async dispose() {
      controller?.abort();
      await cloudflare.dispose?.();
      transient = {};
      googleIdentity = undefined;
      cloudflareIdentity = undefined;
      device = undefined;
    },
  };
}
