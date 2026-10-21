import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/event_option.dart';
import 'package:church_staff_pwa/features/roster/domain/entities/service_roster.dart';
import 'package:church_staff_pwa/features/roster/domain/roster_import.dart';

// 名字都是虚构的（repo 是公开的）。

const _type = ServiceType.youth;

User _user(String id, String name, List<String> ministries) => User(
  id: id,
  name: name,
  email: '$id@example.com',
  username: id,
  role: UserRole.staff,
  zones: [UserZoneInfo(serviceType: _type, ministries: ministries)],
);

ServiceRoster _roster(
  String date, {
  List<RosterEntry> duties = const [],
  List<String> events = const [],
  Map<String, int> colors = const {},
}) => ServiceRoster(
  id: 'r-$date',
  date: DateTime.parse(date),
  type: _type,
  serviceName: '青崇',
  duties: duties,
  specialEvents: events,
  customEventColors: colors,
);

final _users = [
  _user('u1', '林书安', ['敬拜', '司琴']),
  _user('u2', '郭子谦', ['司琴']),
];

RosterImportPlan _plan(
  Object json, {
  List<ServiceRoster>? rosters,
  Map<ServiceType, List<String>>? templates,
  bool templatesLoaded = true,
  List<EventOption> eventOptions = const [],
}) => planRosterImport(
  input: jsonEncode(json),
  type: _type,
  users: _users,
  rosters: rosters ?? [_roster('2026-10-03')],
  templates: templatesLoaded
      ? templates ??
            {
              _type: ['司琴', '敬拜'],
            }
      : null,
  eventOptions: eventOptions,
);

RosterImportReady _ready(RosterImportPlan plan) {
  if (plan is RosterImportReady) return plan;
  fail('被挡下了：${(plan as RosterImportRejected).message}');
}

String _rejection(RosterImportPlan plan) {
  if (plan is RosterImportRejected) return plan.message;
  fail('应该被挡下');
}

