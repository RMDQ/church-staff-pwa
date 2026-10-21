#!/usr/bin/env python3
"""把服事表照片丢给 Gemini，产生汇入用的 JSON，并接上干式汇入验一次。

这支是 app 内建「照片直接汇入」之前的试水温版本：同一套 prompt、同一份
Firestore 现况、同一个 parser，只是跑在本机而不是 Cloudflare Function。
先用它确认 Gemini 读不读得懂那几张表，值得再搬进 worker。

用法：
    uv run scripts/try-gemini-import.py youth 服事表.jpg
    uv run scripts/try-gemini-import.py youth 上半.jpg 下半.jpg --preview
    uv run scripts/try-gemini-import.py --list-models

    --preview   转完直接接 scripts/preview-roster-import.py 做干式汇入
    --model X   换一个模型（预设见 DEFAULT_MODEL，或用 GEMINI_MODEL 环境变数）

API key 二选一，**不要打在命令列上**（会进 shell 纪录）：
    export GEMINI_API_KEY=...
    echo ... > .local/gemini-api-key

⚠ 送出去的内容包含同工姓名（prompt 里的白名单）与整张服事表。AI Studio 的
  免费层，Google 会用送进去的资料改善产品；付费层不会。是否可接受请自行
  判断 —— 这跟 build-claude-skill.py 上传名单到 claude.ai 是同一个判断题。

产物都在 .local/（已 gitignore）。
"""

import argparse
import base64
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCAL = ROOT / ".local"
from _church_config import CONFIG, TYPES

# 模型名称会改版，所以留得下来覆写。跑 --list-models 看现在有哪些。
#
# 不用 `gemini-flash-latest` 这种别名：别名指到当红那一支，最容易 503。
# 钉版本也让同一张图转两次结果一致。
DEFAULT_MODEL = "gemini-3.6-flash"
# v1，不是 v1beta —— 新的模型在 v1beta 上会回一个 0 byte 的 404，
# 看起来像模型不存在，其实是走错版本。
API_BASE = "https://generativelanguage.googleapis.com/v1"

# Gemini 的 inline data 是整包塞进请求里的，太大会被挡。超过这个大小先自己
# 缩图，不要让它跑到一半才失败。
MAX_IMAGE_BYTES = 7 * 1024 * 1024

# 503（尖峰）与 429（额度）都是等一下就好的，免费层碰到是常态。
RETRY_CODES = {429, 503}
RETRY_DELAYS = (5, 15, 40)

MIME_BY_SUFFIX = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".heic": "image/heic",
    ".heif": "image/heif",
}


def api_key() -> str:
    value = os.environ.get("GEMINI_API_KEY", "").strip()
    if value:
        return value
    path = LOCAL / "gemini-api-key"
    if path.exists():
        value = path.read_text().strip()
        if value:
            return value
    sys.exit(
        "找不到 Gemini API key。到 https://aistudio.google.com/apikey 拿一个，然后二选一：\n"
        "  export GEMINI_API_KEY=...\n"
        "  echo ... > .local/gemini-api-key"
    )


def call_api(path: str, key: str, body: dict | None = None) -> dict:
    """打 Gemini API。

    key 走 `X-goog-api-key` header，不走 query string —— query string 会进
    代理与伺服器的存取日志，header 不会。
    """
    url = f"{API_BASE}/{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"X-goog-api-key": key}
    if data:
        headers["Content-Type"] = "application/json"

    for attempt, delay in enumerate((*RETRY_DELAYS, None)):
        request = urllib.request.Request(url, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:1200]
            if e.code in RETRY_CODES and delay is not None:
                print(f"  HTTP {e.code}，{delay} 秒后重试（第 {attempt + 1} 次）…")
                time.sleep(delay)
                continue
            hint = ""
            if e.code == 404:
                hint = "\n模型名称可能已经改版，跑 --list-models 看现在有哪些。"
            elif e.code == 429:
                hint = "\n额度用完了，等久一点再试。"
            elif e.code == 503:
                hint = "\n模型在尖峰，重试几次都不行就换 --model 或晚点再跑。"
            elif e.code in (400, 403):
                hint = "\nkey 不对、或这个 key 没开 Generative Language API。"
            sys.exit(f"Gemini 回 HTTP {e.code}{hint}\n{detail}")
    raise AssertionError("unreachable")


def list_models(key: str) -> None:
    data = call_api("models?pageSize=200", key)
    for model in data.get("models", []):
        name = model.get("name", "").removeprefix("models/")
        methods = model.get("supportedGenerationMethods", [])
        if "generateContent" not in methods:
            continue
        print(f"  {name}\t{model.get('displayName', '')}")


