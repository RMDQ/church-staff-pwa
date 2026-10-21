// Only provisions resources inside the project created by this installation.
// Importing/constructing this adapter never reads credentials or contacts Google.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { bootstrap, buildAdminProfile, enabledServiceIds, firestoreValue } from '../bootstrap-admin.mjs';
import { renderRules } from '../prepare-deployment.mjs';
import { runCommand } from './process.mjs';
import { canonical, fingerprint, sha256 as hash, stepIdsFor } from './shared.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const hosts = new Set(['cloudresourcemanager', 'serviceusage', 'firebase', 'firestore', 'identitytoolkit', 'firebaserules']);
const quotaProjectHosts = new Set(['firebase', 'firestore', 'identitytoolkit', 'firebaserules']);
const steps = stepIdsFor('google');
const projectPattern = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Firestore REST omits empty repeated fields on read: a written
// {arrayValue:{values:[]}} comes back as {arrayValue:{}} (same for empty maps).
// Compare documents in that read-back form, or every profile with an empty
// list would look like someone else's data.
function readBackForm(value) {
  if (Array.isArray(value)) return value.map(readBackForm);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key, entry]) => !(['values', 'fields'].includes(key) &&
      (Array.isArray(entry) ? entry.length === 0 : entry && typeof entry === 'object' && Object.keys(entry).length === 0)))
    .map(([key, entry]) => [key, readBackForm(entry)]));
}
const documentFingerprint = (fields) => fingerprint(readBackForm(fields ?? {}));
const encodedName = (name) => name.split('/').map(encodeURIComponent).join('/');

export class ActionRequired extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ActionRequired';
    this.code = code;
    this.safeToDisplay = true;
    this.actionRequired = true;
  }
}

function stop(code, message) { throw new ActionRequired(code, message); }
function conflict(message = '云端资源已存在或被其他操作变更；为避免接管既有站，已停止。请核对本次安装纪录。') {
  stop('GOOGLE_RESOURCE_CONFLICT', message);
}

// Never expose provider messages, request URLs, command output or response bodies.
function cloudError(status, error = {}, authSetup = false) {
  const reason = `${error.status ?? ''} ${error.message ?? ''} ${canonical(error.details ?? [])}`.toUpperCase();
  if (authSetup && (status === 404 || /CONFIGURATION_NOT_FOUND|PROJECT_NOT_FOUND|OPERATION_NOT_ALLOWED/.test(reason))) {
    stop('AUTH_SETUP_REQUIRED', '请按下方「开启官方设定页」，在 Firebase 的 Authentication 页按「Get started」。看到一排登入方式就完成了，不用再点任何一种，也不要升级付费方案；回到这里按「核对后接续安装」，精灵会自己设定 Email 登入。');
  }
  if (/BILLING|BLAZE|IDENTITY_PLATFORM.*UPGRADE/.test(reason)) {
    stop('GOOGLE_FREE_TIER_REQUIRED', 'Google 要求付费方案；安装器不会绑定帐单或升级。请核对免费 Firebase 设定后再继续。');
  }
  if (/TERMS|TOS_|TOS NOT ACCEPTED|AGREEMENT/.test(reason)) {
    stop('GOOGLE_TERMS_REQUIRED', '请先在 Google Cloud／Firebase 官方网站接受帐号所需条款，再回到此处继续。');
  }
  // Right after services:batchEnable, Google can still answer 403 SERVICE_DISABLED
  // for a few minutes. It is not a permission problem; waiting fixes it.
  if (/SERVICE_DISABLED|ACCESS_NOT_CONFIGURED|API HAS NOT BEEN USED|IT IS DISABLED/.test(reason)) {
    stop('GOOGLE_API_PROPAGATING', 'Google 刚启用的服务还在生效中，通常需要 1–3 分钟。请稍候再按「稍后接续安装」；不需要改任何设定。');
  }
  if (status === 401 || status === 16) stop('GOOGLE_AUTH_REQUIRED', 'Google 授权已过期或未完成；请重新完成 Cloud Shell 官方授权，再继续本次安装。');
  // A per-minute request limit, not a quota to raise: waiting a minute clears it.
  if (/RATE_LIMIT_EXCEEDED/.test(reason)) {
    stop('GOOGLE_RATE_LIMITED', 'Google 暂时挡下太多次请求，不用改任何设定。请等 5 分钟后按「稍后接续安装」。');
  }
  if (status === 429 || status === 8 || /QUOTA|RESOURCE_EXHAUSTED/.test(reason)) {
    stop('GOOGLE_QUOTA_REQUIRED', 'Google 专案或 API 配额不足；请到官方配额页核对，稍后再继续。安装进度已保留。');
  }
  if (status === 403 || status === 7 || /ORG_POLICY|PERMISSION_DENIED/.test(reason)) {
    stop('GOOGLE_PERMISSION_REQUIRED', '目前 Google 帐号缺少建立或设定此专案的权限，或受到组织政策限制。请由组织管理员核对权限；不会切换到其他凭证。');
  }
  if (status === 409 || status === 6 || /ALREADY_EXISTS|EMAIL_EXISTS|DUPLICATE_LOCAL_ID/.test(reason)) conflict();
  stop('GOOGLE_API_FAILED', 'Google API 未完成操作；请稍后续跑以核对实际状态。未自动删除或覆写既有资源。');
}