void main() {
  group('挡下整份汇入', () {
    test('JSON 坏掉时直接回解析错误，不去对服事表', () {
      expect(
        _rejection(
          planRosterImport(
            input: '{',
            type: _type,
            users: _users,
            rosters: const [],
            templates: {},
            eventOptions: const [],
          ),
        ),
        'JSON 格式错误',
      );
    });

    test('样板还没载入时，带 duties 的汇入不能进行', () {
      final message = _rejection(
        _plan([
          {
            'date': '2026-10-03',
            'duties': [
              {
                'role': '敬拜',
                'people': ['林书安'],
              },
            ],
          },
        ], templatesLoaded: false),
      );
      expect(message, contains('尚未载入'));
    });

    test('这个崇拜没有样板时挡下，并说要找管理员', () {
      final message = _rejection(
        _plan(
          [
            {
              'date': '2026-10-03',
              'duties': [
                {
                  'role': '敬拜',
                  'people': ['林书安'],
                },
              ],
            },
          ],
          templates: {
            ServiceType.children: ['司琴'],
          },
        ),
      );
      expect(message, contains(_type.label));
      expect(message, contains('请管理员'));
    });

    test('只带 events 的汇入不需要样板', () {
      final plan = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'events': ['圣餐'],
          },
        ], templatesLoaded: false),
      );
      expect(plan.updates.single.specialEvents, ['圣餐']);
    });
  });

  group('对到现有服事表', () {
    test('服事照样板排序，名字换成全名并带上 uid', () {
      final plan = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'duties': [
              {
                'role': '敬拜',
                'people': ['书安'],
              },
              {
                'role': '司琴',
                'people': ['郭子谦'],
              },
            ],
          },
        ]),
      );
      final duties = plan.updates.single.duties;
      expect(duties.map((d) => d.role), ['司琴', '敬拜']);
      expect(duties[1].people, ['林书安']);
      expect(duties[1].personIdsByName, {'林书安': 'u1'});
    });

    test('找不到的日期列进 missingDates，不写', () {
      final plan = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'events': ['圣餐'],
          },
          {
            'date': '2026-10-10',
            'events': ['圣餐'],
          },
        ]),
      );
      expect(plan.updates.map((r) => r.id), ['r-2026-10-03']);
      expect(plan.summary.missingDates, ['2026-10-10']);
      expect(plan.summary.updated, 1);
    });

    test('只带 duties 的那天，活动与颜色原样保留', () {
      final existing = _roster(
        '2026-10-03',
        events: ['洗礼'],
        colors: {'洗礼': 0xFF123456},
      );
      final plan = _ready(
        _plan(
          [
            {
              'date': '2026-10-03',
              'duties': [
                {
                  'role': '敬拜',
                  'people': ['林书安'],
                },
              ],
            },
          ],
          rosters: [existing],
        ),
      );
      final updated = plan.updates.single;
      expect(updated.specialEvents, ['洗礼']);
      expect(updated.customEventColors, {'洗礼': 0xFF123456});
    });

    test('只带 events 的那天，服事原样保留；活动与颜色整批换掉', () {
      final duty = RosterEntry(role: '敬拜', people: const ['林书安']);
      final existing = _roster(
        '2026-10-03',
        duties: [duty],
        events: ['洗礼'],
        colors: {'洗礼': 0xFF123456},
      );
      final plan = _ready(
        _plan(
          [
            {
              'date': '2026-10-03',
              'events': ['圣餐'],
            },
          ],
          rosters: [existing],
        ),
      );
      final updated = plan.updates.single;
      expect(updated.duties, [duty]);
      expect(updated.specialEvents, ['圣餐']);
      expect(updated.customEventColors, isEmpty);
    });
  });

  group('报告', () {
    test('排到没设定的服事：每个人都在 details 里，服事排序过', () {
      final plan = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'duties': [
              {
                'role': '敬拜',
                'people': ['郭子谦'],
              },
              {
                'role': '音控',
                'people': ['郭子谦'],
              },
            ],
          },
        ]),
      );
      expect(plan.summary.roleMismatchDetails, {
        '郭子谦': ['敬拜', '音控'],
      });
    });

    test('名单上没有的人照写进服事表，也列进报告', () {
      final plan = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'duties': [
              {
                'role': '敬拜',
                'people': ['何宥廷'],
              },
            ],
          },
        ]),
      );
      expect(plan.updates.single.duties.single.people, ['何宥廷']);
      expect(plan.summary.notInRosterNames, ['何宥廷']);
      expect(plan.summary.hasIssues, isTrue);
    });

    test('活动清单里没有的活动列进 notInEventCatalog', () {
      final plan = _ready(
        _plan(
          [
            {
              'date': '2026-10-03',
              'events': ['圣餐', '感恩聚餐'],
            },
          ],
          eventOptions: const [EventOption(name: '圣餐', color: 0xFFAAAAAA)],
        ),
      );
      expect(plan.summary.notInEventCatalog, ['感恩聚餐']);
    });
  });

  test('外来讲员列进报告，但不算问题', () {
    final plan = _ready(
      _plan(
        [
          {
            'date': '2026-10-03',
            'duties': [
              {
                'role': '信息',
                'people': ['温以诺'],
              },
            ],
          },
        ],
        templates: {
          _type: ['信息'],
        },
      ),
    );
    expect(plan.updates.single.duties.single.people, ['温以诺']);
    expect(plan.summary.guestSpeakerNames, ['温以诺']);
    expect(plan.summary.notInRosterNames, isEmpty);
    expect(plan.summary.hasIssues, isFalse);
  });

  test('app 里只有 roster_import.dart 直接用 parser', () {
    // 直接呼叫 parseRosterImportJson 会绕过样板检查、依日期合并与报告 ——
    // 以前这段编排写在画面里，bug 都出在那里。
    final offenders = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            !file.path.endsWith('roster_import.dart') &&
            !file.path.endsWith('roster_import_parser.dart') &&
            file.readAsStringSync().contains('roster_import_parser.dart'))
          file.path,
    ];
    expect(offenders, isEmpty);
  });

  group('同工排序', () {
    test('照图片上的先后学，只带活动的日期不算', () {
      final ready = _ready(
        _plan(
          [
            {
              'date': '2026-10-03',
              'duties': [
                {
                  'role': '司琴',
                  'people': ['郭子谦', '林书安'],
                },
              ],
            },
            // 只带活动：那天的服事还是旧的（林书安在前），不能拿来学。
            {
              'date': '2026-10-10',
              'events': ['圣餐'],
            },
          ],
          rosters: [
            _roster('2026-10-03'),
            _roster(
              '2026-10-10',
              duties: [
                RosterEntry(role: '司琴', people: ['林书安', '郭子谦']),
              ],
            ),
          ],
        ),
      );
      expect(ready.staffOrder.rankingOf('司琴'), ['郭子谦', '林书安']);
    });

    test('名单外的人不进排序', () {
      final ready = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'duties': [
              {
                'role': '司琴',
                'people': ['外请甲', '郭子谦', '林书安'],
              },
            ],
          },
        ]),
      );
      expect(ready.staffOrder.rankingOf('司琴'), ['郭子谦', '林书安']);
    });

    test('只带活动的汇入没有东西可学', () {
      final ready = _ready(
        _plan([
          {
            'date': '2026-10-03',
            'events': ['圣餐'],
          },
        ]),
      );
      expect(ready.staffOrder.isEmpty, isTrue);
    });
  });

  test('rosterDateKey 补零', () {
    expect(rosterDateKey(DateTime(2026, 1, 4)), '2026-01-04');
  });
}
