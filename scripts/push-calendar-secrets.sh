#!/usr/bin/env bash
#
# 把行事历写入需要的执行期变数推到 Cloudflare Pages。
#
# 为什么要有这支：GOOGLE_SERVICE_ACCOUNT_JSON 是一整份多行 JSON，贴进
# dashboard 的输入框很容易漏字或被改成单行，而失败的样子是部署后才发现
# 「伺服器设定不完整」。用 CLI 从档案直接送就没有这个问题。
#
# 这三个是 **执行期** 变数（Pages Functions 读的），跟 build 阶段的
# --dart-define 是两套，要分开设。
#
# 用法：
#     wrangler login          # 只有第一次，或 token 过期时
#     bash scripts/push-calendar-secrets.sh
#
# 需要 .local/service-account.json（已 gitignore）。
#
# LINE 通知（选用）：另读 .local/n8n-notify-url 与 .local/n8n-notify-secret。
# Wrangler Pages secret put 只支援 Production，没有 --env。
# Preview 必须另用 Cloudflare Dashboard 或 REST API 设定，避免测试通知发到正式群组。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${CLOUDFLARE_PAGES_PROJECT:?Set CLOUDFLARE_PAGES_PROJECT to your own Pages project}"
KEY_FILE="$ROOT/.local/service-account.json"

WRANGLER=(npx --yes wrangler@4)

if [[ ! -f "$KEY_FILE" ]]; then
  echo "找不到 $KEY_FILE" >&2
  echo "先产生 service account 金钥再跑这支。" >&2
  exit 1
fi

# Firebase 专案 id 决定 Function 去哪个 Firestore 查管理员身分。读错专案的话
# 每个人都会被判成没有权限。
firebase_project_id() {
  if [[ -n "${FIREBASE_PROJECT_ID:-}" ]]; then
    printf '%s' "$FIREBASE_PROJECT_ID"
  elif [[ -f "$ROOT/.local/project-id" ]]; then
    tr -d '[:space:]' < "$ROOT/.local/project-id"
  else
    gh variable get FIREBASE_PROJECT_ID --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  fi
}

calendar_id() {
  if [[ -n "${GOOGLE_CALENDAR_ID:-}" ]]; then
    printf '%s' "$GOOGLE_CALENDAR_ID"
  elif [[ -f "$ROOT/.local/calendar-id" ]]; then
    tr -d '[:space:]' < "$ROOT/.local/calendar-id"
  else
    gh variable get GOOGLE_CALENDAR_ID --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  fi
}

PROJECT_ID="$(firebase_project_id)"
CALENDAR_ID="$(calendar_id)"

if [[ -z "$PROJECT_ID" || -z "$CALENDAR_ID" ]]; then
  echo "拿不到 FIREBASE_PROJECT_ID 或 GOOGLE_CALENDAR_ID。" >&2
  echo "用环境变数指定，或先跑 gh auth login。" >&2
  exit 1
fi

# Production only; Wrangler does not expose a Pages preview flag.
for environment in production; do
  echo "── $environment ──"

  # 全部走 secret：值不会回显在 dashboard 或 wrangler 的输出里，而 Function
  # 读的方式完全相同。
  "${WRANGLER[@]}" pages secret put GOOGLE_SERVICE_ACCOUNT_JSON \
    --project-name "$PROJECT_NAME" < "$KEY_FILE"

  printf '%s' "$PROJECT_ID" | "${WRANGLER[@]}" pages secret put FIREBASE_PROJECT_ID \
    --project-name "$PROJECT_NAME"

  printf '%s' "$CALENDAR_ID" | "${WRANGLER[@]}" pages secret put GOOGLE_CALENDAR_ID \
    --project-name "$PROJECT_NAME"
done

# ── LINE 通知（选用）────────────────────────────────────────────────────────
# 两个档案都在才推。缺一个就整个跳过：Function 那边也是任一没设就关掉通知，
# 只推一半只会得到「设了却不会动」这种最难查的状态。
notify_url() {
  if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
    printf '%s' "$NOTIFY_WEBHOOK_URL"
  elif [[ -f "$ROOT/.local/n8n-notify-url" ]]; then
    tr -d '[:space:]' < "$ROOT/.local/n8n-notify-url"
  fi
}

notify_secret() {
  if [[ -n "${NOTIFY_WEBHOOK_SECRET:-}" ]]; then
    printf '%s' "$NOTIFY_WEBHOOK_SECRET"
  elif [[ -f "$ROOT/.local/n8n-notify-secret" ]]; then
    tr -d '[:space:]' < "$ROOT/.local/n8n-notify-secret"
  fi
}

NOTIFY_URL="$(notify_url)"
NOTIFY_SECRET="$(notify_secret)"

echo
if [[ -n "$NOTIFY_URL" && -n "$NOTIFY_SECRET" ]]; then
  for environment in production; do
    echo "── LINE 通知：$environment ──"
    printf '%s' "$NOTIFY_URL" | "${WRANGLER[@]}" pages secret put NOTIFY_WEBHOOK_URL \
      --project-name "$PROJECT_NAME"
    printf '%s' "$NOTIFY_SECRET" | "${WRANGLER[@]}" pages secret put NOTIFY_WEBHOOK_SECRET \
      --project-name "$PROJECT_NAME"
  done
else
  echo "略过 LINE 通知：找不到 .local/n8n-notify-url 或 .local/n8n-notify-secret。"
fi

echo
echo "完成。下一次部署才会生效 —— 现有的 deployment 不会自动带到新设定。"
