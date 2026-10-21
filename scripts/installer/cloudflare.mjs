import { chmod, lstat, mkdir, mkdtemp, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { privateEnvironment, runIsolatedCommand } from './process.mjs';
import { fingerprint, installationError, isPrivateDirectory, projectIdFor, stepIdsFor, verifyBuildArtifacts, WRANGLER_VERSION } from './shared.mjs';

export const CLOUDFLARE_SCOPES = ['account:read', 'user:read', 'pages:write'];
const API = 'https://api.cloudflare.com/client/v4';
const ACCOUNT_ID = /^[a-f0-9]{32}$/;
const RUN_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// A Pages project this wizard created, recognisable from Cloudflare alone: a
// direct upload (no Git source) to 'main' whose production env vars are exactly
// the two the create step writes, naming a run and the Google project derived
// from it. Returns that pair, or null for anything else in the account.
export function installerBinding(project) {
  const vars = project?.deployment_configs?.production?.env_vars;
  if (!project || project.source || project.production_branch !== 'main' || !vars ||
      Object.keys(vars).sort().join() !== 'FIREBASE_PROJECT_ID,INSTALLER_RUN_ID') return null;
  const runId = vars.INSTALLER_RUN_ID?.type === 'plain_text' ? vars.INSTALLER_RUN_ID.value : undefined;
  const projectId = vars.FIREBASE_PROJECT_ID?.type === 'plain_text' ? vars.FIREBASE_PROJECT_ID.value : undefined;
  if (!RUN_ID.test(runId ?? '') || projectId !== projectIdFor(runId)) return null;
  if (typeof project.subdomain !== 'string' || !/^[a-z0-9][a-z0-9-]{0,62}\.pages\.dev$/.test(project.subdomain)) return null;
  return { runId, projectId };
}
const STEP_IDS = stepIdsFor('cloudflare');
const cloudflareError = (message) => installationError(message, 'CLOUDFLARE_INSTALL_FAILED');

export function parseDevicePrompt(output) {
  const clean = output.replace(/\x1b\[[0-9;]*m/g, '');
  const match = clean.match(/To authorize [^\n]+, please visit:\s+(https:\/\/[^\s]+)\s+and enter the code:\s+([A-Za-z0-9]{8}|[A-Z0-9]{4}-[A-Z0-9]{4})(?![A-Za-z0-9-])/);
  if (!match) return null;
  const url = new URL(match[1]);
  // The CLI prints the bare URI. Do not forward arbitrary query strings,
  // fragments or URLs from diagnostic output (which can contain tokens).
  if (url.origin !== 'https://dash.cloudflare.com' || url.username || url.password || url.search || url.hash || !/^\/oauth2\/[a-z/-]+$/.test(url.pathname)) return null;
  return { verificationUrl: url.href, userCode: match[2] };
}

function safeJson(stdout) {
  try { return JSON.parse(stdout); } catch { throw cloudflareError('Cloudflare 工具回应格式不符，请重新授权。'); }
}

const configurationFingerprint = (project) => fingerprint(project.deployment_configs);

async function verifyUpload(directory) {
  if (!path.isAbsolute(directory) || !(await lstat(directory)).isDirectory()) throw cloudflareError('Pages 建置目录格式不符。');
  async function visit(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.name.startsWith('.env') || ['firebase-config.json', 'firestore.rules', 'dart-defines.json'].includes(entry.name)) throw cloudflareError('Pages 产物含私人设定档，禁止发布。');
      if (entry.isDirectory()) await visit(file);
      else if (!entry.isFile() || (await lstat(file)).nlink !== 1) throw cloudflareError('Pages 产物不可包含符号连结、硬连结或特殊档案。');
    }
  }
  await visit(directory);
  await verifyBuildArtifacts(directory, (message) => cloudflareError(`Pages ${message}`));
}