// One step's view of the plan: derived resource names, a short-lived token
// refreshed on demand, and the checkpoint helpers every step shares.
function openStepSession(context, { fetchImpl, command, delay, now, inspectIdentity }, { update = false } = {}) {
  const { plan, signal } = context;
  // An update has no admin to create and reads the region from the database.
  if (!projectPattern.test(plan?.projectId ?? '') || !emailPattern.test(plan?.googleEmail ?? '') ||
      typeof plan.runId !== 'string' || !/^[a-zA-Z0-9_-]{8,100}$/.test(plan.runId) ||
      !/^[a-z0-9][a-z0-9-]{0,57}[a-z0-9]$/.test(plan.pagesProject ?? '') ||
      (!update && (!/^[a-z][a-z0-9-]{1,40}$/.test(plan.region ?? '') ||
        !emailPattern.test(plan.admin?.email ?? '') || !plan.admin?.name || !plan.admin?.username))) {
    stop('GOOGLE_INVALID_PLAN', '安装计划的专案、地区或管理员资料无效；未读取凭证或连线。');
  }
  const serviceIds = enabledServiceIds(plan.churchConfig);
  const projectId = plan.projectId;
  const project = `projects/${projectId}`;
  const database = `${project}/databases/(default)`;
  const documents = `${database}/documents`;
  const authPath = `/v1/${project}/accounts`;
  // Matches Firebase CLI's documented admin configuration endpoint; the
  // discovery method path alone omits this prefix. Never try a paid setup API.
  const configPath = `/admin/v2/${project}/config`;
  const runLabel = hash(plan.runId).slice(0, 32);
  const adminUid = `install-${hash(plan.runId).slice(0, 40)}`;
  context.transient ??= {};
  context.checkpoint.resources ??= {};
  // Cloudflare may suffix the name; use the verified subdomain the Pages step saved.
  const pagesDomain = () => {
    const value = context.checkpoint.resources.pagesSubdomain;
    if (typeof value !== 'string' || !/^[a-z0-9][a-z0-9-]{0,62}\.pages\.dev$/.test(value) || !value.startsWith(plan.pagesProject)) {
      stop('GOOGLE_INVALID_PLAN', '尚未取得已核对的网站网址，不能设定登入网域或寄送设定密码信。');
    }
    return value;
  };
  context.checkpoint.intents ??= {};
  let token;
  let checkedAt = -Infinity;

  async function save(section, key, value) {
    await context.save({ [section]: { [key]: value } });
    // Also support hosts whose save writes durably without mutating the view.
    context.checkpoint[section][key] = value;
  }
  const resource = (key) => context.checkpoint.resources[key];
  const intent = (key) => context.checkpoint.intents[key];
  async function begin(key, value) {
    if (!intent(key)) await save('intents', key, { ...value, at: new Date(now()).toISOString() });
    return intent(key);
  }
  async function credentials() {
    if (token && now() - checkedAt < 60_000) return;
    const identity = await inspectIdentity({ signal });
    if (identity.email !== plan.googleEmail.toLowerCase()) {
      stop('GOOGLE_ACCOUNT_CHANGED', '目前 Google 登入与确认安装时不同；请回到原帐号再续跑，不会使用其他身分写入。');
    }
    try {
      token = (await command('gcloud', ['auth', 'print-access-token', `--account=${identity.email}`, '--quiet'], { signal })).stdout.trim();
    } catch {
      signal?.throwIfAborted();
      stop('GOOGLE_AUTH_REQUIRED', '无法取得 Google 短期授权；请重新完成 Cloud Shell 官方授权。');
    }
    if (!token || /\s/.test(token)) stop('GOOGLE_AUTH_REQUIRED', 'Google 短期授权无效；请重新完成官方授权。');
    checkedAt = now();
  }
  async function request(host, pathname, { method = 'GET', body, missing = false, authSetup = false, readOnly = method === 'GET', beforeSend, locale } = {}) {
    if (!hosts.has(host) || !pathname.startsWith('/') || /[\r\n#]/.test(pathname)) stop('GOOGLE_INVALID_TARGET', 'Google API 目标无效。');
    for (let attempt = 0; attempt < 4; attempt++) {
      signal?.throwIfAborted();
      await credentials();
      let response;
      let data;
      // Marks the write as possibly sent only once nothing can stop it locally.
      if (beforeSend && attempt === 0) await beforeSend();
      try {
        response = await fetchImpl(`https://${host}.googleapis.com${pathname}`, {
          method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
            ...(quotaProjectHosts.has(host) ? { 'x-goog-user-project': projectId } : {}),
            ...(locale ? { 'X-Firebase-Locale': locale } : {}) },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: 'error',
          signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(30_000)]) : AbortSignal.timeout(30_000),
        });
        const text = await response.text();
        if (text.length > 4 * 1024 * 1024) stop('GOOGLE_INVALID_RESPONSE', 'Google 回应超出预期大小；已停止操作。');
        data = text ? JSON.parse(text) : {};
      } catch (error) {
        signal?.throwIfAborted();
        if (error instanceof ActionRequired) throw error;
        stop('GOOGLE_CONNECTION_INTERRUPTED', 'Google 连线中断；操作可能已被接受。请续跑核对状态，不要另建第二个安装。');
      }
      if (response.ok) return data;
      if (response.status === 404 && missing) return null;
      if (readOnly && (response.status === 429 || response.status >= 500) && attempt < 3) {
        await delay(500 * 2 ** attempt, signal);
        continue;
      }
      const reasonCode = [data.error?.status, ...(data.error?.details ?? []).map((item) => item?.reason)]
        .filter((value) => typeof value === 'string' && /^[A-Z_]{3,60}$/.test(value)).slice(0, 2).join(' ');
      if (readOnly && /SERVICE_DISABLED/.test(reasonCode) && attempt < 3) {
        await delay(5000 * 2 ** attempt, signal);
        continue;
      }
      try { cloudError(response.status, data.error, authSetup); }
      catch (failure) {
        // Only the service, HTTP status and Google's reason enum: enough for
        // support, never a URL, body or credential.
        if (failure instanceof ActionRequired) failure.message += `〔技术代码：${host} ${response.status}${reasonCode ? ` ${reasonCode}` : ''}〕`;
        // These answers are definite refusals: nothing was created. A 5xx may
        // still have been accepted, so only these let a create be retried.
        // 408 and 499 (cancelled) can still hide an accepted request.
        if ([400, 401, 403, 404, 409, 429].includes(response.status)) failure.rejected = true;
        throw failure;
      }
    }
  }
  function operationPath(host, name) {
    const simple = /^operations\/[a-zA-Z0-9_.:-]+$/;
    // Firebase Management runs addFirebase and webApps.create as workflows,
    // e.g. operations/workflows/<base64 id>. The id carries no project, so the
    // finished response is checked against this project in wait().
    const firebase = /^operations\/workflows\/[A-Za-z0-9+_=-]+$/;
    const firestore = new RegExp(`^projects/${projectId}/databases/\\(default\\)/operations/[a-zA-Z0-9_.:-]+$`);
    const valid = host === 'firestore' ? firestore.test(name ?? '')
      : simple.test(name ?? '') || (host === 'firebase' && firebase.test(name ?? ''));
    if (!valid) stop('GOOGLE_INVALID_RESPONSE', 'Google operation 目标与本次安装不一致；已停止。');
    return encodedName(name);
  }
  async function wait(host, version, operation, key) {
    if (!operation || typeof operation !== 'object') stop('GOOGLE_INVALID_RESPONSE', 'Google 未回传预期的 operation。');
    if (operation.name) {
      operationPath(host, operation.name);
      await save('intents', key, { ...intent(key), operation: operation.name });
    }
    const started = now();
    for (let attempt = 0; ; attempt++) {
      if (operation.done) {
        if (operation.error) {
          // A terminal failure is not an uncertain write. Reconcile resources
          // on the next run, then allow a new attempt after permissions/quota
          // are fixed instead of polling the same failed operation forever.
          const { operation: _failed, requested: _sent, ...previous } = intent(key);
          await save('intents', key, { ...previous, lastOperationFailed: true });
          cloudError(operation.error.code, operation.error);
        }
        if (operation.response?.projectId !== undefined && operation.response.projectId !== projectId) conflict('Google operation 完成结果不属于本次专案；已停止。');
        return operation.response;
      }
      if (!operation.name) stop('GOOGLE_INVALID_RESPONSE', 'Google operation 缺少名称；请续跑核对资源。');
      if (attempt >= 45 || now() - started >= 180_000) stop('GOOGLE_OPERATION_PENDING', 'Google 仍在建立资源；本次 operation 已保存，请稍后续跑。');
      if (attempt % 5 === 0) {
        const label = { googleProject: '新专案', googleServices: 'Firebase 所需 API', firebase: 'Firebase', database: 'Firestore 资料库' }[key] ?? '云端资源';
        context.emit?.({ message: `Google 正在准备${label}（本阶段已等待 ${Math.floor((now() - started) / 1000)} 秒）` });
      }
      await delay(Math.min(1000 * 2 ** attempt, 8000), signal);
      operation = await request(host, `/${version}/${operationPath(host, operation.name)}`);
    }
  }
  // Each create is sent at most once per intent. The flag is saved before the
  // POST; if no operation was saved after it, Google may have accepted it, so a
  // resume reads the resource back (callers do) and never sends it again.
  async function createOrWait(host, version, key, pathname, body) {
    if (intent(key)?.operation) {
      return wait(host, version, await request(host, `/${version}/${operationPath(host, intent(key).operation)}`), key);
    }
    if (intent(key)?.requested) {
      stop('GOOGLE_REQUEST_UNCONFIRMED', 'Google 可能已接受上一次建立请求，但精灵没有收到可核对的回复。为避免重复建立，不会重送；请等 3–5 分钟后按「核对后接续安装」，精灵会先读回实际资源。若多次接续仍停在这里，请保留安装识别码并求助。');
    }
    const { lastRequestRejected: _previous, ...pending } = intent(key);
    let operation;
    try {
      operation = await request(host, pathname, { method: 'POST', body,
        beforeSend: () => save('intents', key, { ...pending, requested: true }) });
    }
    catch (error) {
      if (error.rejected && intent(key).requested) {
        const { requested: _sent, ...rest } = intent(key);
        await save('intents', key, { ...rest, lastRequestRejected: true });
      }
      throw error;
    }
    return wait(host, version, operation, key);
  }
  function checkProject(value) {
    if (!value || !intent('googleProject') ||
        (!intent('googleProject').operation && !intent('googleProject').adoptedByLabel && !resource('googleProject')) || value.projectId !== projectId ||
        value.labels?.['church-install'] !== runLabel || value.state !== 'ACTIVE' ||
        !/^projects\/\d+$/.test(value.name ?? '') ||
        (resource('googleProject') && resource('googleProject').projectNumber !== value.name.split('/')[1])) conflict();
    return value;
  }
  async function ownedProject() {
    return checkProject(await request('cloudresourcemanager', `/v3/${project}`));
  }
  async function noOtherData(requireAdmin = Boolean(resource('admin'))) {
    const db = await request('firestore', `/v1/${encodedName(database)}`);
    if (!intent('database')?.uid || db.name !== database || db.uid !== intent('database').uid ||
        (resource('database') && resource('database').uid !== db.uid) || db.locationId !== plan.region ||
        db.type !== 'FIRESTORE_NATIVE' || (db.databaseEdition && db.databaseEdition !== 'STANDARD')) conflict('Firestore 资料库身分或地区已变更；不会写入替换后的资料库。');
    const collections = await request('firestore', `/v1/${encodedName(documents)}:listCollectionIds`, { method: 'POST', body: { pageSize: 2 }, readOnly: true });
    if (requireAdmin && !(collections.collectionIds ?? []).includes('users')) conflict('本次管理员 profile 已消失；不会自动重新建立或升权。');
    if (collections.nextPageToken || (collections.collectionIds ?? []).some((id) => id !== 'users')) conflict('此专案已有其他 Firestore 资料；首次安装不会接管或覆写。');
    if ((collections.collectionIds ?? []).includes('users')) {
      const result = await request('firestore', `/v1/${encodedName(documents)}/users?pageSize=2&showMissing=true`);
      if (!intent('adminProfile') || result.nextPageToken || (result.documents ?? []).length !== 1 ||
          result.documents[0].name !== `${documents}/users/${adminUid}` ||
          documentFingerprint(result.documents[0].fields) !== intent('adminProfile').fieldsFingerprint) conflict('此专案已有其他使用者资料；不会覆写或升权。');
      const children = await request('firestore', `/v1/${encodedName(documents)}/users/${adminUid}:listCollectionIds`, { method: 'POST', body: { pageSize: 1 }, readOnly: true });
      if (children.nextPageToken || children.collectionIds?.length) conflict('此专案已有使用者子集合资料；首次安装已停止。');
    }
  }
  function checkAuthUser(user) {
    if (!user || user.localId !== adminUid || user.email?.toLowerCase() !== plan.admin.email.toLowerCase() ||
        user.disabled || user.customAttributes || user.validSince && Number(user.validSince) < 0) conflict('管理员 Auth 身分与本次安装不一致；不会使用或升权既有帐号。');
    return { localId: user.localId, email: user.email, disabled: false };
  }
  async function onlyOwnAuth() {
    const data = await request('identitytoolkit', `${authPath}:batchGet?maxResults=2`, { authSetup: true });
    if (data.nextPageToken || (data.users ?? []).some((user) => !intent('adminAuth') || user.localId !== adminUid) || (data.users ?? []).length > 1) {
      conflict('此专案已有其他 Firebase Auth 帐号；首次安装不会接管。');
    }
    return data.users?.length ? checkAuthUser(data.users[0]) : null;
  }
  async function getAuthConfig() {
    const config = await request('identitytoolkit', configPath, { authSetup: true });
    if (![`${project}/config`, `projects/${resource('googleProject')?.projectNumber}/config`].includes(config.name) || config.subtype === 'IDENTITY_PLATFORM' ||
        config.signIn?.phoneNumber?.enabled || config.signIn?.anonymous?.enabled || config.signIn?.allowDuplicateEmails) {
      conflict('Firebase Auth 设定不是预期的免费首次安装状态；请核对官方设定，不会自动变更其他登入方式。');
    }
    return config;
  }
  return {
    plan, context, signal, now, delay: (ms) => delay(ms, signal), serviceIds, projectId, project, database, documents, authPath, configPath, runLabel, adminUid,
    token: () => token, pagesDomain, save, resource, intent, begin, credentials, request, operationPath, wait, createOrWait,
    checkProject, ownedProject, noOtherData, checkAuthUser, onlyOwnAuth, getAuthConfig,
  };
}

