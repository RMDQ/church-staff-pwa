"""这个资料夹里的脚本共用的 Firestore 读取工具。

底线开头代表「给 scripts/ 自己用」，不是可以独立跑的脚本。脚本用
`uv run scripts/x.py` 跑时 sys.path[0] 就是 scripts/，所以直接 `import
_firestore` 就找得到。

会抽出来是因为 build-import-prompt.py 与 preview-roster-import.py 各有一份
一模一样的 project_id / token / get，而 token 那段的双凭证退路是后来才补的 ——
补在一边忘了另一边，就会出现「一支跑得动、另一支叫你去 gcloud auth login」
这种查起来很烦的状况。
"""

import json
import os
import pathlib
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCAL = ROOT / ".local"

# Stable service IDs come from the deployment config, including disabled IDs.
from _church_config import CONFIG, TYPES


def project_id() -> str:
    """repo 是公开的，专案 id 不写死在版控里。"""
    value = os.environ.get("FIREBASE_PROJECT_ID", "").strip()
    if value:
        return value
    path = LOCAL / "project-id"
    if path.exists():
        return path.read_text().strip()
    sys.exit(
        "找不到 Firebase 专案 id。二选一：\n"
        "  export FIREBASE_PROJECT_ID=你的专案id\n"
        "  echo 你的专案id > .local/project-id"
    )


def base_url() -> str:
    return (
        f"https://firestore.googleapis.com/v1/projects/{project_id()}"
        "/databases/(default)/documents"
    )


def token() -> str:
    """拿一个读得到 Firestore 的 access token。

    使用者凭证会过期，而过期后 `gcloud auth print-access-token` 需要互动式重新
    登入 —— 在脚本里跑就直接死掉。所以拿不到时退回 application-default 凭证，
    那份通常还活著。两个都不行才叫使用者去登入。
    """
    for command in (
        ["gcloud", "auth", "print-access-token"],
        ["gcloud", "auth", "application-default", "print-access-token"],
    ):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0 and len(result.stdout.strip()) >= 50:
            return result.stdout.strip()
    sys.exit(
        "拿不到 access token，两种凭证都试过了。二选一：\n"
        "  gcloud auth login\n"
        "  gcloud auth application-default login"
    )


def get(base: str, path: str, tok: str) -> dict:
    request = urllib.request.Request(
        f"{base}/{path}", headers={"Authorization": f"Bearer {tok}"}
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def paged(base: str, path: str, tok: str) -> list[dict]:
    """把一个集合读完，跟著 nextPageToken 翻到底。"""
    docs, page = [], None
    while True:
        joiner = "&" if "?" in path else "?"
        suffix = f"{joiner}pageToken={page}" if page else ""
        data = get(base, f"{path}{suffix}", tok)
        docs.extend(data.get("documents", []))
        page = data.get("nextPageToken")
        if not page:
            break
    return docs
