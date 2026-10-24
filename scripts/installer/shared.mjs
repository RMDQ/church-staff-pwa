// Contract shared by the installer core and its adapters. Keeping it in one
// place means a new step, tool version or build artifact is declared once.
import { createHash } from 'node:crypto';
import { lstat, readFile } from 'node:fs/promises';
import path from 'node:path';

export const FLUTTER_VERSION = '3.41.0';
export const WRANGLER_VERSION = '4.138.0';

// Order is execution order. `provider` selects the adapter that owns the step.
export const STEPS = [
  ['google-project', '建立专属 Google 专案', 'google'],
  ['firebase', '准备 Firebase', 'google'],
  ['database', '建立资料库', 'google'],
  ['auth', '设定帐号登入', 'google'],
  ['web-app', '取得网站设定', 'google'],
  ['pages-project', '准备网站空间', 'cloudflare'],
  ['build', '建置教会网站', 'build'],
  ['rules', '部署资料存取规则', 'google'],
  ['admin', '建立指定管理员', 'google'],
  ['account-admin', '设定同工帐号管理', 'accounts'],
  ['publish', '发布网站', 'cloudflare'],
  ['auth-domains', '设定登入网域', 'google'],
  ['activation', '寄送管理员设定密码信', 'google'],
].map(([id, label, provider]) => ({ id, label, provider }));

// The site's secret holding the key of the service account that creates and
// removes staff sign-ins (worker/account_admin.js). The step that sets it up
// ('accounts' provider above) runs Google and Cloudflare in turn.
export const ACCOUNT_ADMIN_SECRET = 'ACCOUNT_ADMIN_KEY';

export const stepIdsFor = (provider) => new Set(STEPS.filter((step) => step.provider === provider).map((step) => step.id));

// Update mode: rebuild an existing install from the latest source. No data,
// staff account or admin is touched; the site, its rules and the account
// management key (set up here for sites installed before it existed) change.
export const UPDATE_STEPS = [
  ['inspect', '核对网站与 Google 专案', 'google'],
  // Before the build: a newly stored key only reaches the site with a new
  // deployment, so it makes an otherwise unchanged build publish anyway.
  ['account-admin', '设定同工帐号管理', 'accounts'],
  ['build', '建置新版网站', 'build'],
  ['rules', '更新资料存取规则', 'google'],
  ['publish', '发布新版网站', 'cloudflare'],
  // Only when the church asked for its own address.
  ['domain', '设定自订网址', 'domain'],
].map(([id, label, provider]) => ({ id, label, provider }));

// A subdomain the church owns, e.g. staff.hope-church.org. Apex domains only
// work with Cloudflare nameservers, which this wizard cannot set up.
export function normalizeCustomDomain(value) {
  const domain = typeof value === 'string' ? value.trim().toLowerCase().replace(/\.$/, '') : '';
  const labels = domain.split('.');
  if (domain.length > 253 || labels.length < 3 || labels.some((label) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ||
      /^\d+$/.test(labels.at(-1)) || /\.(?:pages\.dev|workers\.dev|cloudshell\.dev|firebaseapp\.com|web\.app)$/.test(domain)) return null;
  return domain;
}

// Icons the update may replace, with their required pixel size.
export const ICON_SIZES = Object.freeze({
  'favicon.png': 32, 'icons/Icon-192.png': 192, 'icons/Icon-512.png': 512,
  'icons/Icon-maskable-192.png': 192, 'icons/Icon-maskable-512.png': 512,
});

// A PNG of exactly the given size, or null. Only the signature and IHDR are
// read: the browser made it from a canvas, and Pages serves it as a file.
export function checkPng(bytes, size) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 33 || bytes.length > 1024 * 1024) return null;
  if (!bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return null;
  if (bytes.toString('latin1', 12, 16) !== 'IHDR' || bytes.readUInt32BE(16) !== size || bytes.readUInt32BE(20) !== size) return null;
  return bytes;
}

// First installs only use the neutral artwork shipped in web/.
export const CORE_ICONS = Object.freeze({
  favicon: 'favicon.png', icon192: 'icons/Icon-192.png', icon512: 'icons/Icon-512.png',
  maskable192: 'icons/Icon-maskable-192.png', maskable512: 'icons/Icon-maskable-512.png',
});

// Project and Pages names are derived from the run so a retry can never pick
// a different target.
export const projectIdFor = (runId) => `church-${runId.replaceAll('-', '').slice(0, 20)}`;

export function installationError(message, code = 'INSTALLATION_ERROR') {
  return Object.assign(new Error(message), { code, safeToDisplay: true });
}

export const sha256 = (text) => createHash('sha256').update(text).digest('hex');

// Key order must not change a fingerprint, so objects are serialized sorted.
export const canonical = (value) => JSON.stringify(value, (_, entry) => entry && !Array.isArray(entry) && typeof entry === 'object'
  ? Object.fromEntries(Object.keys(entry).sort().map((key) => [key, entry[key]])) : entry);
export const fingerprint = (value) => sha256(canonical(value) ?? 'null');

export const isPrivateDirectory = (stat) => stat.isDirectory() && !stat.isSymbolicLink() && (process.platform === 'win32' || (stat.mode & 0o077) === 0);

// A complete, finalized Pages upload. Build checks it after finalizing and
// publish checks it again right before upload.
const REQUIRED_BUILD_FILES = ['index.html', 'main.dart.js', 'flutter_bootstrap.js', 'cache_sw.js', 'firebase-messaging-sw.js', 'version.json', 'canvaskit/canvaskit.wasm', '_worker.js/index.js'];
const UNRESOLVED_PLACEHOLDER = /__(?:FIREBASE_[A-Z_]+|BUILD_VERSION|VENDOR_VERSION)__/;

export async function verifyBuildArtifacts(directory, fail) {
  for (const name of REQUIRED_BUILD_FILES) {
    const stat = await lstat(path.join(directory, name)).catch(() => null);
    if (!stat?.isFile() || stat.size === 0) throw fail('建置产物不完整，禁止发布。');
  }
  for (const name of ['cache_sw.js', 'firebase-messaging-sw.js']) {
    if (UNRESOLVED_PLACEHOLDER.test(await readFile(path.join(directory, name), 'utf8'))) throw fail('建置含未替换设定，禁止发布。');
  }
}