// Create the run-labelled Google project, or reconcile a pending create.
async function createProject(s) {
  const { projectId, project, runLabel, save, resource, intent, begin, request, operationPath, wait, createOrWait, checkProject } = s;
  let value;
  try { value = await request('cloudresourcemanager', `/v3/${project}`, { missing: true }); }
  catch (error) {
    // Google can return 403 for a nonexistent ID. Only before our first create intent,
    // try creating this exact ID; an occupied ID cannot be adopted by a POST. A
    // create whose reply was lost may also still read as 403; it waits below.
    if (!(error instanceof ActionRequired && error.code === 'GOOGLE_PERMISSION_REQUIRED' && !resource('googleProject') &&
        (!intent('googleProject') || intent('googleProject').lastRequestRejected || intent('googleProject').requested))) throw error;
    value = null;
  }
  if (!value) {
    if (resource('googleProject')) conflict('本次建立的 Google 专案已消失；不会自动重新建立或切换目标。');
    const earlier = intent('googleProject');
    if (earlier && !earlier.operation && !earlier.requested && !earlier.lastOperationFailed && !earlier.lastRequestRejected) {
      conflict('先前建立请求没有保存 Google operation；无法安全判定专案所有权，不会重送或接管。请核对本次专案后求助。');
    }
    await begin('googleProject', { projectId, runLabel });
    await createOrWait('cloudresourcemanager', 'v3', 'googleProject', '/v3/projects', {
      projectId, displayName: 'Church Staff', labels: { 'church-install': runLabel },
    });
    value = await request('cloudresourcemanager', `/v3/${project}`);
  } else if (value.state !== 'ACTIVE' && intent('googleProject')?.operation) {
    await wait('cloudresourcemanager', 'v3', await request('cloudresourcemanager', `/v3/${operationPath('cloudresourcemanager', intent('googleProject').operation)}`), 'googleProject');
    value = await request('cloudresourcemanager', `/v3/${project}`);
  }
  // The create was sent but its reply was lost. The label is derived from the
  // private run ID (the project ID shows only part of it), so a project with
  // this label, created no earlier than our request, is the one we asked for.
  const unconfirmed = intent('googleProject');
  if (value && unconfirmed?.requested && !unconfirmed.operation && !unconfirmed.adoptedByLabel && !resource('googleProject')) {
    const created = Date.parse(value.createTime ?? '');
    if (value.labels?.['church-install'] !== runLabel || !(created >= Date.parse(unconfirmed.at) - 5 * 60_000)) {
      conflict('Google 专案已存在，但不是这次安装建立的；不会接管。请保留安装识别码并求助，不要另开新的安装。');
    }
    await save('intents', 'googleProject', { ...unconfirmed, adoptedByLabel: true });
  }
  checkProject(value);
  const metadata = { projectId, projectNumber: value.name.split('/')[1], runLabel, createTime: value.createTime };
  await save('resources', 'googleProject', metadata);
  return { googleProject: metadata };
}

