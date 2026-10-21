#!/usr/bin/env python3
"""打包一个可以上传到 claude.ai 的独立技能。

用途：人不在这台电脑前（例如只有手机）时，照样能把服事表照片转成汇入用的
JSON。上传一次，之后在 claude.ai 附上照片说「转 json」就好。

跟本机的 /roster-import 技能的差别：
  - 本机版会做干式汇入（呼叫 app 真正的 parser 验一次）
  - 这个版本没有那步 —— claude.ai 上没有 repo 也没有 Firestore。
    规则全部写死在技能里，错了要等 app 的汇入结果视窗才会知道。

用法：
    uv run scripts/build-claude-skill.py

产物在 .local/claude-skill/（已 gitignore）：
    roster-import/SKILL.md
    roster-import.zip      ← 上传这个

⚠ 产物内含同工姓名。上传等于把名单送到 claude.ai，是否可接受请自行判断。
"""

import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCAL = ROOT / ".local"
OUT = LOCAL / "claude-skill"
from _church_config import CONFIG, TYPES

FRONTMATTER = """---
name: roster-import
description: 把教会服事表的照片转成可以汇入服事表 app 的 JSON。使用者附上服事表照片、或说「服事表转 json」「这张表帮我转」时使用。
---

# 服事表照片转汇入 JSON

## 第一步：判断是哪一个崇拜

照片标题通常写得出来（例如「青年崇拜服事表」「儿童主日学服事表」）。
判断不出来就**问使用者**，不要猜；不同聚会的服事项目可能不一样。

对应到下面的章节：

| 标题出现 | 用哪一节 |
|---|---|
{{SERVICE_TABLE}}

## 第二步：照那一节的规则转

只输出 JSON，不要任何说明文字，不要用程式码围栏包起来。
使用者要的是可以直接复制贴进 app 的东西。

## 第三步：转完提醒一句

转完之后用一句话说明：哪些名字你不太确定、哪些日期可能不在 app 的范围内
（app 只有本季与下季的服事表）。使用者汇入后 app 也会再报一次。

---
"""


def main() -> None:
    # 先把各聚会最新的 prompt 产生出来（会从 Firestore 抓现况）。
    build = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build-import-prompt.py")],
        cwd=ROOT,
    )
    if build.returncode != 0:
        sys.exit("build-import-prompt.py 失败，先把那支修好")

    sections = []
    for service_type, label in TYPES.items():
        path = LOCAL / f"roster-import-prompt.{service_type}.md"
        if not path.exists():
            print(f"⚠ 找不到 {path.name}，跳过 {label}")
            continue
        body = path.read_text().strip()
        # 每一节的标题降一级，避免跟技能本身的 H1/H2 打架。
        body = re.sub(r"^## ", "### ", body, flags=re.M)
        sections.append(f"## {label}\n\n{body}\n")

    if not sections:
        sys.exit("一份 prompt 都没有，中止")

    skill_dir = OUT / "roster-import"
    if OUT.exists():
        shutil.rmtree(OUT)
    skill_dir.mkdir(parents=True)
    service_table = "\n".join(
        f"| {service['name']}、{service['label']} | {service['label']} |"
        for service in CONFIG["services"]
    )
    (skill_dir / "SKILL.md").write_text(
        FRONTMATTER.replace("{{SERVICE_TABLE}}", service_table) + "\n".join(sections)
    )

    archive = shutil.make_archive(str(OUT / "roster-import"), "zip", OUT, "roster-import")
    size = pathlib.Path(archive).stat().st_size

    print()
    print(f"技能已产生：{skill_dir.relative_to(ROOT)}/SKILL.md")
    print(f"上传这个：  {pathlib.Path(archive).relative_to(ROOT)}（{size // 1024} KB）")
    print()
    print("⚠ 内含同工姓名。上传等于把名单送到 claude.ai。")
    print("   名单有异动时重跑这支，再上传一次覆盖。")


if __name__ == "__main__":
    main()