export function createCloudflareInstaller({ command = runIsolatedCommand, fetchImpl = fetch, sessionDir, wrangler = process.env.INSTALLER_WRANGLER || 'wrangler', environment = process.env, loginTimeoutMs = 310_000, requestTimeoutMs = 30_000, wait = delay } = {}) {
  if (!sessionDir || !path.isAbsolute(sessionDir)) throw cloudflareError('Cloudflare 需要独立的绝对路径暂存目录。');
  let home;
  let initializing;
  let disposed = false;
  let loginActive = false;
  const activeCommands = new Set();
  const lifetime = new AbortController();
  async function init() {
    if (disposed) throw cloudflareError('Cloudflare 授权已结束，请重新开启安装精灵。');
    if (!initializing) initializing = (async () => {
      const stat = await lstat(sessionDir);
      if (!isPrivateDirectory(stat)) throw cloudflareError('Cloudflare 暂存目录必须是私人目录（0700）。');
      home = await mkdtemp(path.join(sessionDir, 'cloudflare-'));
      await chmod(home, 0o700);
      // Wrangler prefers the legacy home once it exists. Create it before any CLI
      // process so login and later commands always read the same credential store.
      await mkdir(path.join(home, '.wrangler'), { mode: 0o700 });
      await mkdir(path.join(home, 'tmp'), { mode: 0o700 });
    })();
    await initializing;
  }
  async function cli(args, { signal, onStdout, timeoutMs, accountId } = {}) {
    await init();
    const pending = Promise.resolve().then(() => command(wrangler, args, {
      cwd: home, env: { ...privateEnvironment(home, environment), ...(accountId ? { CLOUDFLARE_ACCOUNT_ID: accountId } : {}) },
      signal: AbortSignal.any([lifetime.signal, ...(signal ? [signal] : [])]), onStdout, timeoutMs,
    }));
    activeCommands.add(pending);
    try { return await pending; }
    catch { throw cloudflareError('Cloudflare 工具无法完成，请重新授权或重试。'); }
    finally { activeCommands.delete(pending); }
  }
  async function inspectIdentity({ signal } = {}) {
    const result = await cli(['whoami', '--json'], { signal });
    const data = safeJson(result.stdout);
    if (!data.loggedIn) return { loggedIn: false, accounts: [] };
    if (result.exitCode !== 0 || data.authType !== 'OAuth Token' || !Array.isArray(data.accounts)) throw cloudflareError('请使用本次安装的 Cloudflare 官方授权，不支援 API Key。');
    if (!CLOUDFLARE_SCOPES.every((scope) => data.tokenPermissions?.includes(scope))) throw cloudflareError('Cloudflare 授权缺少必要的 Pages 或帐号读取权限，请重新授权。');
    const accounts = data.accounts.filter((account) => ACCOUNT_ID.test(account.id) && typeof account.name === 'string').map(({ id, name }) => ({ id, name: name.slice(0, 200) }));
    return { loggedIn: true, email: typeof data.email === 'string' ? data.email.slice(0, 254) : '', accounts };
  }
  async function startLogin({ emit = () => {}, signal } = {}) {
    if (loginActive) throw cloudflareError('Cloudflare 授权正在进行，请完成或取消后再试。');
    loginActive = true;
    let buffer = '';
    let shown = false;
    const onStdout = (chunk) => {
      buffer = (buffer + chunk).slice(-16_384);
      const prompt = parseDevicePrompt(buffer);
      if (prompt && !shown) {
        shown = true;
        // The wizard stops waiting at loginTimeoutMs; approving later cannot finish this login.
        emit({ type: 'authorization', provider: 'cloudflare', ...prompt, expiresInMs: Math.max(0, loginTimeoutMs - 10_000),
          message: '请按「开启官方授权页」，在 Cloudflare 页面输入下列代码，再按 Authorize。' });
      }
    };
    try {
      const version = await cli(['--version'], { signal });
      if (version.exitCode !== 0 || version.stdout.trim() !== WRANGLER_VERSION) throw cloudflareError(`需要 Wrangler ${WRANGLER_VERSION}，请由 Cloud Shell 安装入口重开。`);
      const result = await cli(['login', '--device', '--browser=false', '--scopes', ...CLOUDFLARE_SCOPES], { signal, onStdout, timeoutMs: loginTimeoutMs });
      onStdout(result.stdout);
      if (result.exitCode !== 0 || !shown) throw cloudflareError('Cloudflare 授权未完成或已过期；请确认未拒绝授权，再重新连接。');
      const identity = await inspectIdentity({ signal });
      if (!identity.loggedIn || !identity.accounts.length) throw cloudflareError('Cloudflare 尚无可用帐号，请在官方网站建立帐号后重试。');
      return identity;
    } catch (error) {
      // Even CLI failures can contain token text. Only our own fixed messages
      // are exposed; partial credentials are discarded before another attempt.
      if (home) { await rm(home, { recursive: true, force: true }); home = undefined; initializing = undefined; }
      if (signal?.aborted || lifetime.signal.aborted) throw cloudflareError('Cloudflare 授权已取消。');
      if (shown) throw cloudflareError('这组 Cloudflare 代码已失效或未获授权。请按「连接 Cloudflare」取得新代码，并在倒数结束前按 Authorize；旧代码即使显示成功也不能再用。');
      throw cloudflareError('Cloudflare 授权未完成、遭拒绝或已逾时，请重新连接；请确认使用指定版本 Wrangler。');
    } finally { loginActive = false; }
  }
  async function token(signal) {
    const result = await cli(['auth', 'token', '--json'], { signal });
    const data = safeJson(result.stdout);
    if (result.exitCode !== 0 || data.type !== 'oauth' || typeof data.token !== 'string' || !data.token) throw cloudflareError('Cloudflare 授权已失效，请重新连接。');
    return data.token;
  }
  async function api(route, { method = 'GET', body, signal, missing = false } = {}) {
    const accessToken = await token(signal);
    for (let attempt = 0; attempt < 4; attempt += 1) {
      let response;
      try {
        response = await fetchImpl(`${API}${route}`, {
          method, headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
          ...(body ? { body: JSON.stringify(body) } : {}),
          signal: AbortSignal.any([lifetime.signal, AbortSignal.timeout(requestTimeoutMs), ...(signal ? [signal] : [])]), redirect: 'error',
        });
      } catch { throw cloudflareError('无法连线 Cloudflare，请稍后重新授权并续跑；不会自动删除资源。'); }
      if (response.status === 404 && missing) return null;
      if (method === 'GET' && (response.status === 429 || response.status >= 500) && attempt < 3) { await wait(500 * 2 ** attempt, undefined, { signal }); continue; }
      let data;
      try { data = await response.json(); } catch { throw cloudflareError('Cloudflare 回传无法辨识的资料，已停止。'); }
      if (!response.ok || data.success !== true) throw cloudflareError(`Cloudflare 操作失败（HTTP ${response.status}）；请确认 Pages 权限、帐号方案与额度，再续跑。`);
      return data;
    }
  }
  async function deployments(base, signal) {
    const result = [];
    const pageSize = 25;
    for (let page = 1; page <= 20; page += 1) {
      const data = await api(`${base}/deployments?per_page=${pageSize}&page=${page}`, { signal });
      if (!Array.isArray(data.result)) throw cloudflareError('Pages 部署清单格式不符。');
      result.push(...data.result);
      if (data.result.length < pageSize) return result;
    }
    throw cloudflareError('Pages 已有过多部署，不符合全新安装条件。');
  }
  // Cloudflare may add a suffix when the name is taken elsewhere; trust only its answer.
  function pagesSubdomain(project, plan) {
    const subdomain = project?.subdomain;
    if (typeof subdomain !== 'string' || !/^[a-z0-9][a-z0-9-]{0,62}\.pages\.dev$/.test(subdomain) || !subdomain.startsWith(plan.pagesProject)) {
      throw cloudflareError('Cloudflare 未回传可辨识的网站网址，已停止。');
    }
    return subdomain;
  }
  // Resume may only continue a project this run created. Every condition
  // below is evidence of that: the durable create intent, the exact name and
  // account, direct upload (no Git source), production branch 'main', and the
  // two env vars written atomically at creation. Once recorded, the project id,
  // settings fingerprint and subdomain must also stay unchanged.
  function verifyProject(project, context) {
    const { plan, checkpoint } = context;
    const intent = checkpoint.intents?.pagesProject;
    const recorded = checkpoint.resources ?? {};
    const vars = project?.deployment_configs?.production?.env_vars;
    const createdByThisRun = project && intent && intent.runId === plan.runId && intent.name === plan.pagesProject &&
      intent.accountId === plan.cloudflareAccountId && project.name === plan.pagesProject &&
      project.production_branch === 'main' && !project.source;
    const bindingsMatch = vars?.INSTALLER_RUN_ID?.value === plan.runId && vars?.FIREBASE_PROJECT_ID?.value === plan.projectId &&
      vars?.INSTALLER_RUN_ID?.type === 'plain_text' && vars?.FIREBASE_PROJECT_ID?.type === 'plain_text' &&
      Object.keys(vars || {}).every((key) => ['INSTALLER_RUN_ID', 'FIREBASE_PROJECT_ID'].includes(key));
    const unchangedSinceRecorded = (!recorded.pagesProjectId || project.id === recorded.pagesProjectId) &&
      (!recorded.pagesConfigFingerprint || configurationFingerprint(project) === recorded.pagesConfigFingerprint) &&
      (!recorded.pagesSubdomain || project.subdomain === recorded.pagesSubdomain);
    if (!createdByThisRun || !bindingsMatch || !unchangedSinceRecorded) {
      throw cloudflareError('Pages 目标已存在或设定已变更，且无法确认属于本次安装；不会接管或覆盖。');
    }
  }
  // Every deployment must be this run's production upload (same marker).
  function assertOnlyOwnDeployments(existing, marker) {
    for (const deployment of existing) {
      if (!marker || deployment.environment !== 'production' || deployment.deployment_trigger?.metadata?.branch !== 'main' ||
          deployment.deployment_trigger?.metadata?.commit_message !== marker) {
        throw cloudflareError('Pages 已有非本次安装的部署，已停止；不会覆盖既有网站。');
      }
    }
  }
  const projectRoute = (plan) => `/accounts/${plan.cloudflareAccountId}/pages/projects/${plan.pagesProject}`;
  async function prepare(context) {
    const { plan, signal } = context;
    if (!ACCOUNT_ID.test(plan.cloudflareAccountId) || !/^[a-z0-9][a-z0-9-]{0,57}$/.test(plan.pagesProject) || !/^[A-Za-z0-9_-]{8,80}$/.test(plan.runId) || !/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(plan.projectId)) throw cloudflareError('Cloudflare 安装计划格式不符。');
    const identity = await inspectIdentity({ signal });
    if (!identity.accounts.some((account) => account.id === plan.cloudflareAccountId)) throw cloudflareError('请明确选择目前已授权的 Cloudflare 帐号。');
    return (await api(projectRoute(plan), { signal, missing: true }))?.result;
  }
  // Read-only check before confirmation: the account is usable and the name free.
  async function preflight(plan, { signal } = {}) {
    if (await prepare({ plan, signal })) throw cloudflareError(`你的 Cloudflare 帐号里已经有叫「${plan.pagesProject}」的网站，请换一个网站名称再预览。`);
  }
  async function createPagesProject(context) {
    const { plan, checkpoint, save, signal } = context;
    let project = await prepare(context);
    if (!project) {
      if (checkpoint.resources?.pagesProjectId) throw cloudflareError('本次 Pages 专案已被移除，已停止以避免重建其他站台。');
      const intent = { runId: plan.runId, accountId: plan.cloudflareAccountId, name: plan.pagesProject };
      await save({ intents: { pagesProject: intent } });
      checkpoint.intents = { ...checkpoint.intents, pagesProject: intent };
      await api(`/accounts/${plan.cloudflareAccountId}/pages/projects`, { method: 'POST', signal, body: {
        name: plan.pagesProject, production_branch: 'main', deployment_configs: {
          production: { env_vars: { FIREBASE_PROJECT_ID: { type: 'plain_text', value: plan.projectId }, INSTALLER_RUN_ID: { type: 'plain_text', value: plan.runId } } },
        },
      } });
      project = (await api(projectRoute(plan), { signal })).result;
    }
    verifyProject(project, context);
    assertOnlyOwnDeployments(await deployments(projectRoute(plan), signal), checkpoint.intents?.pagesPublish?.marker);
    await save({ resources: { pagesProjectId: project.id, pagesProject: project.name, pagesSubdomain: pagesSubdomain(project, plan), pagesConfigFingerprint: configurationFingerprint(project) } });
    return { pagesProject: project.name };
  }
  async function publish(context) {
    const { plan, checkpoint, save, signal, transient } = context;
    const base = projectRoute(plan);
    const project = await prepare(context);
    verifyProject(project, context);
    const existing = await deployments(base, signal);
    const publishIntent = checkpoint.intents?.pagesPublish;
    assertOnlyOwnDeployments(existing, publishIntent?.marker);
    if (!transient.buildDir || !transient.buildVersion) throw cloudflareError('缺少已验证的建置产物，禁止发布。');
    await verifyUpload(transient.buildDir);
    const marker = `installer:${plan.runId}:${transient.buildVersion}`;
    if (publishIntent && publishIntent.marker !== marker) throw cloudflareError('本次建置版本已改变，请勿用续跑覆盖已部署内容。');
    await save({ intents: { pagesPublish: { marker } } });
    const completed = (item) => item?.latest_stage?.name === 'deploy' && item.latest_stage.status === 'success';
    const failed = (item) => ['failure', 'canceled'].includes(item?.latest_stage?.status);
    const previousFailures = new Set(existing.filter(failed).map((item) => item.id));
    let deployment = existing.find(completed) || existing.find((item) => !failed(item));
    if (!deployment) {
      verifyProject((await api(base, { signal })).result, context);
      const result = await cli(['pages', 'deploy', transient.buildDir, '--project-name', plan.pagesProject, '--branch', 'main', '--commit-message', marker, '--commit-dirty=true'], { signal, accountId: plan.cloudflareAccountId, timeoutMs: 600_000 });
      if (result.exitCode !== 0) throw cloudflareError('Pages 发布尚未确认完成；请重新授权并续跑，安装器会先查询实际部署状态。');
    }
    for (let attempt = 0; attempt < 60; attempt += 1) {
      const all = await deployments(base, signal);
      if (all.some((item) => item.environment !== 'production' || item.deployment_trigger?.metadata?.branch !== 'main' || item.deployment_trigger?.metadata?.commit_message !== marker)) throw cloudflareError('发布期间侦测到其他 Pages 部署，已停止。');
      deployment = all.find(completed) || all.find((item) => !failed(item)) || all.find((item) => !previousFailures.has(item.id));
      if (completed(deployment)) {
        const current = (await api(base, { signal })).result;
        verifyProject(current, context);
        const website = `https://${pagesSubdomain(current, plan)}`;
        transient.website = website;
        await save({ resources: { pagesDeploymentId: deployment.id, website } });
        return { website };
      }
      if (failed(deployment)) throw cloudflareError('Pages 部署失败，请至 Cloudflare 官方部署页确认原因；不会自动覆写。');
      await wait(2000, undefined, { signal });
    }
    throw cloudflareError('Pages 部署仍未完成，请稍后续跑以确认实际状态。');
  }
  // Every install in the connected accounts, for update mode to offer.
  async function listInstalls({ signal } = {}) {
    const identity = await inspectIdentity({ signal });
    if (!identity.loggedIn) throw cloudflareError('请先连接 Cloudflare。');
    const found = [];
    for (const account of identity.accounts) {
      for (let page = 1; page <= 20; page += 1) {
        const data = await api(`/accounts/${account.id}/pages/projects?per_page=10&page=${page}`, { signal });
        if (!Array.isArray(data.result)) throw cloudflareError('Pages 专案清单格式不符。');
        for (const project of data.result) {
          const binding = installerBinding(project);
          if (binding && /^[a-z0-9][a-z0-9-]{0,57}$/.test(project.name ?? '')) {
            found.push({ accountId: account.id, accountName: account.name, pagesProject: project.name, subdomain: project.subdomain, ...binding });
          }
        }
        const totalPages = data.result_info?.total_pages;
        if (data.result.length < 10 || (Number.isInteger(totalPages) && page >= totalPages)) break;
      }
    }
    return found;
  }
  // Update mode's ownership proof, re-read right before anything is uploaded.
  async function updateTarget(context) {
    const { plan, signal } = context;
    if (!ACCOUNT_ID.test(plan.cloudflareAccountId) || !/^[a-z0-9][a-z0-9-]{0,57}$/.test(plan.pagesProject)) throw cloudflareError('更新目标格式不符。');
    const project = (await api(projectRoute(plan), { signal, missing: true }))?.result;
    const binding = installerBinding(project);
    if (!binding || binding.runId !== plan.runId || binding.projectId !== plan.projectId || project.name !== plan.pagesProject) {
      throw cloudflareError('这个 Cloudflare 网站不是安装精灵为这次选择的教会建立的，或设定已被改过；不会更新。');
    }
    return project;
  }
  // Only this install's own uploads may exist: an update never overwrites a
  // site someone deployed by other means.
  function assertOnlyInstallerDeployments(existing, runId) {
    for (const deployment of existing) {
      if (deployment.environment !== 'production' || deployment.deployment_trigger?.metadata?.branch !== 'main' ||
          !String(deployment.deployment_trigger?.metadata?.commit_message ?? '').startsWith(`installer:${runId}:`)) {
        throw cloudflareError('这个网站有不是安装精灵发布的版本；为避免覆盖别人的部署，已停止。');
      }
    }
  }
  async function publishUpdate(context) {
    const { plan, signal, transient } = context;
    const base = projectRoute(plan);
    const project = await updateTarget(context);
    const existing = await deployments(base, signal);
    assertOnlyInstallerDeployments(existing, plan.runId);
    const completed = (item) => item?.latest_stage?.name === 'deploy' && item.latest_stage.status === 'success';
    const failed = (item) => ['failure', 'canceled'].includes(item?.latest_stage?.status);
    const website = `https://${project.subdomain}/`;
    if (transient.unchanged) return { website, unchanged: true };
    if (!transient.buildDir || !transient.buildVersion) throw cloudflareError('缺少已验证的建置产物，禁止发布。');
    await verifyUpload(transient.buildDir);
    const marker = `installer:${plan.runId}:${transient.buildVersion}`;
    const ours = (item) => item.deployment_trigger?.metadata?.commit_message === marker;
    const previousFailures = new Set(existing.filter((item) => ours(item) && failed(item)).map((item) => item.id));
    // A resumed update whose upload already went through only waits for it.
    if (!existing.some((item) => ours(item) && !failed(item))) {
      const result = await cli(['pages', 'deploy', transient.buildDir, '--project-name', plan.pagesProject, '--branch', 'main', '--commit-message', marker, '--commit-dirty=true'], { signal, accountId: plan.cloudflareAccountId, timeoutMs: 600_000 });
      if (result.exitCode !== 0) throw cloudflareError('新版网站发布尚未确认完成；请重新按「开始更新」，精灵会先查询实际部署状态。');
    }
    for (let attempt = 0; attempt < 60; attempt += 1) {
      const all = await deployments(base, signal);
      assertOnlyInstallerDeployments(all, plan.runId);
      const deployment = all.find((item) => ours(item) && !previousFailures.has(item.id));
      if (completed(deployment)) {
        await updateTarget(context);
        return { website, unchanged: false };
      }
      if (failed(deployment)) throw cloudflareError('新版网站部署失败，请至 Cloudflare 官方部署页确认原因；旧版网站仍照常运作。');
      await wait(2000, undefined, { signal });
    }
    throw cloudflareError('新版网站部署仍未完成，请稍后重新按「开始更新」确认实际状态。');
  }
  // Attach the church's own subdomain. The wizard has no DNS permission, so
  // the church adds the CNAME itself; Cloudflare checks it and issues the
  // certificate. Adding first is deliberate: a CNAME to pages.dev that exists
  // before the domain is attached answers with an error page.
  async function addCustomDomain(context) {
    const { plan, signal } = context;
    const project = await updateTarget(context);
    const domain = plan.customDomain;
    if (typeof domain !== 'string' || !/^[a-z0-9.-]{4,253}$/.test(domain)) throw cloudflareError('自订网址格式不符。');
    const route = `${projectRoute(plan)}/domains`;
    const listed = await api(route, { signal });
    if (!Array.isArray(listed.result)) throw cloudflareError('Pages 网域清单格式不符。');
    let entry = listed.result.find((item) => item.name === domain);
    if (!entry) entry = (await api(route, { method: 'POST', body: { name: domain }, signal })).result;
    const status = ['initializing', 'pending', 'active', 'deactivated', 'blocked', 'error'].includes(entry?.status) ? entry.status : 'pending';
    return { domain, status, cname: { name: domain.split('.')[0], fullName: domain, target: project.subdomain } };
  }
  async function execute(step, context) {
    if (!STEP_IDS.has(step)) throw cloudflareError('不支援的 Cloudflare 安装步骤。');
    return step === 'pages-project' ? createPagesProject(context) : publish(context);
  }
  async function dispose() {
    disposed = true;
    lifetime.abort();
    await initializing?.catch(() => {});
    await Promise.allSettled([...activeCommands]);
    if (home) await rm(home, { recursive: true, force: true });
  }
  return { inspectIdentity, startLogin, preflight, execute, listInstalls, publishUpdate, addCustomDomain, dispose };
}