// Enable the APIs the app needs and add Firebase to the project.
async function enableFirebase(s) {
  const { owned, projectId, project, save, resource, intent, begin, request, createOrWait } = s;
  const services = ['firebase.googleapis.com', 'firestore.googleapis.com', 'identitytoolkit.googleapis.com', 'firebaserules.googleapis.com'];
  const missing = [];
  s.context.emit?.({ message: '正在核对 Firebase 所需的 Google API…' });
  for (const service of services) {
    const state = await request('serviceusage', `/v1/${owned.name}/services/${service}`);
    if (state.state !== 'ENABLED') missing.push(service);
  }
  if (missing.length) {
    s.context.emit?.({ message: '正在启用 Firebase 所需的 Google API…' });
    await begin('googleServices', { services: missing });
    await createOrWait('serviceusage', 'v1', 'googleServices', `/v1/${owned.name}/services:batchEnable`, { serviceIds: missing });
    s.context.emit?.({ message: '正在核对 Google API 是否已启用…' });
    for (const service of services) {
      if ((await request('serviceusage', `/v1/${owned.name}/services/${service}`)).state !== 'ENABLED') stop('GOOGLE_OPERATION_PENDING', 'Google API 仍在启用；请稍后续跑。');
    }
  }
  s.context.emit?.({ message: '正在核对 Firebase 专案状态…' });
  let firebase = await request('firebase', `/v1beta1/${project}`, { missing: true });
  if (!firebase) {
    if (resource('firebase')) conflict();
    s.context.emit?.({ message: '正在将 Firebase 加入新专案…' });
    await begin('firebase', { projectId });
    await addFirebase(s);
    firebase = await request('firebase', `/v1beta1/${project}`);
  } else if (!intent('firebase')) {
    // Added in the console before this run asked, e.g. someone who did the
    // terms step ahead of time. The project is this run's own (checked by its
    // label before every step), so only its owner can have done it.
    await begin('firebase', { projectId, addedInConsole: true });
  }
  if (!intent('firebase') || firebase.projectId !== projectId || String(firebase.projectNumber) !== owned.name.split('/')[1]) conflict();
  await save('resources', 'firebase', { projectId });
  s.context.emit?.({ message: 'Firebase 已准备完成' });
  return { firebase: { projectId } };
}

// Google accepts the Firebase terms only in the console, once per account, so
// every account new to Firebase stops here with a 403 (its debug detail, when
// Google includes it, reads "Firebase Tos Not Accepted"). The caller owns the
// project this run just created, so the 403 is not missing IAM. Send the
// person to the console at once: retrying cannot accept the terms, and
// addFirebase is rate limited, so a few quick retries end in a 429. If the
// account had accepted them and the new project was still settling, resuming
// in a minute sends it again; otherwise the resume reads back the Firebase
// project the person added in the console.
async function addFirebase(s) {
  const { projectId, intent } = s;
  try { return await s.createOrWait('firebase', 'v1beta1', 'firebase', `/v1beta1/${s.project}:addFirebase`, {}); }
  catch (error) {
    // Refused outright, or its operation failed: either way nothing is pending.
    const refused = error instanceof ActionRequired && ['GOOGLE_TERMS_REQUIRED', 'GOOGLE_PERMISSION_REQUIRED'].includes(error.code) &&
      !intent('firebase')?.requested && !intent('firebase')?.operation;
    if (!refused) throw error;
    // Keep Google's reason code for support; it never carries a URL or credential.
    const code = error.message.match(/〔技术代码：[^〕]*〕/)?.[0] ?? '';
    stop('GOOGLE_TERMS_REQUIRED', [
      '这个 Google 帐号第一次用 Firebase，要先到 Firebase 官网同意条款（每个帐号只做一次）：',
      '1. 按下方「开启官方设定页」',
      '2. 按「如要开始使用，请设定 Firebase 专案」',
      '3. 按最下面的「将 Firebase 新增到 Google Cloud 专案」（不要输入专案名称）',
      `4. 选「Church Staff」（${projectId}），勾选同意条款，一路按继续`,
      '5. 看到专案首页后，回来按「核对后接续安装」',
      '如果以前就用过 Firebase，等 2 分钟再按「核对后接续安装」即可。',
      code,
    ].filter(Boolean).join('\n'));
  }
}

// A brand-new project's IAM takes a minute or two to reach Firestore, which
// meanwhile answers 403 PERMISSION_DENIED. That is not a missing permission
// (a personal Gmail has no organisation to ask), so wait it out, and if it
// still lasts, say so instead of sending people to an administrator.
const NEW_PROJECT_GRACE_MS = 15 * 60_000;
async function createDatabase(s) {
  const created = Date.parse(s.resource('googleProject')?.createTime ?? '');
  const young = () => Number.isFinite(created) && s.now() - created < NEW_PROJECT_GRACE_MS;
  for (let attempt = 0; ; attempt++) {
    try { return await createDatabaseOnce(s); }
    catch (error) {
      const propagating = error instanceof ActionRequired && error.code === 'GOOGLE_PERMISSION_REQUIRED' && error.rejected && young();
      if (!propagating) throw error;
      if (attempt >= 11) {
        stop('GOOGLE_API_PROPAGATING', 'Google 还在替刚建立的新专案开通权限，通常 1–3 分钟。这不是你的帐号有问题，不用改任何设定；请稍候再按「稍后接续安装」。');
      }
      s.context.emit?.({ message: `Google 正在替新专案开通资料库权限，稍候自动重试（第 ${attempt + 1} 次）…` });
      await s.delay(15_000);
    }
  }
}

// Create the (default) Native Firestore database in the confirmed region.
async function createDatabaseOnce(s) {
  const { plan, project, database, save, resource, intent, begin, request, operationPath, wait, createOrWait, noOtherData } = s;
  let listing = await request('firestore', `/v1/${project}/databases`);
  if (listing.unreachable?.length || (listing.databases ?? []).some((db) => db.name !== database)) conflict('此专案已有非预期资料库；首次安装不会接管。');
  let db = listing.databases?.[0];
  if (!db) {
    if (resource('database')) conflict();
    await begin('database', { name: database, locationId: plan.region });
    const result = await createOrWait('firestore', 'v1', 'database', `/v1/${project}/databases?databaseId=%28default%29`, {
      locationId: plan.region, type: 'FIRESTORE_NATIVE', databaseEdition: 'STANDARD',
    });
    if (!result?.uid || result.name !== database) stop('GOOGLE_INVALID_RESPONSE', 'Google 未回传可核对的资料库建立结果；已保留 operation。');
    await save('intents', 'database', { ...intent('database'), uid: result.uid });
    db = await request('firestore', `/v1/${encodedName(database)}`);
  } else if (!intent('database')?.uid && intent('database')?.operation) {
    const result = await wait('firestore', 'v1', await request('firestore', `/v1/${operationPath('firestore', intent('database').operation)}`), 'database');
    if (result?.uid) await save('intents', 'database', { ...intent('database'), uid: result.uid });
  }
  if (!intent('database')?.uid || db.name !== database || db.uid !== intent('database').uid ||
      db.locationId !== plan.region || db.type !== 'FIRESTORE_NATIVE' || (db.databaseEdition && db.databaseEdition !== 'STANDARD')) conflict();
  await noOtherData();
  const metadata = { name: database, uid: db.uid, locationId: db.locationId };
  await save('resources', 'database', metadata);
  return { database: metadata };
}

