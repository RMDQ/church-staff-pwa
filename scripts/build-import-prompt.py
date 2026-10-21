#!/usr/bin/env python3
"""从 Firestore 现况产生服事表汇入用的 prompt。

repo 是公开的，所以同工姓名一律不进版控：模板在
docs/roster-import-prompt.template.md，产生的成品写到 .local/（已 gitignore）。

用法：
    uv run scripts/build-import-prompt.py            # 所有设定的聚会都产生
    uv run scripts/build-import-prompt.py youth      # 只产生青崇
    uv run scripts/build-import-prompt.py --publish  # 顺便发布到 Firestore

需要环境变数 FIREBASE_PROJECT_ID，或 .local/project-id 这个档。

没有 --publish 就只读 Firestore，产物写到 .local/。

--publish 会把**模板**写进 settings/import_prompts，那是 app 内建的「照片直接
汇入」在用的 —— functions/api/roster/import-image.js 从那里读。

发布的是模板不是完成品：服事项目、活动、同工名单、今天这几个留成 {{...}}，
由 worker 每次呼叫时从 Firestore 现况填。所以**新同工建完帐号就直接生效，
不必重跑这支**。只有改了版面规则、栏名对照、绰号或模板本文才要重新发布。

各教会自己的规则（例如「会前祷+奉献拆两项」、敬拜团展开方式、绰号对照）
放在 .local/import-rules.json，格式见模板文件末段。
"""

import datetime
from zoneinfo import ZoneInfo
import json
import pathlib
import sys
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

# worker 每次呼叫才填的栏位。跟 worker/roster_prompt.js 的 fillPrompt 一致 ——
# 两边对不上的话，prompt 会带著 {{NAMES}} 这种字面值送出去。
LIVE_FIELDS = ("ROLES", "EVENTS", "NAMES", "TODAY", "SAMPLE_ROLE_A", "SAMPLE_ROLE_B")

# 名单一行放几个人，以及活动清单空的时候写什么。这两个值 worker 也各有一份 ——
# 对不上的话，本机验过的 prompt 跟线上送出去的就不是同一份，而且没有东西会
# 叫。functions-tests/prompt_parity.test.js 把两边钉在一起。
NAMES_PER_LINE = 6
NO_EVENTS = "（尚未设定）"

from _firestore import LOCAL, ROOT, TYPES, base_url, get, project_id, token  # noqa: F401
from _church_config import CONFIG

TEMPLATE = ROOT / "docs" / "roster-import-prompt.template.md"


def fetch_names(base: str, tok: str) -> list[str]:
    names, page = [], None
    while True:
        suffix = f"&pageToken={page}" if page else ""
        data = get(base, f"users?pageSize=300{suffix}", tok)
        for doc in data.get("documents", []):
            name = doc.get("fields", {}).get("name", {}).get("stringValue", "").strip()
            if name:
                names.append(name)
        page = data.get("nextPageToken")
        if not page:
            break
    return sorted(set(names))


def fill_live(template: str, *, roles: list[str], events: list[str], names: list[str]) -> str:
    """填上「活的」那几个栏位。

    这支只给本机预览用。正式流程是 worker 的 fillPrompt 做同一件事，资料直接
    从 Firestore 现况读 —— 所以新同工建完帐号就生效，不必有人回来重跑。
    两边的输出要长得一样，否则本机验过的跟线上跑的不是同一份 prompt。
    """
    return (
        template.replace("{{ROLES}}", "、".join(roles))
        .replace("{{EVENTS}}", "、".join(events) if events else NO_EVENTS)
        .replace(
            "{{NAMES}}",
            "\n".join(
                "  " + "、".join(names[i : i + NAMES_PER_LINE])
                for i in range(0, len(names), NAMES_PER_LINE)
            ),
        )
        # 有些表的标题根本不写年份（儿主那张就是），模型只能猜。给它今天，
        # 让它挑离今天最近的那个年份 —— 猜错年份整份都汇不进去。
        .replace("{{TODAY}}", datetime.datetime.now(ZoneInfo(CONFIG["timeZone"])).date().isoformat())
        .replace("{{SAMPLE_ROLE_A}}", roles[0])
        .replace("{{SAMPLE_ROLE_B}}", roles[1] if len(roles) > 1 else roles[0])
    )


