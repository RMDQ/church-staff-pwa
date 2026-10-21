// 事件新增成功后通知 n8n，由 n8n 发 LINE 群组讯息。
//
// 为什么不在这里直接打 LINE Messaging API：channel access token 和讯息排版
// 都已经在 n8n 里（那边还有一条「LINE 群组讯息 → 建事件 → 回复」的流程）。
// 从这里再接一次 LINE，等于把同一段排版逻辑养在两个系统，改一边忘了另一边
// 是迟早的事。这里只负责把「发生了什么」讲清楚，长什么样交给 n8n。
//
// 只有新增会通知。编辑和删除没接，是因为目前群组只想知道有新聚集；真要加的话
// 编辑可以照抄下面的用法（PATCH 的回应就是完整事件），删除则要在删掉之前先
// GET 一次才拿得到标题 —— Google 的 DELETE 回 204 空 body。

/// 通知是附带效果，不该让使用者为它多等。比对外的 Google 呼叫更短。
import { churchConfig } from './church_config.js';

const NOTIFY_TIMEOUT_MS = 5000;

/// 把 Google 的 event resource 摊平成 n8n 好处理的形状。
///
/// n8n 那端不必知道 Google 用 `date` 表示全天、用 `dateTime` 表示定时，也不必
/// 知道 `end.date` 是排他的。那些差异在这里一次弭平。
///
/// [actor] 是 authorize() 回传值里的 `{ uid, name }`。两个都送：群组里要看的是
/// 名字，但名字会改、也可能重复，事后要追是谁做的还是得靠 uid。
export function notifyPayload(action, event, actor, timeZone = churchConfig().timeZone) {
  const allDay = Boolean(event?.start?.date);
  return {
    action,
    source: 'pwa',
    timeZone,
    id: event?.id ?? null,
    title: event?.summary ?? null,
    allDay,
    start: event?.start?.dateTime ?? event?.start?.date ?? null,
    end: allDay
      ? inclusiveEndDate(event?.end?.date)
      : (event?.end?.dateTime ?? null),
    location: event?.location ?? '',
    description: event?.description ?? '',
    link: event?.htmlLink ?? null,
    actorUid: actor?.uid ?? null,
    // 旧资料可能没有 name 栏位，所以这里可能是 null —— n8n 那端要能少这一行。
    actorName: actor?.name ?? null,
  };
}

/// Google 的 `end.date` 是排他的：8/20 的单日活动存进去是 end.date=8/21。
/// buildGoogleEvent() 进去时加了一天，出来给人看要减回来，否则群组收到的讯息
/// 会晚一天。
function inclusiveEndDate(date) {
  if (typeof date !== 'string') return null;
  const stamp = Date.parse(`${date}T00:00:00Z`);
  if (Number.isNaN(stamp)) return null;
  return new Date(stamp - 86400000).toISOString().slice(0, 10);
}

/// 送出通知。失败只会留在 log 里，不会往外抛。
///
/// 呼叫到这里时事件已经写进 Google 了。LINE 发不出去是件该修的事，但不是使用者
/// 的操作失败 —— 让它变成 500 只会让人以为活动没建成，然后再按一次。
///
/// 两个环境变数任一没设就整个关掉：本机 `wrangler pages dev` 和 Preview 部署
/// 因此不会把测试资料推进真的群组。
export async function notifyN8n(env, payload, fetchImpl = fetch) {
  if (!churchConfig(env).features.lineNotifications) return;
  const url = env?.NOTIFY_WEBHOOK_URL;
  const secret = env?.NOTIFY_WEBHOOK_SECRET;
  if (!url || !secret) return;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), NOTIFY_TIMEOUT_MS);
  try {
    const response = await fetchImpl(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        // n8n Webhook node 的 Header Auth 凭证，名称要跟这里一致。
        'x-notify-secret': secret,
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    if (!response.ok) {
      console.error('n8n notify rejected', response.status);
    }
  } catch (error) {
    console.error('n8n notify failed', error);
  } finally {
    clearTimeout(timer);
  }
}

/// 把通知丢进背景，让回应先回给使用者。
///
/// `waitUntil` 由 Pages 执行期提供，但单元测试是直接呼叫 handler 的，那里没有。
/// 没有就退回「就地等完」—— 慢一点，但不会因为缺一个 context 栏位就整支炸掉。
export function scheduleNotify(waitUntil, promise) {
  if (typeof waitUntil === 'function') {
    waitUntil(promise);
    return;
  }
  return promise;
}