// Turn on Email/Password sign-in, changing nothing else in the Auth config.
async function enableEmailSignIn(s) {
  const { configPath, save, intent, begin, request, ownedProject, onlyOwnAuth, getAuthConfig } = s;
  let config = await getAuthConfig();
  await onlyOwnAuth();
  const desired = { enabled: true, passwordRequired: true };
  await begin('auth', { before: { email: config.signIn?.email ?? {} }, desired });
  if (canonical(config.signIn?.email ?? {}) !== canonical(desired)) {
    if (canonical(config.signIn?.email ?? {}) !== canonical(intent('auth').before.email)) conflict();
    await ownedProject();
    const check = await getAuthConfig();
    if (canonical(check.signIn?.email ?? {}) !== canonical(intent('auth').before.email)) conflict();
    await request('identitytoolkit', `${configPath}?updateMask=signIn.email`, { method: 'PATCH', body: { signIn: { email: desired } }, authSetup: true });
    config = await getAuthConfig();
  }
  if (canonical(config.signIn?.email) !== canonical(desired)) conflict();
  await save('resources', 'auth', { emailPassword: true });
  return { auth: { emailPassword: true } };
}

// Register the single Web app and hand its public config to the build.
async function registerWebApp(s) {
  const { context, owned, projectId, project, runLabel, save, resource, intent, begin, request, createOrWait } = s;
  const displayName = `Church install ${runLabel}`;
  let apps = await request('firebase', `/v1beta1/${project}/webApps?pageSize=2&showDeleted=true`);
  if (apps.nextPageToken || (apps.apps ?? []).length > 1) conflict();
  let app = apps.apps?.[0];
  if (!app) {
    if (resource('webApp')) conflict();
    await begin('webApp', { displayName });
    await createOrWait('firebase', 'v1beta1', 'webApp', `/v1beta1/${project}/webApps`, { displayName });
    apps = await request('firebase', `/v1beta1/${project}/webApps?pageSize=2&showDeleted=true`);
    if (apps.nextPageToken || apps.apps?.length !== 1) conflict();
    app = apps.apps[0];
  }
  if (!intent('webApp') || app.displayName !== displayName || app.projectId !== projectId || app.state !== 'ACTIVE' ||
      !/^[a-zA-Z0-9:_-]+$/.test(app.appId ?? '') || app.name !== `${project}/webApps/${app.appId}` ||
      (resource('webApp') && resource('webApp').appId !== app.appId)) conflict();
  const config = await request('firebase', `/v1beta1/${encodedName(app.name)}/config`);
  if (config.projectId !== projectId || config.appId !== app.appId || config.authDomain !== `${projectId}.firebaseapp.com` ||
      typeof config.apiKey !== 'string' || !config.apiKey || String(config.messagingSenderId) !== owned.name.split('/')[1]) conflict('Firebase Web 设定与本次专案不一致；未继续建置。');
  context.transient.firebaseConfig = Object.fromEntries(['apiKey', 'authDomain', 'projectId', 'storageBucket', 'messagingSenderId', 'appId']
    .filter((key) => config[key] !== undefined).map((key) => [key, config[key]]));
  const metadata = { appId: app.appId, name: app.name };
  await save('resources', 'webApp', metadata);
  return { webApp: metadata };
}

const releaseNameOf = (s) => `${s.project}/releases/cloud.firestore`;

function rulesetPath(s, name) {
  if (!new RegExp(`^projects/${s.projectId}/rulesets/[a-zA-Z0-9_-]+$`).test(name ?? '')) conflict('Firestore ruleset 不属于本次专案；已停止。');
  return `/v1/${encodedName(name)}`;
}

function ruleSource(source) {
  if (!Array.isArray(source?.files) || source.files.some((file) => typeof file.name !== 'string' || typeof file.content !== 'string')) conflict();
  return { files: source.files.map(({ name, content }) => ({ name, content })) };
}

// The live release and its ruleset, reduced to the fields worth backing up.
async function liveRules(s) {
  const releaseName = releaseNameOf(s);
  const release = await s.request('firebaserules', `/v1/${releaseName}`, { missing: true });
  if (!release) return { release: null, ruleset: null };
  if (release.name !== releaseName) conflict();
  const ruleset = await s.request('firebaserules', rulesetPath(s, release.rulesetName));
  if (ruleset.name !== release.rulesetName) conflict();
  return {
    release: Object.fromEntries(['name', 'rulesetName', 'createTime', 'updateTime']
      .filter((key) => release[key] !== undefined).map((key) => [key, release[key]])),
    ruleset: { name: ruleset.name, source: ruleSource(ruleset.source) },
  };
}

// A brand-new database has no release, or Firebase's single deny-all file.
function isInitialDenyAll(state) {
  if (!state.release) return true;
  if (state.ruleset.source.files.length !== 1) return false;
  const text = state.ruleset.source.files[0].content?.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, '').replace(/\s/g, '');
  return ["rules_version='2';", 'rules_version="2";', ''].some((prefix) =>
    text === `${prefix}servicecloud.firestore{match/databases/{database}/documents{match/{document=**}{allowread,write:iffalse;}}}`);
}

// The rules prepare-deployment staged must equal what this plan generates.
async function generatedRules(s) {
  const { plan, context } = s;
  const source = await readFile(path.join(context.transient.deploymentDir ?? path.join(context.runDir, 'deployment'), 'firestore.rules'), 'utf8');
  const expected = renderRules(await readFile(path.join(ROOT, 'firestore.rules'), 'utf8'), plan.churchConfig);
  if (source !== expected) stop('GOOGLE_RULES_MISMATCH', '待发布规则与本次教会设定产生的规则不同；已停止，请重新产生部署产物。');
  return [{ name: 'firestore.rules', content: `// church-install: ${s.runLabel}\n${source}` }];
}