def build_prompt(service_type: str) -> str:
    """呼叫既有的 build-import-prompt.py，读它产生的成品。

    prompt 的组法刻意不在这里重写一份 —— 那支是唯一的来源，两边各有一份
    早晚会不一样，而不一样的那天不会有人发现。
    """
    script = ROOT / "scripts" / "build-import-prompt.py"
    result = subprocess.run(
        [sys.executable, str(script), service_type],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if result.returncode != 0:
        sys.exit(f"产生 prompt 失败：\n{result.stdout}{result.stderr}")
    path = LOCAL / f"roster-import-prompt.{service_type}.md"
    if not path.exists():
        sys.exit(f"build-import-prompt.py 跑完了，但没看到 {path.relative_to(ROOT)}")
    print(result.stdout.strip())
    return path.read_text()


def image_part(path: pathlib.Path) -> dict:
    if not path.exists():
        sys.exit(f"找不到图档：{path}")
    mime = MIME_BY_SUFFIX.get(path.suffix.lower())
    if not mime:
        sys.exit(
            f"不支援的图档格式：{path.suffix}"
            f"（可用：{'、'.join(sorted(MIME_BY_SUFFIX))}）"
        )
    raw = path.read_bytes()
    if len(raw) > MAX_IMAGE_BYTES:
        sys.exit(
            f"{path.name} 有 {len(raw) / 1024 / 1024:.1f}MB，超过 "
            f"{MAX_IMAGE_BYTES // 1024 // 1024}MB。先缩一下，例如：\n"
            f"  magick {path} -resize 2000x {path.stem}-small.jpg"
        )
    return {"inline_data": {"mime_type": mime, "data": base64.b64encode(raw).decode()}}


def extract_json(text: str) -> str:
    """prompt 要求不要围栏，但模型偶尔还是会加。宽容一点，不要为这个重跑一次。"""
    stripped = text.strip()
    fenced = re.match(r"^```(?:json)?\s*\n(.*?)\n```$", stripped, re.S)
    if fenced:
        return fenced.group(1).strip()
    return stripped


def main() -> None:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("service_type", nargs="?", help=f"崇拜类别：{', '.join(TYPES)}")
    parser.add_argument("images", nargs="*", help="服事表照片，可以给多张")
    parser.add_argument("--model", default=os.environ.get("GEMINI_MODEL", DEFAULT_MODEL))
    parser.add_argument("--preview", action="store_true", help="转完接干式汇入")
    parser.add_argument("--list-models", action="store_true")
    args = parser.parse_args()

    key = api_key()

    if args.list_models:
        list_models(key)
        return

    if not args.service_type or not args.images:
        parser.error("要给崇拜类别与至少一张照片。用法见档案开头的 docstring。")
    if args.service_type not in TYPES:
        parser.error(f"未知的崇拜类别「{args.service_type}」，可用：{', '.join(TYPES)}")

    prompt = build_prompt(args.service_type)
    parts = [{"text": prompt}] + [
        image_part(pathlib.Path(p)) for p in args.images
    ]

    print(f"\n送 {len(args.images)} 张图给 {args.model} …")
    response = call_api(
        f"models/{args.model}:generateContent",
        key,
        {
            "contents": [{"parts": parts}],
            "generationConfig": {
                # 服事表转 JSON 没有「创意」的空间，同一张图每次都该转出同一份。
                "temperature": 0,
                # 直接叫它吐 JSON，省掉围栏与前后废话。
                "responseMimeType": "application/json",
            },
        },
    )

    candidates = response.get("candidates") or []
    if not candidates:
        # 被安全过滤掉、或整份被挡下来时走这里。原文印出来才查得下去。
        sys.exit(f"Gemini 没有回任何结果：\n{json.dumps(response, ensure_ascii=False)[:1200]}")
    candidate = candidates[0]
    text = "".join(
        part.get("text", "") for part in candidate.get("content", {}).get("parts", [])
    )
    if not text.strip():
        reason = candidate.get("finishReason", "（没说原因）")
        sys.exit(f"Gemini 回了空的内容，finishReason={reason}")

    payload = extract_json(text)
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError as e:
        out = LOCAL / f"roster-import.{args.service_type}.raw.txt"
        out.write_text(text)
        sys.exit(f"回来的不是合法 JSON（{e}）。原文留在 {out.relative_to(ROOT)}")

    LOCAL.mkdir(exist_ok=True)
    out = LOCAL / f"roster-import.{args.service_type}.json"
    out.write_text(json.dumps(parsed, ensure_ascii=False, indent=2) + "\n")

    days = len(parsed) if isinstance(parsed, list) else "?"
    usage = response.get("usageMetadata", {})
    print(f"✓ {days} 天 → {out.relative_to(ROOT)}")
    if usage:
        print(
            f"  token：输入 {usage.get('promptTokenCount', '?')}、"
            f"输出 {usage.get('candidatesTokenCount', '?')}"
        )

    if args.preview:
        print()
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "preview-roster-import.py"),
                args.service_type,
                str(out),
            ],
            cwd=ROOT,
        )
    else:
        print(
            f"\n干式汇入看一下对不对：\n"
            f"  uv run scripts/preview-roster-import.py {args.service_type} "
            f"{out.relative_to(ROOT)}"
        )


if __name__ == "__main__":
    main()