def publish(base: str, tok: str, prompts: dict[str, str]) -> None:
    """把产生好的 prompt 写进 settings/import_prompts。

    只送这一轮真的产生出来的那几个崇拜（updateMask），所以
    `build-import-prompt.py youth --publish` 不会把另外两个洗掉。
    """
    # 设定允许 ID 带连字号；Firestore field path 要引用才能维持单一顶层键。
    # IDs 已通过 ChurchConfig 验证，不含反引号或反斜线。
    mask = urllib.parse.urlencode(
        [("updateMask.fieldPaths", f"`{t}`") for t in prompts]
    )
    payload = json.dumps(
        {"fields": {t: {"stringValue": body} for t, body in prompts.items()}}
    ).encode()
    request = urllib.request.Request(
        f"{base}/settings/import_prompts?{mask}",
        data=payload,
        method="PATCH",
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            json.load(response)
    except urllib.error.HTTPError as e:
        sys.exit(
            f"发布失败（HTTP {e.code}）。这个帐号要有写入 settings/ 的权限。\n"
            + e.read().decode(errors="replace")[:600]
        )
    print(f"\n已发布到 settings/import_prompts：{'、'.join(TYPES[t] for t in prompts)}")
    print("app 的「照片直接汇入」现在用的就是这一份。")


def main() -> None:
    args = sys.argv[1:]
    should_publish = "--publish" in args
    wanted = [a for a in args if a != "--publish"] or list(TYPES)
    for t in wanted:
        if t not in TYPES:
            sys.exit(f"未知的崇拜类别「{t}」，可用：{', '.join(TYPES)}")

    base = (
        f"https://firestore.googleapis.com/v1/projects/{project_id()}"
        "/databases/(default)/documents"
    )
    tok = token()

    names = fetch_names(base, tok)
    if not names:
        sys.exit("users 读回来是空的，中止")

    templates = get(base, "settings/roster_templates", tok).get("fields", {})
    options = get(base, "settings/event_options", tok).get("fields", {})
    rules_path = LOCAL / "import-rules.json"
    rules = json.loads(rules_path.read_text()) if rules_path.exists() else {}

    # 只撷取模板本文那段（```` 围起来的第一个区块）。
    body = re.search(r"^````\n(.*?)^````$", TEMPLATE.read_text(), re.S | re.M)
    if not body:
        sys.exit("模板里找不到 ```` 围起来的本文区块")
    body = body.group(1)

    # 去姓后撞名 → app 会判成「不确定是哪一位」，那格不会连到任何帐号。
    from collections import Counter

    given = Counter(n[1:] for n in names if len(n) > 1)
    clashes = {g: [n for n in names if n[1:] == g] for g, c in given.items() if c > 1}

    LOCAL.mkdir(exist_ok=True)
    published: dict[str, str] = {}
    for service_type in wanted:
        roles = [
            v["stringValue"]
            for v in templates.get(service_type, {})
            .get("arrayValue", {})
            .get("values", [])
        ]
        events = [
            v["mapValue"]["fields"]["name"]["stringValue"]
            for v in options.get(service_type, {})
            .get("arrayValue", {})
            .get("values", [])
        ]
        if not roles:
            print(f"⚠ {TYPES[service_type]} 在 roster_templates 里没有服事项目，跳过")
            continue

        rule = rules.get(service_type, {})
        nicknames = rule.get("nicknames", {})
        nickname_block = ""
        if nicknames:
            lines = "\n".join(f"{k} → {v}" for k, v in nicknames.items())
            nickname_block = (
                "\n### 绰号对照\n\n表上这些写法对不到名单，只能查表：\n\n"
                + lines
                + "\n"
            )

        team = rule.get("teamRules", "")
        # 版面规则是三个崇拜差最多的地方（主日整张是转置的），没写的话这一段
        # 就空著 —— 模板本文刻意不再假设「一列一天」。
        layout = rule.get("layoutRules", "")
        # ── 两类栏位 ──────────────────────────────────────────────────────
        # 「写的」：版面规则、栏名对照、绰号、敬拜团 —— 有人去改
        # .local/import-rules.json 才会变，发布时就填好。
        #
        # 「活的」：服事项目、活动、同工名单、今天 —— 随时会变，**故意留成
        # {{...}}** 交给 worker 每次呼叫时填。烤进去的话，新同工建完帐号还要
        # 有人记得回来重跑这支，而没人会记得。
        template = (
            body.replace("{{LAYOUT_RULES}}", f"\n{layout}\n" if layout else "")
            .replace("{{EXTRA_ROLE_RULES}}", rule.get("extraRoleRules", ""))
            .replace("{{NICKNAMES}}", nickname_block)
            .replace("{{TEAM_RULES}}", f"\n{team}\n" if team else "")
        )
        remaining = set(re.findall(r"\{\{([A-Z_]+)\}\}", template))
        if remaining != set(LIVE_FIELDS):
            sys.exit(
                "模板剩下的栏位跟 worker 会填的对不上。\n"
                f"  模板里有：{sorted(remaining)}\n"
                f"  worker 填：{sorted(LIVE_FIELDS)}\n"
                "改了模板的话，worker/roster_prompt.js 的 fillPrompt 要一起改。"
            )

        filled = fill_live(template, roles=roles, events=events, names=names)
        left = re.findall(r"\{\{[A-Z_]+\}\}", filled)
        if left:
            sys.exit(f"填完还有剩下的栏位：{sorted(set(left))}")

        out = LOCAL / f"roster-import-prompt.{service_type}.md"
        # 本机这份是填好的，给 try-gemini-import.py 与肉眼看用。
        out.write_text(filled)
        # 发布出去的是**模板**，不是上面那份。
        published[service_type] = template
        note = "" if layout else "，⚠ 没有 layoutRules"
        print(
            f"{TYPES[service_type]}：{out.relative_to(ROOT)}"
            f"（{len(names)} 人、{len(roles)} 个服事项目{note}）"
        )

    if should_publish and published:
        publish(base, tok, published)

    if clashes:
        print("\n⚠ 去掉姓氏后会撞名，这几位汇入时可能对不到帐号：")
        for given_name, full in clashes.items():
            print(f"    {given_name} → {full}")


if __name__ == "__main__":
    main()