// Back up the initial state, create (or reuse) this run's ruleset, then release it.
async function releaseRuleset(s, current, files, desiredFingerprint) {
  const { project, save, intent, begin, request, ownedProject } = s;
  const releaseName = releaseNameOf(s);
  if (!intent('rules')) {
    if (!isInitialDenyAll(current)) conflict('Firestore 已有非初始闭锁规则；首次安装不会覆写既有规则。');
    await begin('rules', { fingerprint: desiredFingerprint, before: current, beforeFingerprint: fingerprint(current) });
  }
  if (intent('rules').fingerprint !== desiredFingerprint || intent('rules').beforeFingerprint !== fingerprint(current)) conflict('Firestore 规则在安装中被其他操作变更；未覆写。');
  let name = intent('rules').rulesetName;
  if (name) {
    const known = await request('firebaserules', rulesetPath(s, name));
    if (fingerprint(ruleSource(known.source).files) !== desiredFingerprint) conflict();
  } else {
    const created = await request('firebaserules', `/v1/${project}/rulesets`, { method: 'POST', body: { source: { files } } });
    rulesetPath(s, created.name);
    name = created.name;
    await save('intents', 'rules', { ...intent('rules'), rulesetName: name });
  }
  await ownedProject();
  if (fingerprint(await liveRules(s)) !== intent('rules').beforeFingerprint) conflict('Firestore 规则在发布前已变更；未覆写。');
  const release = { name: releaseName, rulesetName: name };
  // Rules releases have no CAS: updateTime is output-only. Only install into
  // the empty/deny-all state backed up above; never use this as an upgrader.
  await request('firebaserules', current.release ? `/v1/${releaseName}` : `/v1/${project}/releases`, {
    method: current.release ? 'PATCH' : 'POST', body: current.release ? { release } : release,
  });
}

// Publish the generated rules over the empty/deny-all initial state only.
async function publishRules(s) {
  const { context, save, resource, intent, noOtherData } = s;
  await noOtherData();
  const files = await generatedRules(s);
  const desiredFingerprint = fingerprint(files);
  const current = await liveRules(s);
  if (fingerprint(current.ruleset?.source?.files) === desiredFingerprint) {
    // Already live: only accept it as ours if this run recorded that ruleset.
    if (!intent('rules') || intent('rules').fingerprint !== desiredFingerprint ||
        intent('rules').rulesetName !== current.release.rulesetName ||
        (resource('rules') && resource('rules').releaseFingerprint !== fingerprint(current.release))) conflict();
  } else {
    await releaseRuleset(s, current, files, desiredFingerprint);
  }
  const after = await liveRules(s);
  if (fingerprint(after.ruleset?.source?.files) !== desiredFingerprint) conflict('规则发布后的核对结果不同；请检查 Firebase Console，勿继续部署网站。');
  const metadata = { rulesetName: after.release.rulesetName, fingerprint: desiredFingerprint, releaseFingerprint: fingerprint(after.release) };
  await save('resources', 'rules', metadata);
  context.emit?.({ message: '已核对规则发布；Firebase 规则仍可能需要数分钟传播，尚未代表登入权限验收成功。' });
  return { rules: metadata };
}

// Create the Auth user for the confirmed email under this run's fixed uid,
// unless this run already did. No password is set here.
async function ensureAdminAuthUser(s) {
  const { plan, authPath, adminUid, resource, begin, request, ownedProject, checkAuthUser, onlyOwnAuth } = s;
  let user = await onlyOwnAuth();
  if (!user) {
    if (resource('admin')) conflict();
    await begin('adminAuth', { uid: adminUid, email: plan.admin.email });
    await ownedProject();
    const result = await request('identitytoolkit', authPath, { method: 'POST', body: {
      localId: adminUid, email: plan.admin.email, displayName: plan.admin.name, emailVerified: false, disabled: false,
    }, authSetup: true });
    if (result.localId !== adminUid) conflict();
    user = await onlyOwnAuth();
  }
  return checkAuthUser(user);
}

// Hand the create-only profile write to bootstrap-admin, routed through this
// session's request() so it can only reach the three expected endpoints.
async function writeAdminProfileOnce(s, options) {
  const { plan, signal, documents, authPath, adminUid, request } = s;
  const allowed = new Map([
    [`https://identitytoolkit.googleapis.com${authPath}:lookup`, ['identitytoolkit', `${authPath}:lookup`]],
    [`https://firestore.googleapis.com/v1/${documents}/users/${adminUid}`, ['firestore', `/v1/${encodedName(documents)}/users/${adminUid}`]],
    [`https://firestore.googleapis.com/v1/${documents}:commit`, ['firestore', `/v1/${encodedName(documents)}:commit`]],
  ]);
  try {
    await bootstrap(options, {
      getAccessToken: () => s.token(), readConfig: () => plan.churchConfig, log: () => {},
      fetchImpl: async (url, init) => {
        const target = allowed.get(url);
        if (!target) stop('GOOGLE_INVALID_TARGET', '管理员建立要求非预期的 API 目标；已停止。');
        const data = await request(...target, { method: init.method ?? 'GET', body: init.body ? JSON.parse(init.body) : undefined, missing: !init.method });
        return new Response(data === null ? null : JSON.stringify(data), { status: data === null ? 404 : 200 });
      },
    });
  } catch (error) {
    if (error instanceof ActionRequired) throw error;
    signal?.throwIfAborted();
    stop('GOOGLE_ADMIN_CREATE_FAILED', '管理员 create-only 建立未完成；既有 profile 不会覆写。请续跑核对 Auth 身分与资料。');
  }
}

// Create the confirmed admin Auth user and its create-only profile.
async function createAdmin(s) {
  const { plan, now, serviceIds, projectId, documents, adminUid, save, resource, intent, begin, request, ownedProject, noOtherData, getAuthConfig } = s;
  const config = await getAuthConfig();
  if (!config.signIn?.email?.enabled || !config.signIn.email.passwordRequired) stop('AUTH_SETUP_REQUIRED', '请先完成 Email/Password 登入设定，再建立管理员。');
  await noOtherData();
  const user = await ensureAdminAuthUser(s);
  const options = { project: projectId, uid: adminUid, email: plan.admin.email, name: plan.admin.name, username: plan.admin.username,
    config: 'installer-config', apply: true, 'confirm-project': projectId, 'confirm-uid': adminUid };
  const profile = buildAdminProfile(options, user, serviceIds);
  const fields = Object.fromEntries(Object.entries(profile).map(([key, value]) => [key, firestoreValue(value)]));
  const fieldsFingerprint = documentFingerprint(fields);
  const existing = await request('firestore', `/v1/${encodedName(documents)}/users/${adminUid}`, { missing: true });
  if (existing) {
    // Resume: accept only the exact profile this run recorded before writing.
    if (!intent('adminProfile') || intent('adminProfile').fieldsFingerprint !== fieldsFingerprint ||
        existing.name !== `${documents}/users/${adminUid}` || documentFingerprint(existing.fields) !== fieldsFingerprint) {
      conflict('管理员 profile 已存在或不符合本次安装；不覆写、不升权。');
    }
  } else {
    if (resource('admin')) conflict('本次管理员 profile 已被移除；不会自动重新升权。');
    await begin('adminProfile', { uid: adminUid, fieldsFingerprint, before: { exists: false, checkedAt: new Date(now()).toISOString() } });
    if (intent('adminProfile').fieldsFingerprint !== fieldsFingerprint) conflict();
    await ownedProject();
    await writeAdminProfileOnce(s, options);
  }
  await noOtherData(true);
  const metadata = { uid: adminUid, profileFingerprint: fieldsFingerprint };
  await save('resources', 'admin', metadata);
  return { admin: metadata };
}

