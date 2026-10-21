import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_import_parser.dart';
import 'package:church_staff_pwa/features/roster/domain/staff_directory.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Build a minimal catalog from a list of (name, color) pairs.
Map<String, EventOption> _catalog(List<(String, int)> entries) {
  return {for (final e in entries) e.$1: EventOption(name: e.$1, color: e.$2)};
}

/// Run the parser with sensible defaults so tests only need to supply
/// the fields they care about.
RosterImportParseResult _parse(
  String json, {
  List<String> candidates = const [],
  Map<String, Set<String>> allowedByRole = const {},
  Map<String, EventOption> catalog = const {},
  Map<String, String> nameToId = const {},
}) {
  return parseRosterImportJson(
    input: json,
    staff: StaffDirectory(
      names: candidates,
      idByName: nameToId,
      namesByRole: allowedByRole,
    ),
    catalogByName: catalog,
  );
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // Basic / backward-compatible behaviour
  // ══════════════════════════════════════════════════════════════════════════

  group('duties-only (既有相容)', () {
    test(
      '1. happy path: only duties, no events key → dutiesProvidedDates contains date; eventsProvidedDates empty',
      () {
        const json = '''
[
  {
    "date": "2026-01-04",
    "duties": [{"role": "敬拜主领", "people": ["待定"]}]
  }
]''';
        final result = _parse(
          json,
          candidates: ['待定'],
          allowedByRole: {
            '敬拜主领': {'待定'},
          },
        );
        expect(result.error, isNull);
        expect(result.dutiesProvidedDates, contains('2026-01-04'));
        expect(result.eventsProvidedDates, isEmpty);
        expect(result.dutiesByDate['2026-01-04'], isNotEmpty);
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // events-only
  // ══════════════════════════════════════════════════════════════════════════

  group('events-only', () {
    test(
      '2. no duties key, events: ["圣餐"] → eventsProvidedDates contains date; dutiesProvidedDates empty',
      () {
        const json = '''
[
  {
    "date": "2026-01-04",
    "events": ["圣餐"]
  }
]''';
        final result = _parse(json);
        expect(result.error, isNull);
        expect(result.eventsProvidedDates, contains('2026-01-04'));
        expect(result.dutiesProvidedDates, isEmpty);
        expect(result.eventsByDate['2026-01-04'], equals(['圣餐']));
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Mixed duties + events
  // ══════════════════════════════════════════════════════════════════════════

  group('mixed duties + events', () {
    test('3. both keys → both providedDate sets contain the date', () {
      const json = '''
[
  {
    "date": "2026-01-11",
    "duties": [{"role": "司琴", "people": ["待定"]}],
    "events": ["圣餐"]
  }
]''';
      final result = _parse(
        json,
        candidates: ['待定'],
        allowedByRole: {
          '司琴': {'待定'},
        },
      );
      expect(result.error, isNull);
      expect(result.dutiesProvidedDates, contains('2026-01-11'));
      expect(result.eventsProvidedDates, contains('2026-01-11'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Color parsing
  // ══════════════════════════════════════════════════════════════════════════

  group('parseColor', () {
    test('4. hex 6-digit "#F39C12" → 0xFFF39C12', () {
      expect(parseColor('#F39C12'), equals(0xFFF39C12));
    });

    test('5. hex 8-digit "#FFE74C3C" → 0xFFE74C3C', () {
      expect(parseColor('#FFE74C3C'), equals(0xFFE74C3C));
    });

    test('6. int literal → returned unchanged', () {
      expect(parseColor(0xFFF39C12), equals(0xFFF39C12));
    });

    test('7. "0x" string "0xFFF39C12" → 0xFFF39C12', () {
      expect(parseColor('0xFFF39C12'), equals(0xFFF39C12));
    });

    test('8. named color "red" → null (parse failure)', () {
      expect(parseColor('red'), isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Color in events → error message
  // ══════════════════════════════════════════════════════════════════════════

  group('color error in events', () {
    test(
      '8b. invalid color in events element → error contains correct row/element',
      () {
        const json = '''
[
  {
    "date": "2026-01-04",
    "events": [{"name": "圣餐", "color": "red"}]
  }
]''';
        final result = _parse(json);
        expect(result.error, contains('第 1 笔 events 第 1 笔 color 格式错误'));
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Catalog miss / hit
  // ══════════════════════════════════════════════════════════════════════════

  group('event catalog', () {
    test('9. catalog miss → no error; notInEventCatalog contains the name', () {
      const json = '''
[
  {
    "date": "2026-01-04",
    "events": ["不存在的事件"]
  }
]''';
      final result = _parse(json, catalog: _catalog([]));
      expect(result.error, isNull);
      expect(result.notInEventCatalog, contains('不存在的事件'));
    });

    test(
      '10. catalog hit + JSON color override → colorsByDate[date][name] == parsed color',
      () {
        const json = '''
[
  {
    "date": "2026-01-04",
    "events": [{"name": "圣餐", "color": "#000000"}]
  }
]''';
        final result = _parse(json, catalog: _catalog([('圣餐', 0xFFAAAAAA)]));
        expect(result.error, isNull);
        expect(result.colorsByDate['2026-01-04']?['圣餐'], equals(0xFF000000));
      },
    );

    test(
      '11. catalog hit + no JSON color → colorsByDate[date] does NOT contain key',
      () {
        const json = '''
[
  {
    "date": "2026-01-04",
    "events": ["圣餐"]
  }
]''';
        final result = _parse(json, catalog: _catalog([('圣餐', 0xFFAAAAAA)]));
        expect(result.error, isNull);
        // No explicit color → key must be absent (UI reads from catalog)
        final colors = result.colorsByDate['2026-01-04'];
        expect(colors, isNotNull);
        expect(colors!.containsKey('圣餐'), isFalse);
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Explicit empty events array
  // ══════════════════════════════════════════════════════════════════════════

  group('explicit empty events array', () {
    test(
      '12. events: [] → eventsProvidedDates contains date; eventsByDate[date] == []; colorsByDate[date] == {}',
      () {
        const json = '[{"date": "2026-01-04", "events": []}]';
        final result = _parse(json);
        expect(result.error, isNull);
        expect(result.eventsProvidedDates, contains('2026-01-04'));
        expect(result.eventsByDate['2026-01-04'], equals([]));
        expect(result.colorsByDate['2026-01-04'], equals({}));
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // events key absent
  // ══════════════════════════════════════════════════════════════════════════

  group('events key absent', () {
    test(
      '13. no events key → eventsProvidedDates does NOT contain the date',
      () {
        const json = '''
[
  {
    "date": "2026-01-04",
    "duties": [{"role": "司琴", "people": ["待定"]}]
  }
]''';
        final result = _parse(
          json,
          candidates: ['待定'],
          allowedByRole: {
            '司琴': {'待定'},
          },
        );
        expect(result.error, isNull);
        expect(result.eventsProvidedDates, isNot(contains('2026-01-04')));
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Duplicate event name within day
  // ══════════════════════════════════════════════════════════════════════════

  group('duplicate event name', () {
    test('14. ["圣餐","圣餐"] → error contains 第 1 笔 events 名称重复：圣餐', () {
      const json = '[{"date": "2026-01-04", "events": ["圣餐", "圣餐"]}]';
      final result = _parse(json);
      expect(result.error, contains('第 1 笔 events 名称重复：圣餐'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // events not a list
  // ══════════════════════════════════════════════════════════════════════════

  group('events wrong type', () {
    test(
      '15. "events": "圣餐" (string not array) → error: 第 1 笔 events 格式错误',
      () {
        const json = '[{"date": "2026-01-04", "events": "圣餐"}]';
        final result = _parse(json);
        expect(result.error, equals('第 1 笔 events 格式错误'));
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // Extra cases
  // ══════════════════════════════════════════════════════════════════════════

  group('extra edge cases', () {
    test('object missing name key → error: 第 1 笔 events 第 1 笔缺少 name', () {
      const json = '[{"date": "2026-01-04", "events": [{"color": "#fff000"}]}]';
      final result = _parse(json);
      expect(result.error, contains('第 1 笔 events 第 1 笔缺少 name'));
    });

    test('trim: "  圣餐 " is treated as "圣餐"', () {
      const json = '[{"date": "2026-01-04", "events": ["  圣餐 "]}]';
      final result = _parse(json, catalog: _catalog([('圣餐', 0xFFAAAAAA)]));
      expect(result.error, isNull);
      expect(result.eventsByDate['2026-01-04'], equals(['圣餐']));
      // Should not appear as catalog miss since trimmed == catalog name
      expect(result.notInEventCatalog, isNot(contains('圣餐')));
    });

    test('duties and events both absent → 第 1 笔需至少包含 duties 或 events', () {
      const json = '[{"date": "2026-01-04"}]';
      final result = _parse(json);
      expect(result.error, equals('第 1 笔需至少包含 duties 或 events'));
    });

    test('empty input → 请贴上 JSON 内容', () {
      final result = _parse('   ');
      expect(result.error, equals('请贴上 JSON 内容'));
    });

    test('not a JSON array at top level → JSON 最外层需为阵列', () {
      final result = _parse('{"date":"2026-01-04","events":[]}');
      expect(result.error, equals('JSON 最外层需为阵列'));
    });

    test('duties key exists but not a List → 第 1 笔 duties 格式错误', () {
      const json = '[{"date":"2026-01-04","duties":"wrong"}]';
      final result = _parse(json);
      expect(result.error, equals('第 1 笔 duties 格式错误'));
    });

    test(
      'duties present with valid entry + events present → both dates tracked',
      () {
        const json = '''
[
  {
    "date": "2026-02-01",
    "duties": [{"role": "领会", "people": ["待定"]}],
    "events": ["圣餐", {"name": "受洗礼", "color": "#F39C12"}]
  }
]''';
        final result = _parse(
          json,
          candidates: ['待定'],
          allowedByRole: {
            '领会': {'待定'},
          },
          catalog: _catalog([('圣餐', 0xFF000001)]),
        );
        expect(result.error, isNull);
        expect(result.dutiesProvidedDates, contains('2026-02-01'));
        expect(result.eventsProvidedDates, contains('2026-02-01'));
        expect(result.eventsByDate['2026-02-01'], equals(['圣餐', '受洗礼']));
        // 受洗礼 had explicit color in JSON
        expect(result.colorsByDate['2026-02-01']?['受洗礼'], equals(0xFFF39C12));
        // 圣餐 had no explicit color → not in colorsByDate
        expect(result.colorsByDate['2026-02-01']?.containsKey('圣餐'), isFalse);
        // 受洗礼 not in catalog
        expect(result.notInEventCatalog, contains('受洗礼'));
        // 圣餐 IS in catalog
        expect(result.notInEventCatalog, isNot(contains('圣餐')));
      },
    );

    test('0x lowercase prefix also parsed correctly', () {
      expect(parseColor('0xfff39c12'), equals(0xFFF39C12));
    });

    test('parseColor: int out of range → null', () {
      expect(parseColor(0x1FFFFFFFF), isNull);
    });

    test('parseColor: empty string → null', () {
      expect(parseColor(''), isNull);
    });

    test('parseColor: "#" with wrong digit count → null', () {
      expect(parseColor('#FFF'), isNull);
      expect(parseColor('#FFFFF'), isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 没对到的名字一律照样汇入
  //
  // 以前这三种都是直接丢掉，那格变成「待定」，同一格还有别人时甚至完全没有
  // 痕迹。临时支援别的崇拜是正常状况，不该被当成脏资料删掉。
  // ══════════════════════════════════════════════════════════════════════════

  group('未匹配的名字照样汇入', () {
    const db = ['王大明', '李小华', '陈大明'];
    // 王大明 只被设定为司琴，没有招待。
    const allowed = {
      '司琴': {'王大明'},
      '招待': {'李小华'},
    };
    const ids = {'王大明': 'uid-daming', '李小华': 'uid-xiaohua'};

    RosterImportParseResult run(String people, {String role = '招待'}) => _parse(
      '[{"date":"2026-01-04","duties":[{"role":"$role","people":$people}]}]',
      candidates: db,
      allowedByRole: allowed,
      nameToId: ids,
    );

    RosterEntry dutyOf(RosterImportParseResult r) =>
        r.dutiesByDate['2026-01-04']!.single;

    test('没设定该服事的人照样排进去，uid 也留著', () {
      final r = run('["王大明"]');
      expect(dutyOf(r).people, ['王大明']);
      expect(
        dutyOf(r).personIdsByName['王大明'],
        'uid-daming',
        reason: '人是名单上的真人，uid 查得到就该带上，否则他在自己的首页看不到',
      );
      expect(r.roleMismatchNames, ['王大明'], reason: '照样汇入不等于不用报告');
      expect(r.roleMismatchDetails['王大明'], contains('招待'));
    });

    test('不在名单的人以纯文字排进去，但没有 uid', () {
      final r = run('["陈访客"]');
      expect(dutyOf(r).people, ['陈访客']);
      expect(dutyOf(r).personIdsByName, isEmpty);
      expect(r.notInRosterNames, ['陈访客']);
    });

    test('对到多个同名的人时保留原字串', () {
      // 「大明」同时是 王大明 与 陈大明 的结尾，系统无从判断。
      final r = run('["大明"]', role: '司琴');
      expect(dutyOf(r).people, ['大明']);
      expect(dutyOf(r).personIdsByName, isEmpty);
      expect(r.otherNames, ['大明']);
    });

    test('同一格混合时不会有人静静消失', () {
      // 这格最容易出事：以前画面只显示「李小华」，看起来完全正常，
      // 没有任何迹象显示少了一个人。
      final r = run('["李小华","王大明"]');
      expect(dutyOf(r).people, ['李小华', '王大明']);
      expect(dutyOf(r).personIdsByName, {
        '李小华': 'uid-xiaohua',
        '王大明': 'uid-daming',
      });
    });

    test('真的没填人时才会是待定', () {
      final r = run('[]');
      expect(dutyOf(r).people, ['待定']);
    });

    test('非字串的元素会停下来说明是哪一笔，不会被静静滤掉', () {
      // 以前 whereType<String>() 直接滤掉 null 与数字，既不写进表也不进报告
      // —— 墙上写两个人、app 显示一个，比 roleMismatch 更难察觉。
      expect(run('["李小华", null]').error, '第 1 笔 duties 第 1 笔 people 第 2 个不是文字');
      expect(
        run('["李小华", 12345]').error,
        '第 1 笔 duties 第 1 笔 people 第 2 个不是文字',
      );
    });

    test('空字串仍然略过（那不是名字）', () {
      final r = run('["李小华", "", "  "]');
      expect(r.error, isNull);
      expect(dutyOf(r).people, ['李小华']);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 形近字提示 — 名单里谁跟这个名字很像，只提示不套用
  //
  // 刻意不自动接回去。拿真实名单量过：名单内部互相拼错一个字时，唯一对到
  // 「别的真人」的次数是 0；而会落进这一层的几乎都是**还没建帐号的人**
  // （新同工、外来讲员），他们的名字常常跟某个真人只差一个字。自动接的话
  // 那个人的服事会被记到别人头上、连上别人的 uid，提醒发给错的人，原本那个
  // 名字还会从表上消失。改动这一层前先看这一组。
  // ══════════════════════════════════════════════════════════════════════════

  group('形近字提示', () {
    const db = ['陈志明', '黄雅婷', '林淑芸', '陈佳蓉', '李小华'];
    const allowed = {
      '司琴': {'陈志明', '黄雅婷', '林淑芸', '陈佳蓉', '李小华'},
    };
    const ids = {'陈志明': 'uid-ziqian', '李小华': 'uid-xiaohua'};

    RosterImportParseResult run(String people) => _parse(
      '[{"date":"2026-01-04","duties":[{"role":"司琴","people":$people}]}]',
      candidates: db,
      allowedByRole: allowed,
      nameToId: ids,
    );

    RosterEntry dutyOf(RosterImportParseResult r) =>
        r.dutiesByDate['2026-01-04']!.single;

    test('没建帐号的人不会被接到名单上那个很像的人身上', () {
      // 陈志豪还没有帐号，名单里有陈志明 —— 只差最后一个字。
      final r = run('["陈志豪"]');
      expect(dutyOf(r).people, ['陈志豪'], reason: '名字照表上原文写进去，不可以换成陈志明');
      expect(
        dutyOf(r).personIdsByName,
        isEmpty,
        reason: '带上陈志明的 uid 等于把服事记到他头上，提醒也发给他',
      );
      expect(r.notInRosterNames, ['陈志豪']);
      expect(r.nearMatchSuggestions, {
        '陈志豪': ['陈志明'],
      }, reason: '提示还是要给，管理者才知道可能是谁');
    });

    test('很像的有好几位就全部列出来，不挑', () {
      // 佳芸：跟「陈佳蓉」的梓吻合、跟「林淑芸」的妤吻合，两边都只差一个字。
      final r = run('["佳芸"]');
      expect(dutyOf(r).people, ['佳芸']);
      expect(r.nearMatchSuggestions['佳芸'], unorderedEquals(['陈佳蓉', '林淑芸']));
    });

    test('两个字的写法也给提示', () {
      // 「伃」在表上被写成「仔」。提示不会套用，所以吵一点无所谓，
      // 漏掉才可惜 —— 这种只能靠人看到之后加进绰号对照。
      final r = run('["雅亭"]');
      expect(dutyOf(r).people, ['雅亭']);
      expect(r.nearMatchSuggestions['雅亭'], ['黄雅婷']);
    });

    test('一个字不比对（会对上半本名单）', () {
      // 「扬」不是名单里任何人的结尾，所以前两层都不会接走。
      final r = run('["扬"]');
      expect(r.notInRosterNames, ['扬']);
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('差两个字不给提示', () {
      final r = run('["王小扬"]');
      expect(r.notInRosterNames, ['王小扬']);
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('长度不一样不给提示 —— 那是插入或删除，不是认错字', () {
      final r = run('["陈志明明"]');
      expect(r.notInRosterNames, ['陈志明明']);
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('名单里完全没有像的就不给提示，也不留空清单', () {
      final r = run('["阿宝"]');
      expect(r.notInRosterNames, ['阿宝']);
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('全等时不进提示，也不算对不到', () {
      final r = run('["陈志明"]');
      expect(dutyOf(r).people, ['陈志明']);
      expect(dutyOf(r).personIdsByName['陈志明'], 'uid-ziqian');
      expect(r.notInRosterNames, isEmpty);
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('后缀对得上时不进提示', () {
      final r = run('["小华"]');
      expect(dutyOf(r).people, ['李小华']);
      expect(dutyOf(r).personIdsByName['李小华'], 'uid-xiaohua');
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('「待定」不会被拿去比对', () {
      final r = run('["待定"]');
      expect(dutyOf(r).people, ['待定']);
      expect(r.nearMatchSuggestions, isEmpty);
    });

    test('同一格有人对得上、有人对不上时，两个都留著', () {
      final r = run('["李小华","陈志豪"]');
      expect(dutyOf(r).people, ['李小华', '陈志豪']);
      expect(dutyOf(r).personIdsByName, {'李小华': 'uid-xiaohua'});
      expect(r.nearMatchSuggestions['陈志豪'], ['陈志明']);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // orderDutiesByTemplate — 汇入后的排序规格
  //
  // 规格是「一律照样板排」，JSON 自己的顺序不算数。这一组就是这条规则的
  // 白纸黑字，改动排序逻辑前先看这里。
  // ══════════════════════════════════════════════════════════════════════════

  group('orderDutiesByTemplate（照样板排）', () {
    List<String> rolesOf(List<RosterEntry> duties) =>
        duties.map((d) => d.role).toList();

    List<RosterEntry> dutiesOf(List<String> roles) => [
      for (final role in roles) RosterEntry(role: role, people: const ['待定']),
    ];

    test('JSON 顺序不算数，一律照样板排', () {
      final sorted = orderDutiesByTemplate(dutiesOf(['领诗', '司琴', '主席']), const [
        '主席',
        '司琴',
        '领诗',
      ]);
      expect(rolesOf(sorted), ['主席', '司琴', '领诗']);
    });

    test('样板里没有的角色接在最后，彼此维持 JSON 的相对顺序', () {
      final sorted = orderDutiesByTemplate(
        dutiesOf(['音控', '司琴', '招待', '主席']),
        const ['主席', '司琴'],
      );
      expect(rolesOf(sorted), ['主席', '司琴', '音控', '招待']);
    });

    test('只排序，不会把样板有、JSON 没有的角色补进来', () {
      final sorted = orderDutiesByTemplate(dutiesOf(['司琴']), const [
        '主席',
        '司琴',
        '领诗',
      ]);
      expect(rolesOf(sorted), ['司琴']);
    });

    test('同一角色在 JSON 出现两次时维持原本的先后（sort 不保证稳定，要自己 tie-break）', () {
      // 用 people 分辨两笔同名角色谁先谁后。
      final duties = [
        RosterEntry(role: '司琴', people: const ['第一笔']),
        RosterEntry(role: '主席', people: const ['主席甲']),
        RosterEntry(role: '司琴', people: const ['第二笔']),
      ];
      final sorted = orderDutiesByTemplate(duties, const ['主席', '司琴']);
      expect(rolesOf(sorted), ['主席', '司琴', '司琴']);
      expect(sorted[1].people, ['第一笔']);
      expect(sorted[2].people, ['第二笔']);
    });

    test('项目数超过 32 时同名角色仍维持原顺序（这里才真的测到 tie-break）', () {
      // 上面那条三笔的测试其实咬不到 tie-break：Dart 的 List.sort 在 32 个
      // 元素以下走 insertion sort，本身就是稳定的。超过 32 才换成 dual-pivot
      // quicksort，同分元素的相对顺序这时才会被打乱。拿掉 tie-break 的话
      // 只有这一条会红。
      const count = 40;
      final duties = [
        for (var i = 0; i < count; i++)
          RosterEntry(role: i.isEven ? '司琴' : '主席', people: ['第$i笔']),
      ];

      final sorted = orderDutiesByTemplate(duties, const ['主席', '司琴']);

      expect(rolesOf(sorted).toSet(), {'主席', '司琴'});
      expect(sorted.take(count ~/ 2).map((d) => d.people.single), [
        for (var i = 1; i < count; i += 2) '第$i笔',
      ], reason: '主席应照原顺序排在前半');
      expect(sorted.skip(count ~/ 2).map((d) => d.people.single), [
        for (var i = 0; i < count; i += 2) '第$i笔',
      ], reason: '司琴应照原顺序排在后半');
    });

    test('角色全部都不在样板里时，整份维持 JSON 顺序', () {
      final sorted = orderDutiesByTemplate(dutiesOf(['音控', '招待']), const [
        '主席',
      ]);
      expect(rolesOf(sorted), ['音控', '招待']);
    });

    test('样板为空时退回 JSON 顺序 —— 呼叫端必须先挡掉这种情况', () {
      // 这条不是「期望的行为」，是把后果写下来：样板没载到就汇入会排出
      // JSON 顺序。roster_edit_screen 用 RosterProvider.templatesLoaded
      // 在进到这里之前就挡掉了。
      final sorted = orderDutiesByTemplate(
        dutiesOf(['领诗', '司琴']),
        const <String>[],
      );
      expect(rolesOf(sorted), ['领诗', '司琴']);
    });

    test('样板有重复角色时取第一次出现的位置', () {
      final sorted = orderDutiesByTemplate(dutiesOf(['司琴', '主席']), const [
        '司琴',
        '主席',
        '司琴',
      ]);
      expect(rolesOf(sorted), ['司琴', '主席']);
    });

    test('不会改动传进来的 list', () {
      final original = dutiesOf(['领诗', '主席']);
      orderDutiesByTemplate(original, const ['主席', '领诗']);
      expect(rolesOf(original), ['领诗', '主席']);
    });

    test('空输入不会炸', () {
      expect(orderDutiesByTemplate(const [], const ['主席']), isEmpty);
    });

    test('parser 保留 JSON 顺序，重排是后面那一层的事', () {
      // 两层的分工：parser 忠实反映 JSON，orderDutiesByTemplate 才决定显示
      // 顺序。parser 若自作主张排序，这里会红。
      const json = '''
[
  {
    "date": "2026-01-04",
    "duties": [
      {"role": "领诗", "people": ["王大明"]},
      {"role": "主席", "people": ["李小华"]}
    ]
  }
]
''';
      final result = _parse(
        json,
        candidates: const ['王大明', '李小华'],
        allowedByRole: const {
          '领诗': {'王大明'},
          '主席': {'李小华'},
        },
      );
      final parsed = result.dutiesByDate['2026-01-04']!;
      expect(rolesOf(parsed), ['领诗', '主席']);
      expect(rolesOf(orderDutiesByTemplate(parsed, const ['主席', '领诗'])), [
        '主席',
        '领诗',
      ]);
    });
  });

  group('外来讲员', () {
    // 名字一律照写进服事表；这里测的只是报告上归到哪一段。
    const json = '''
[
  {
    "date": "2026-11-22",
    "duties": [
      {"role": "信息", "people": ["周慕恩"]},
      {"role": "招待", "people": ["陈志明"]}
    ]
  },
  {
    "date": "2026-11-29",
    "duties": [
      {"role": "信息", "people": ["黄雅婷"]},
      {"role": "招待", "people": ["黄雅婷"]}
    ]
  },
  {
    "date": "2026-12-06",
    "duties": [{"role": "信息", "people": ["陈志豪"]}]
  }
]''';

    RosterImportParseResult parse() => _parse(
      json,
      candidates: ['陈志明', '林淑芸'],
      allowedByRole: {
        '招待': {'陈志明'},
      },
      nameToId: {'陈志明': 'u1', '林淑芸': 'u2'},
    );

    test('只排在信息、名单里没有也没有很像的人，归到外来讲员', () {
      final result = parse();
      expect(result.guestSpeakerNames, ['周慕恩']);
      expect(result.notInRosterNames, isNot(contains('周慕恩')));
    });

    test('名字照样写进那一格，只是没有 uid', () {
      final duty = parse().dutiesByDate['2026-11-22']!.firstWhere(
        (d) => d.role == '信息',
      );
      expect(duty.people, ['周慕恩']);
      expect(duty.personIdsByName, isEmpty);
    });

    test('也排了别的服事的，多半是还没开帐号的同工，留在警告里', () {
      final result = parse();
      expect(result.notInRosterNames, contains('黄雅婷'));
      expect(result.guestSpeakerNames, isNot(contains('黄雅婷')));
    });

    test('名单里有很像的，多半是同工的名字被读错一个字，留在警告里', () {
      final result = parse();
      expect(result.nearMatchSuggestions['陈志豪'], ['陈志明']);
      expect(result.notInRosterNames, contains('陈志豪'));
      expect(result.guestSpeakerNames, isNot(contains('陈志豪')));
    });

    test('信息写「总部连线」这种不是人名的，也照外来讲员处理', () {
      final result = _parse(
        '[{"date": "2026-12-13", "duties": [{"role": "信息", "people": ["总部连线"]}]}]',
        candidates: ['陈志明', '林淑芸'],
        nameToId: {'陈志明': 'u1', '林淑芸': 'u2'},
      );
      expect(result.guestSpeakerNames, ['总部连线']);
      expect(result.notInRosterNames, isEmpty);
      expect(result.dutiesByDate['2026-12-13']!.single.people, ['总部连线']);
    });
  });

  group('带自己日期的一次性活动', () {
    test('认得出名称后面带的日期', () {
      expect(isDatedOneOffEvent('感恩聚餐（12/26 六）'), isTrue);
      expect(isDatedOneOffEvent('感恩聚餐(12/26六)'), isTrue);
      expect(isDatedOneOffEvent('孩童奉献礼'), isFalse);
      // 名称里本来就有斜线的不算（合并格的「活动/地点」）。
      expect(isDatedOneOffEvent('夏令营/营地'), isFalse);
    });

    test('不列进「活动没有固定颜色」，但照样写进那天', () {
      // 名字每次都不同，加进活动清单也永远对不上下一次。
      const json = '''
[
  {"date": "2026-12-27", "events": ["感恩聚餐（12/26 六）", "孩童奉献礼"]}
]''';
      final result = _parse(json);
      expect(result.notInEventCatalog, ['孩童奉献礼']);
      expect(result.eventsByDate['2026-12-27'], ['感恩聚餐（12/26 六）', '孩童奉献礼']);
    });
  });

  group('pickEventColor', () {
    test('空的清单从色盘第一个开始', () {
      expect(pickEventColor(const []), eventColorPalette.first);
    });

    test('挑目前用得最少的，连续加的几个彼此分得开', () {
      final existing = [
        EventOption(name: '圣餐', color: eventColorPalette[0]),
        EventOption(name: '爱餐', color: eventColorPalette[1]),
      ];
      expect(pickEventColor(existing), eventColorPalette[2]);
    });

    test('全部都用过一轮时，回到用得最少的那一个', () {
      final existing = [
        for (final color in eventColorPalette)
          EventOption(name: '$color', color: color),
        EventOption(name: '再一个', color: eventColorPalette[0]),
      ];
      expect(pickEventColor(existing), eventColorPalette[1]);
    });

    test('色盘没有灰色：那是「没设颜色」的颜色', () {
      expect(eventColorPalette, isNot(contains(fallbackEventColor)));
    });

    test('色盘外的颜色（手动设的旧资料）不影响挑选', () {
      final existing = [const EventOption(name: '旧的', color: 0xFF000000)];
      expect(pickEventColor(existing), eventColorPalette.first);
    });
  });
}
