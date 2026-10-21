#!/usr/bin/env python3
"""拿真实资料对一份汇入 JSON 做干式汇入，事先看到 app 会回报什么。

不重写比对逻辑 —— 从 Firestore 抓现况之后，产生一支暂时的 Dart 测试去呼叫
app 真正在用的 parseRosterImportJson 与 orderDutiesByTemplate，所以这里看到
的结果就是按下汇入会看到的结果。

用法：
    uv run scripts/preview-roster-import.py youth roster.json
    uv run scripts/preview-roster-import.py sundayService roster.json
    uv run scripts/preview-roster-import.py children roster.json

只读 Firestore，不写入任何东西，也不会碰服事表。
"""

import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from _church_config import CONFIG
import pathlib
import re
import subprocess
import sys
import urllib.request

from _firestore import ROOT, TYPES, base_url, get as _get, paged as _paged, token  # noqa: F401

BASE = base_url()


def get(path: str, tok: str) -> dict:
    return _get(BASE, path, tok)


def paged(path: str, tok: str) -> list[dict]:
    return _paged(BASE, path, tok)


def dart_literal(value) -> str:
    """把 Python 资料转成 Dart 字面值。JSON 字串跟 Dart 字串语法够接近，
    但单引号与 $ 要跳脱（Dart 的字串内插用 $）。"""
    if isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$")
        return f"'{escaped}'"
    if isinstance(value, list):
        return "[" + ", ".join(dart_literal(v) for v in value) + "]"
    if isinstance(value, set):
        return "{" + ", ".join(dart_literal(v) for v in sorted(value)) + "}"
    if isinstance(value, dict):
        return (
            "{"
            + ", ".join(f"{dart_literal(k)}: {dart_literal(v)}" for k, v in value.items())
            + "}"
        )
    raise TypeError(type(value))


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in TYPES:
        sys.exit(__doc__)
    service_type, json_path = sys.argv[1], pathlib.Path(sys.argv[2])
    if not json_path.exists():
        sys.exit(f"找不到 {json_path}")

    raw = json_path.read_text()
    try:
        rows = json.loads(raw)
    except json.JSONDecodeError as e:
        sys.exit(f"这份 JSON 本身就解析不了：{e}")
    if not isinstance(rows, list):
        sys.exit("最外层必须是阵列")

    tok = token()

    # ── 名单与「谁能做哪个服事」──────────────────────────────────────────
    users = paged("users?pageSize=300", tok)
    candidate_names, name_to_id, allowed = [], {}, {}
    for doc in users:
        fields = doc.get("fields", {})
        name = fields.get("name", {}).get("stringValue", "").strip()
        if not name:
            continue
        candidate_names.append(name)
        uid = doc["name"].split("/")[-1].strip()
        if uid:
            name_to_id[name] = uid
        for zone in fields.get("zones", {}).get("arrayValue", {}).get("values", []):
            zf = zone.get("mapValue", {}).get("fields", {})
            if zf.get("serviceType", {}).get("stringValue") != service_type:
                continue
            for m in zf.get("ministries", {}).get("arrayValue", {}).get("values", []):
                role = m.get("stringValue", "").strip()
                if role:
                    allowed.setdefault(role, set()).add(name)

    # ── 服事项目样板与活动选单 ────────────────────────────────────────────
    templates = get("settings/roster_templates", tok).get("fields", {})
    template_roles = [
        v["stringValue"]
        for v in templates.get(service_type, {}).get("arrayValue", {}).get("values", [])
    ]
    options = get("settings/event_options", tok).get("fields", {})
    catalog = [
        v["mapValue"]["fields"]["name"]["stringValue"]
        for v in options.get(service_type, {}).get("arrayValue", {}).get("values", [])
    ]

    # ── app 看得到的服事表日期（决定哪几天汇不进去）──────────────────────
    #
    # 光看 Firestore 有没有那份文件是不够的：app 只载入
    # 「今天 ~ 下一季末」这个区间（firestore_roster_repository 的
    # _filterAndSortRosters），过去的文件还在资料库里但汇入时看不到，
    # 一样会被算成「这几天没有汇入」。这里照同一个区间过滤。
    church_zone = ZoneInfo(CONFIG["timeZone"])
    today = datetime.now(church_zone).date()
    quarter_start_month = ((today.month - 1) // 3) * 3 + 1
    is_last_month = today.month == quarter_start_month + 2
    raw_end_month = quarter_start_month + (5 if is_last_month else 2)
    end_year = today.year + (raw_end_month - 1) // 12
    end_month = (raw_end_month - 1) % 12 + 1
    window_end = date(end_year + end_month // 12, end_month % 12 + 1, 1) - timedelta(days=1)

    existing = set()
    for d in paged("rosters?pageSize=300", tok):
        doc_id = d["name"].split("/")[-1]
        fields = d.get("fields", {})
        if fields.get("type", {}).get("stringValue") != service_type:
            continue
        key = fields.get("dateKey", {}).get("stringValue")
        legacy = re.fullmatch(r"(\d{4})(\d{2})(\d{2})_" + re.escape(service_type), doc_id)
        if key:
            when = date.fromisoformat(key)
        elif legacy:
            when = date(*(int(part) for part in legacy.groups()))
        else:
            stamp = fields.get("date", {}).get("timestampValue")
            if not stamp:
                continue
            when = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone(church_zone).date()
        if today <= when <= window_end:
            existing.add(when.isoformat())

    # ── 产生一支暂时的 Dart 测试，呼叫真正的 parser ──────────────────────
    test_path = ROOT / "test" / "zz_import_preview_test.dart"
    test_path.write_text(
        f"""// 由 scripts/preview-roster-import.py 产生，跑完会自动删掉。
import 'package:flutter_test/flutter_test.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_import_parser.dart';
import 'package:church_staff_pwa/features/roster/domain/staff_directory.dart';

void main() {{
  test('preview', () {{
    const input = r\"\"\"{raw}\"\"\";
    final result = parseRosterImportJson(
      input: input,
      staff: StaffDirectory(
        names: {dart_literal(candidate_names)},
        idByName: {dart_literal(name_to_id)},
        namesByRole: {dart_literal({k: v for k, v in allowed.items()})},
      ),
      catalogByName: {{
        for (final name in {dart_literal(catalog)})
          name: EventOption(name: name, color: 0),
      }},
    );
    if (result.error != null) {{
      print('OUT|error|${{result.error}}');
      return;
    }}
    for (final n in result.notInRosterNames) {{ print('OUT|notInList|$n'); }}
    for (final e in result.roleMismatchDetails.entries) {{
      print('OUT|roleMismatch|${{e.key}}|${{e.value.join('、')}}');
    }}
    for (final n in result.otherNames) {{ print('OUT|ambiguous|$n'); }}
    for (final e in result.nearMatchSuggestions.entries) {{
      print('OUT|nearMatch|${{e.key}}|${{e.value.join('、')}}');
    }}
    for (final n in result.notInEventCatalog) {{ print('OUT|noColor|$n'); }}
    for (final d in result.dutiesProvidedDates) {{ print('OUT|dutiesDate|$d'); }}
    for (final d in result.eventsProvidedDates) {{ print('OUT|eventsDate|$d'); }}
    // 排序后的样子，确认每天的项目顺序
    for (final e in result.dutiesByDate.entries) {{
      final ordered = orderDutiesByTemplate(e.value, {dart_literal(template_roles)});
      print('OUT|order|${{e.key}}|${{ordered.map((d) => d.role).join(' > ')}}');
    }}
  }});
}}
"""
    )
    try:
        run = subprocess.run(
            ["flutter", "test", str(test_path)],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
    finally:
        test_path.unlink(missing_ok=True)

    lines = [
        m.group(1)
        for m in re.finditer(r"OUT\|(.*)", run.stdout.replace("\r", "\n"))
    ]
    if not lines:
        sys.exit(
            "parser 没有跑起来，flutter test 的输出：\n"
            + (run.stdout[-3000:] or run.stderr[-3000:])
        )

    buckets: dict[str, list[str]] = {}
    for line in lines:
        kind, _, rest = line.partition("|")
        buckets.setdefault(kind, []).append(rest)

    if "error" in buckets:
        print(f"✗ 整份会被挡下来：{buckets['error'][0]}")
        sys.exit(1)

    dates = sorted(set(buckets.get("dutiesDate", []) + buckets.get("eventsDate", [])))
    missing = [
        d for d in dates if d not in existing
    ]

    print(f"=== 干式汇入：{TYPES[service_type]} / {json_path.name} ===")
    print(f"共 {len(dates)} 天，其中 {len(dates) - len(missing)} 天汇得进去")

    def section(title: str, items: list[str], note: str = "") -> None:
        if not items:
            return
        print(f"\n{title}{'  ' + note if note else ''}")
        for item in items:
            print(f"  ・{item}")

    section(
        "名单里有很像的",
        [r.replace("|", " ≈ ") for r in buckets.get("nearMatch", [])],
        "（只是提示，名字照原文写进去，没有自动换）",
    )
    section("这几天没有汇入", missing, "（服事表里没有这些日期）")
    section(
        "没有设定这个服事",
        [r.replace("|", "：") for r in buckets.get("roleMismatch", [])],
        "（会照样排进去）",
    )
    section("名单里没有这个人", buckets.get("notInList", []), "（会照样排进去，但收不到提醒）")
    section("不确定是哪一位", buckets.get("ambiguous", []), "（没有对到帐号）")
    section("活动没有固定颜色", buckets.get("noColor", []))

    if not any(
        buckets.get(k)
        for k in ("roleMismatch", "notInList", "ambiguous", "nearMatch", "noColor")
    ) and not missing:
        print("\n✓ 全部对得上，汇入后不会有任何未匹配")

    print("\n--- 排序后每天的服事项目 ---")
    for entry in sorted(buckets.get("order", [])):
        day, _, roles = entry.partition("|")
        print(f"  {day}  {roles}")


if __name__ == "__main__":
    main()
