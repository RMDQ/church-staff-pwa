#!/usr/bin/env node
// Scheduled fetch of the configured devotional source into the data branch.
// The adapters live in worker/devotional.js so the site's same-day fallback
// accepts exactly the same sources.
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { validateChurchConfig } from '../worker/church_config.js';
import { fetchDailyVerse } from '../worker/devotional.js';

export { fetchDailyVerse, parseDailyBibleHtml, validateDailyVerse } from '../worker/devotional.js';

export function devotionalFetchSettings(rawConfig) {
  if (!rawConfig?.trim()) return { enabled: false };
  const config = validateChurchConfig(JSON.parse(rawConfig));
  return {
    enabled: config.devotional.enabled && Boolean(config.devotional.fetchUrl),
    url: config.devotional.fetchUrl ?? '',
    format: config.devotional.fetchFormat ?? 'json',
    timeZone: config.timeZone,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.env.NODE_TLS_REJECT_UNAUTHORIZED === '0') throw new Error('不允许停用 TLS 验证。');
    const [output, ...extra] = process.argv.slice(2);
    if (!output || extra.length || (output.startsWith('--') && output !== '--check-config')) {
      throw new Error('Usage: CHURCH_CONFIG_JSON=<public-config-json> node scripts/fetch-daily-verse.mjs OUTPUT.json|--check-config');
    }
    const settings = devotionalFetchSettings(process.env.CHURCH_CONFIG_JSON);
    if (output === '--check-config') {
      console.log(`enabled=${settings.enabled}`);
    } else if (!settings.enabled) {
      console.log('未启用灵粮抓取或 fetchUrl 为空；没有网路请求，也未写档。');
    } else {
      const data = await fetchDailyVerse(settings.url, { timeZone: settings.timeZone, format: settings.format });
      writeFileSync(output, `${JSON.stringify(data, null, 2)}\n`);
      console.log(`已验证灵粮来源；日期 ${data.date}。内容与再散布授权仍须部署者确认。`);
    }
  } catch (error) {
    // URL 可能含 feed 的 access token，避免直接印出 fetch 的错误或 payload。
    console.error(error instanceof SyntaxError ? '设定或来源不是有效 JSON；只有明确选择 dailyBibleHtml 才会使用专用 HTML adapter。' : error.message);
    process.exitCode = 1;
  }
}