// Add this run's verified Pages domain to the Auth authorized domains.
async function authorizeDomain(s) {
  const { configPath, pagesDomain, save, intent, begin, request, ownedProject, getAuthConfig } = s;
  const domain = pagesDomain();
  let config = await getAuthConfig();
  const before = config.authorizedDomains ?? [];
  if (!Array.isArray(before) || before.some((value) => typeof value !== 'string')) conflict();
  if (!intent('authDomains')) {
    if (before.includes(domain)) conflict('本次 Pages 登入网域已由其他操作加入；请核对后再继续，不会接管设定。');
    await begin('authDomains', { before: { authorizedDomains: before }, desired: [...before, domain] });
  }
  const desired = intent('authDomains').desired;
  if (canonical(before) !== canonical(desired)) {
    if (canonical(before) !== canonical(intent('authDomains').before.authorizedDomains)) conflict('Auth 登入网域在安装中被其他操作变更；未覆写。');
    await ownedProject();
    const current = await getAuthConfig();
    if (canonical(current.authorizedDomains ?? []) !== canonical(before)) conflict();
    await request('identitytoolkit', `${configPath}?updateMask=authorizedDomains`, { method: 'PATCH', body: { authorizedDomains: desired }, authSetup: true });
    config = await getAuthConfig();
  }
  if (canonical(config.authorizedDomains) !== canonical(desired)) conflict();
  await save('resources', 'authDomains', { domain });
  return { authDomains: { domain } };
}

