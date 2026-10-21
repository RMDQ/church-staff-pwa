import 'package:flutter/material.dart';

import '../../../core/utils/error_messages.dart';
import 'providers/roster_provider.dart';

/// 写入失败时给人看的一句话。
///
/// [RosterProvider] 的写入失败一律往上丢（见 [RosterProvider.updateRoster]），
/// 由各个画面就地显示。收在这里是为了让每个画面的讲法一致 —— 尤其是「部分
/// 失败」：那不是「失败」，有几天已经写进去了，照一般失败讲会让人以为全部
/// 都要重来。
///
/// [action] 是动词（「更新」「删除」「储存」）。[partialNote] 只接在部分失败
/// 后面，给那个画面自己知道的补充（例如「设定本身已储存」）。
String writeFailureMessage(String action, Object error, {String? partialNote}) {
  if (error is PartialUpdateException) {
    return [
      '有 ${error.failureCount} 天的服事表没有$action成功，'
          '其余 ${error.successCount} 天已完成',
      ?partialNote,
    ].join('。');
  }
  return '$action失败：${mapErrorToUserMessage(error)}';
}

/// 把 [writeFailureMessage] 用 snackbar 显示出来。
///
/// 收 [ScaffoldMessengerState] 而不是 BuildContext：呼叫端都是在 await 之后
/// 才知道失败，那时 context 可能已经不在树上了，要在 await 之前先拿好。
void showWriteFailure(
  ScaffoldMessengerState messenger,
  String action,
  Object error, {
  String? partialNote,
}) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        writeFailureMessage(action, error, partialNote: partialNote),
      ),
    ),
  );
}
