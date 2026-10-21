// Live end-to-end check of the calendar write path.
//
// Imports the staged worker/google_calendar.js — the same code/config the deployed
// Pages Function runs — and points it at the real Google Calendar API with the
// real service account key. Nothing here is mocked, so a pass means the JWT
// signing, the OAuth exchange, the API enablement and the calendar sharing are
// all genuinely working. The unit tests cannot tell you any of that.
//
// It creates one all-day event far in the future, reads it back, then deletes
// it. If the delete fails the id is printed so it can be removed by hand.
//
// Usage:
//     node scripts/prepare-deployment.mjs --config .local/church.json --out .local/deployment
//     node scripts/verify-calendar-writer.mjs
// Optional CHURCH_DEPLOYMENT_DIR selects a different prepared output directory.
//
// Reads the key from .local/service-account.json (gitignored) and the calendar
// id from .local/calendar-id, GOOGLE_CALENDAR_ID, or `gh variable get`.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { readChurchConfig } from './read-church-config.mjs';


const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Deliberately in 2099 so a failed cleanup cannot land in anyone's real week.
const PROBE_DATE = '2099-12-31';
const PROBE_TITLE = '（测试）行事历写入检查，可以直接删掉';

function die(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function serviceAccountJson() {
  const file = path.join(ROOT, '.local', 'service-account.json');
  try {
    return readFileSync(file, 'utf8');
  } catch {
    die(
      `找不到 ${path.relative(ROOT, file)}。\n` +
        '  先建立 service account 金钥，或把既有的那份放到这个位置。',
    );
  }
}

function calendarId() {
  const fromEnv = process.env.GOOGLE_CALENDAR_ID?.trim();
  if (fromEnv) return fromEnv;
  try {
    return readFileSync(path.join(ROOT, '.local', 'calendar-id'), 'utf8').trim();
  } catch {
    // Fall through to gh.
  }
  try {
    return execFileSync('gh', ['variable', 'get', 'GOOGLE_CALENDAR_ID'], {
      cwd: ROOT,
      encoding: 'utf8',
    }).trim();
  } catch {
    die(
      '找不到 GOOGLE_CALENDAR_ID。三选一：\n' +
        '  export GOOGLE_CALENDAR_ID=...\n' +
        '  echo ... > .local/calendar-id\n' +
        '  gh auth login（让这支自己去读 repo variable）',
    );
  }
}

async function main() {
  const config = readChurchConfig();
  if (!config.features.calendar) die('Calendar is disabled in church configuration.');
  const deploymentDir = process.env.CHURCH_DEPLOYMENT_DIR || path.join(ROOT, '.local/deployment');
  const { buildGoogleEvent, callCalendar } = await import(
    pathToFileURL(path.join(deploymentDir, 'worker/google_calendar.js')).href
  );
  const env = {
    CHURCH_CONFIG_JSON: JSON.stringify(config),
    GOOGLE_SERVICE_ACCOUNT_JSON: serviceAccountJson(),
    GOOGLE_CALENDAR_ID: calendarId(),
  };

  const account = JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_JSON).client_email;
  console.log(`service account : ${account}`);
  console.log(`calendar        : ${env.GOOGLE_CALENDAR_ID.slice(0, 12)}…`);
  console.log();

  let created;
  try {
    const response = await callCalendar(env, {
      method: 'POST',
      body: buildGoogleEvent({
        title: PROBE_TITLE,
        allDay: true,
        start: PROBE_DATE,
        description: '由 scripts/verify-calendar-writer.mjs 建立，应该会自动删除。',
      }),
    });
    created = await response.json();
  } catch (error) {
    console.error(`✗ 写入失败：${error.message}`);
    if (error.status === 502) {
      console.error();
      console.error('  最常见的原因是日历还没分享给 service account。');
      console.error('  Google 日历 → 该日历设定 → 与特定使用者或群组共用 →');
      console.error(`  加入 ${account}，权限选「变更活动」。`);
    }
    process.exit(1);
  }

  console.log(`✓ 新增成功  id=${created.id}`);

  try {
    const response = await callCalendar(env, { method: 'GET', eventId: created.id });
    const readBack = await response.json();
    if (readBack.summary !== PROBE_TITLE) {
      die(`读回来的标题对不上：${readBack.summary}`);
    }
    // end.date is exclusive, so a single-day event on the 31st ends on the 1st.
    if (readBack.start?.date !== PROBE_DATE) {
      die(`日期对不上：送出 ${PROBE_DATE}，读回 ${readBack.start?.date}`);
    }
    console.log(`✓ 读回确认  ${readBack.start.date} → ${readBack.end.date}（结束日不含当天，正确）`);
  } catch (error) {
    console.error(`✗ 读回失败：${error.message}`);
  }

  try {
    await callCalendar(env, { method: 'DELETE', eventId: created.id });
    console.log('✓ 删除成功');
  } catch (error) {
    console.error(`✗ 删除失败：${error.message}`);
    console.error(`  请手动删掉日历上的「${PROBE_TITLE}」（${PROBE_DATE}）`);
    process.exit(1);
  }

  console.log();
  console.log('全部通过 —— 新增、读取、删除都打得到真正的 Google Calendar。');
}

await main();
