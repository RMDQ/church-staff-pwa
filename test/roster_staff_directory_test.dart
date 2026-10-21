import 'package:flutter_test/flutter_test.dart';

import 'package:church_staff_pwa/core/types/service_type.dart';
import 'package:church_staff_pwa/features/auth/domain/entities/user.dart';
import 'package:church_staff_pwa/features/roster/domain/staff_directory.dart';

// 名字都是虚构的（repo 是公开的）。

User _user(
  String id,
  String name, {
  Map<ServiceType, List<String>> ministries = const {},
}) => User(
  id: id,
  name: name,
  email: '$id@example.com',
  username: id,
  role: UserRole.staff,
  zones: [
    for (final entry in ministries.entries)
      UserZoneInfo(serviceType: entry.key, ministries: entry.value),
  ],
);

void main() {
  group('StaffDirectory.fromUsers', () {
    final staff = StaffDirectory.fromUsers([
      _user(
        'u1',
        ' 林书安 ',
        ministries: {
          ServiceType.youth: ['敬拜', ' 司琴 '],
          ServiceType.children: ['教师'],
        },
      ),
      _user(
        'u2',
        '郭子谦',
        ministries: {
          ServiceType.youth: ['司琴'],
        },
      ),
      _user('u3', '   '),
    ], ServiceType.youth);

    test('名字 trim 过，空白名字不算', () {
      expect(staff.names, ['林书安', '郭子谦']);
      expect(staff.contains('林书安'), isTrue);
    });

    test('只看这个崇拜的服事设定', () {
      expect(staff.canServe('林书安', '司琴'), isTrue);
      expect(staff.canServe('林书安', '教师'), isFalse);
    });

    test('namesForRole 依名字排序', () {
      expect(staff.namesForRole('司琴'), ['林书安', '郭子谦']..sort());
      expect(staff.namesForRole('音控'), isEmpty);
    });

    test('同名同姓：不带 uid，也不猜是哪一位', () {
      final dup = StaffDirectory.fromUsers([
        _user('first', '林书安'),
        _user('second', '林书安'),
        _user('u2', '郭子谦'),
      ], ServiceType.youth);
      expect(dup.idOf('林书安'), isNull);
      expect(dup.idByName, {'郭子谦': 'u2'});
      expect(dup.resolve('林书安', '敬拜').status, NameMatchStatus.other);
      expect(dup.resolve('书安', '敬拜').status, NameMatchStatus.other);
    });

    test('idsOf 只回查得到 uid 的名字', () {
      expect(staff.idsOf(['林书安', '何宥廷']), {'林书安': 'u1'});
    });
  });

  group('StaffDirectory.resolve', () {
    final staff = StaffDirectory(
      names: const ['林书安', '郭子谦', '郭子安'],
      namesByRole: const {
        '敬拜': {'林书安'},
      },
    );

    test('空白与待定都是占位', () {
      expect(staff.resolve(' ', '敬拜').name, placeholderPerson);
      expect(
        staff.resolve(placeholderPerson, '敬拜').status,
        NameMatchStatus.matched,
      );
    });

    test('全名：有设定是 matched，没有是 roleMismatch', () {
      expect(staff.resolve('林书安', '敬拜').status, NameMatchStatus.matched);
      expect(staff.resolve('郭子谦', '敬拜').status, NameMatchStatus.roleMismatch);
    });

    test('唯一的字尾改写成全名', () {
      final result = staff.resolve('书安', '敬拜');
      expect(result.status, NameMatchStatus.matched);
      expect(result.name, '林书安');
    });

    test('字尾对到两位以上就不猜', () {
      // 「安」同时是林书安与郭子安的尾字。
      expect(staff.resolve('安', '敬拜').status, NameMatchStatus.other);
    });

    test('差一个字只给提示，名字不改', () {
      final result = staff.resolve('林书按', '敬拜');
      expect(result.status, NameMatchStatus.notInList);
      expect(result.name, '林书按');
      expect(result.suggestions, ['林书安']);
    });
  });
}