// Show the church's name as the sender of Firebase's password mails, instead
// of a bare noreply address. Best effort: a refusal never stops the install,
// it only leaves Firebase's default sender.
async function nameMailSender(s) {
  const { plan, configPath, request, getAuthConfig } = s;
  const name = String(plan.churchConfig?.appName ?? '').replace(/[\x00-\x1f<>"]/g, '').slice(0, 60).trim();
  if (!name) return;
  try {
    const current = (await getAuthConfig()).notification?.sendEmail?.resetPasswordTemplate?.senderDisplayName;
    if (current === name) return;
    await request('identitytoolkit', `${configPath}?updateMask=notification.sendEmail.resetPasswordTemplate.senderDisplayName`, {
      method: 'PATCH', authSetup: true, body: { notification: { sendEmail: { resetPasswordTemplate: { senderDisplayName: name } } } },
    });
  } catch (error) {
    if (!(error instanceof ActionRequired)) throw error;
    s.context.emit?.({ message: '寄件者名称没有设定成功，信件会用 Firebase 预设的寄件者；不影响安装。' });
  }
}

// Ask Firebase to send the admin a password-setup email, at most once.
async function sendActivation(s) {
  const { plan, authPath, adminUid, pagesDomain, save, resource, intent, begin, request, noOtherData, onlyOwnAuth, getAuthConfig } = s;
  if (plan.activationEmailConfirmed !== true) stop('ACTIVATION_CONFIRMATION_REQUIRED', '寄送 Firebase 设定密码信前，需要本人确认管理员 email 并同意寄信。');
  const domain = pagesDomain();
  const user = await onlyOwnAuth();
  if (!user || resource('admin')?.uid !== user.localId) conflict();
  await noOtherData();
  if (!(await getAuthConfig()).authorizedDomains?.includes(domain)) conflict();
  if (!resource('activation')?.sent) {
    await nameMailSender(s);
    if (intent('activation')) stop('ACTIVATION_DELIVERY_UNKNOWN', '上次寄信是否被接受无法确定，为避免重复寄信已停止。请先检查信箱和垃圾邮件；若仍未收到，打开网站登入页按「忘记密码？」，输入管理员 email 再寄一次。不要另建管理员。');
    await begin('activation', { uid: adminUid, state: 'sending' });
    // Firebase sends its own message. Never request/retain an OOB link/code.
    // zh-TW picks Firebase's Chinese template; the default is English, which
    // together with a project-id subject reads like a phishing mail.
    await request('identitytoolkit', `${authPath}:sendOobCode`, { method: 'POST', locale: 'zh-TW', body: {
      requestType: 'PASSWORD_RESET', email: user.email, returnOobLink: false, continueUrl: `https://${domain}/`,
    } });
    await save('resources', 'activation', { sent: true });
  }
  return { activation: { sent: true } };
}

// ---------------------------------------------------------------------------
// Update mode. The project is proven to be this install's by the label the
// create step wrote (derived from the private run id, which only the Pages
// project's env vars and the install record know). Nothing is created; data,
// Auth users and settings are never read beyond what is needed here.
// ---------------------------------------------------------------------------

async function installedProject(s) {
  const value = await s.request('cloudresourcemanager', `/v3/${s.project}`);
  if (value.projectId !== s.projectId || value.labels?.['church-install'] !== s.runLabel || value.state !== 'ACTIVE' ||
      !/^projects\/\d+$/.test(value.name ?? '')) {
    conflict('这个 Google 专案不是安装精灵为这个网站建立的，或已被关闭；不会更新。');
  }
  return value;
}

// Read back the web app config the build needs; no write.
async function inspectInstalled(s) {
  const { context, owned, projectId, project, database, runLabel, request } = s;
  const db = await request('firestore', `/v1/${encodedName(database)}`);
  if (db.name !== database || db.type !== 'FIRESTORE_NATIVE') conflict('Firestore 资料库不是安装精灵建立的样子；不会更新。');
  const apps = await request('firebase', `/v1beta1/${project}/webApps?pageSize=2`);
  const app = apps.apps?.length === 1 ? apps.apps[0] : null;
  if (apps.nextPageToken || !app || app.displayName !== `Church install ${runLabel}` || app.state !== 'ACTIVE' ||
      !/^[a-zA-Z0-9:_-]+$/.test(app.appId ?? '') || app.name !== `${project}/webApps/${app.appId}`) {
    conflict('Firebase 网站设定不是安装精灵建立的样子；不会更新。');
  }
  const config = await request('firebase', `/v1beta1/${encodedName(app.name)}/config`);
  if (config.projectId !== projectId || config.appId !== app.appId || typeof config.apiKey !== 'string' || !config.apiKey ||
      String(config.messagingSenderId) !== owned.name.split('/')[1]) conflict('Firebase Web 设定与这个专案不一致；未继续建置。');
  context.transient.firebaseConfig = Object.fromEntries(['apiKey', 'authDomain', 'projectId', 'storageBucket', 'messagingSenderId', 'appId']
    .filter((key) => config[key] !== undefined).map((key) => [key, config[key]]));
  return { region: db.locationId };
}

// Replace the live rules only if they are this install's (first line carries
// its label), and only when the generated rules actually differ.
async function updateRules(s) {
  const { project, runLabel, request, context } = s;
  const files = await generatedRules(s);
  const desired = fingerprint(files);
  const current = await liveRules(s);
  const first = current.ruleset?.source?.files?.[0]?.content ?? '';
  if (!current.release || current.ruleset.source.files.length !== 1 || !first.startsWith(`// church-install: ${runLabel}\n`)) {
    conflict('Firestore 规则不是安装精灵发布的（可能被手动改过）；为避免盖掉别人的设定，已停止。');
  }
  if (fingerprint(current.ruleset.source.files) === desired) return { rules: { unchanged: true } };
  const created = await request('firebaserules', `/v1/${project}/rulesets`, { method: 'POST', body: { source: { files } } });
  rulesetPath(s, created.name);
  await installedProject(s);
  // No compare-and-set exists for releases: re-read right before replacing.
  if (fingerprint(await liveRules(s)) !== fingerprint(current)) conflict('Firestore 规则在更新中被其他操作变更；未覆写。');
  const releaseName = releaseNameOf(s);
  await request('firebaserules', `/v1/${releaseName}`, { method: 'PATCH', body: { release: { name: releaseName, rulesetName: created.name } } });
  const after = await liveRules(s);
  if (fingerprint(after.ruleset?.source?.files) !== desired) conflict('规则更新后的核对结果不同；请检查 Firebase Console。');
  context.emit?.({ message: '已更新资料存取规则；Firebase 可能需要几分钟才完全生效。' });
  return { rules: { unchanged: false } };
}

// Let Firebase Auth accept the church's own address too. Only ever adds.
async function authorizeCustomDomain(s) {
  const { plan, configPath, request, getAuthConfig } = s;
  const domain = plan.customDomain;
  if (typeof domain !== 'string' || !/^[a-z0-9.-]{4,253}$/.test(domain)) stop('GOOGLE_INVALID_PLAN', '自订网址格式不符。');
  const before = (await getAuthConfig()).authorizedDomains ?? [];
  if (!Array.isArray(before) || before.some((value) => typeof value !== 'string')) conflict();
  if (!before.includes(domain)) {
    await installedProject(s);
    await request('identitytoolkit', `${configPath}?updateMask=authorizedDomains`, { method: 'PATCH', body: { authorizedDomains: [...before, domain] }, authSetup: true });
    const after = (await getAuthConfig()).authorizedDomains ?? [];
    if (!after.includes(domain) || before.some((value) => !after.includes(value))) conflict('登入网域更新后的核对结果不同；请检查 Firebase Console。');
  }
  return { authDomains: { domain } };
}

const UPDATE_HANDLERS = { inspect: inspectInstalled, rules: updateRules, domain: authorizeCustomDomain };

const STEP_HANDLERS = {
  'google-project': createProject,
  'firebase': enableFirebase,
  'database': createDatabase,
  'auth': enableEmailSignIn,
  'web-app': registerWebApp,
  'rules': publishRules,
  'admin': createAdmin,
  'auth-domains': authorizeDomain,
  'activation': sendActivation,
};

export function createGoogleInstaller({
  fetchImpl = globalThis.fetch,
  command = (file, args, options = {}) => runCommand(file, args, { timeoutMs: 30_000, maxOutputBytes: 1024 * 1024, ...options }),
  delay = (ms, signal) => sleep(ms, undefined, { signal }),
  now = Date.now,
  authorizeTimeoutMs = 5 * 60_000,
} = {}) {
  async function inspectIdentity({ signal } = {}) {
    signal?.throwIfAborted();
    if (['CLOUDSDK_AUTH_ACCESS_TOKEN', 'CLOUDSDK_AUTH_ACCESS_TOKEN_FILE', 'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
      'CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT'].some((key) => process.env[key])) {
      stop('GOOGLE_AUTH_REQUIRED', '请使用 Cloud Shell 本人的官方登入，不支援环境变数覆写凭证或服务帐号模拟。');
    }
    let accounts;
    let config;
    try {
      accounts = JSON.parse((await command('gcloud', ['auth', 'list', '--filter=status:ACTIVE', '--format=json', '--quiet'], { signal })).stdout);
      config = JSON.parse((await command('gcloud', ['config', 'list', '--format=json', '--quiet'], { signal })).stdout);
    } catch {
      signal?.throwIfAborted();
      stop('GOOGLE_AUTH_REQUIRED', '无法读取 Google 登入身分；请先完成 Cloud Shell 官方授权。');
    }
    const overrides = config.auth ?? {};
    if (['impersonate_service_account', 'credential_file_override', 'access_token_file'].some((key) => overrides[key])) {
      stop('GOOGLE_AUTH_REQUIRED', '目前 gcloud 使用覆写凭证或服务帐号模拟；请改用 Cloud Shell 本人的官方登入。');
    }
    if (!Array.isArray(accounts) || accounts.length !== 1 || accounts[0].status !== 'ACTIVE' ||
        !emailPattern.test(accounts[0].account ?? '') || accounts[0].account.endsWith('.gserviceaccount.com')) {
      stop('GOOGLE_AUTH_REQUIRED', '找不到唯一有效的 Google 个人登入；请先完成 Cloud Shell 官方授权。');
    }
    return { email: accounts[0].account.toLowerCase() };
  }

  // Cloud Shell shows its official "Authorize Cloud Shell" prompt when this
  // wizard's own gcloud first asks for a token, so the credential lands in the
  // configuration the wizard reads (a second terminal tab has another one).
  // The token is discarded; only the identity check result is kept.
  async function authorize({ signal } = {}) {
    try { return await inspectIdentity({ signal }); }
    catch (error) { if (error.code !== 'GOOGLE_AUTH_REQUIRED' || signal?.aborted) throw error; }
    if (process.env.TRUSTED_ENVIRONMENT === 'false') {
      stop('GOOGLE_AUTH_REQUIRED', '这个 Cloud Shell 是「暂时模式」，没有你的 Google 授权。按 Cloud Shell 右上角的「⋮」，点选单里打勾的「暂时模式」，再按「停用」。Cloud Shell 重新启动并请你按「授权」后，回到安装说明页重新按「Open in Cloud Shell」，勾选「信任存放区」再照教学做。精灵会重新开始，尚未建立任何云端资源。');
    }
    try { await command('gcloud', ['auth', 'print-access-token', '--quiet'], { signal, timeoutMs: authorizeTimeoutMs }); }
    catch {
      signal?.throwIfAborted();
      stop('GOOGLE_AUTH_REQUIRED', 'Cloud Shell 没有完成 Google 授权。请按「连接 Google」再试一次，接著立刻切到 Cloud Shell 分页，在「Authorize Cloud Shell」视窗按 Authorize 并选择这次要用的 Google 帐号。');
    }
    return inspectIdentity({ signal });
  }

  async function executeStep(step, context) {
    if (!steps.has(step)) stop('GOOGLE_INVALID_STEP', '不支援的 Google 安装步骤。');
    const s = openStepSession(context, { fetchImpl, command, delay, now, inspectIdentity });
    await s.credentials();
    if (step === 'google-project') return createProject(s);
    // Every later step first proves the project is still the one this run created.
    s.owned = await s.ownedProject();
    return STEP_HANDLERS[step](s);
  }
  async function updateStep(step, context) {
    if (!UPDATE_HANDLERS[step]) stop('GOOGLE_INVALID_STEP', '不支援的更新步骤。');
    const s = openStepSession(context, { fetchImpl, command, delay, now, inspectIdentity }, { update: true });
    await s.credentials();
    s.owned = await installedProject(s);
    return UPDATE_HANDLERS[step](s);
  }
  const update = (step, context) => withHelp(context, () => updateStep(step, context));
  const execute = (step, context) => withHelp(context, () => executeStep(step, context));
  async function withHelp(context, run) {
    try { return await run(); }
    catch (error) {
      if (error instanceof ActionRequired && projectPattern.test(context?.plan?.projectId ?? '')) {
        const id = encodeURIComponent(context.plan.projectId);
        const links = {
          AUTH_SETUP_REQUIRED: `https://console.firebase.google.com/project/${id}/authentication`,
          GOOGLE_FREE_TIER_REQUIRED: `https://console.firebase.google.com/project/${id}/overview`,
          GOOGLE_PERMISSION_REQUIRED: `https://console.cloud.google.com/iam-admin/iam?project=${id}`,
          GOOGLE_QUOTA_REQUIRED: `https://console.cloud.google.com/iam-admin/quotas?project=${id}`,
          GOOGLE_TERMS_REQUIRED: 'https://console.firebase.google.com/',
        };
        if (links[error.code]) error.helpUrl = links[error.code];
      }
      throw error;
    }
  }
  return { inspectIdentity, authorize, execute, update };
}
