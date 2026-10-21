import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/services/install_hint_service.dart';

/// 提醒还在浏览器里用的同工把网站加到手机主画面。
///
/// 没加的话每次都要找那则 LINE 讯息、关掉分页常常就登出了，同工只会觉得
/// 「这个 App 很难用」。按「不用了」之后这台装置就不再提醒。
class AddToHomeCard extends StatefulWidget {
  const AddToHomeCard({super.key, this.service = const InstallHintService()});

  final InstallHintService service;

  static const dismissedKey = 'add_to_home_dismissed';

  @override
  State<AddToHomeCard> createState() => _AddToHomeCardState();
}

class _AddToHomeCardState extends State<AddToHomeCard> {
  // 读到 SharedPreferences 之前先不显示，以免已经按过「不用了」的人看到闪一下。
  bool _dismissed = true;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _dismissed = prefs.getBool(AddToHomeCard.dismissedKey) ?? false,
    );
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AddToHomeCard.dismissedKey, true);
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    final accepted = await widget.service.prompt();
    if (!mounted) return;
    setState(() {
      _installing = false;
      // 装好了就不用再提醒；按了取消就留著卡片，说明文字还是有用。
      if (accepted) _dismissed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.service.read();
    if (_dismissed || !hint.shouldSuggest) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final canInstall =
        hint.platform == InstallPlatform.android && hint.canPrompt;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.add_to_home_screen,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '把这个网站加到手机桌面',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('桌面会多一个图示，之后点一下就能打开，不用再去 LINE 找连结。'),
              const SizedBox(height: 12),
              if (canInstall)
                const Text('按下面的「安装到手机」，再按「安装」就好了。')
              else
                ..._steps(hint, theme),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _dismiss, child: const Text('不用了')),
                  if (canInstall) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _installing ? null : _install,
                      child: const Text('安装到手机'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 照着点就会的步骤。图示直接画出来，因为「分享钮」是哪一个很多人不知道。
  List<Widget> _steps(InstallHint hint, ThemeData theme) {
    WidgetSpan icon(IconData data) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Icon(data, size: 20, color: theme.colorScheme.primary),
    );
    final share = icon(Icons.ios_share);
    final List<List<InlineSpan>> steps = switch (hint.platform) {
      InstallPlatform.ios => [
        switch (hint.browser) {
          InstallBrowser.chrome => [
            const TextSpan(text: '点网址列右边的分享图示 '),
            share,
          ],
          InstallBrowser.safari => [
            // iOS 26 起 Safari 有三种版面：「下方」「上方」的工具列直接有分享钮；预设的「精简」只剩网址列，分享收在网址列右边的「⋯」里。
            const TextSpan(text: '点下方工具列的分享图示 '),
            share,
            const TextSpan(text: '。下方只有网址列的话，先点网址列右边的「⋯」，再点「分享」'),
          ],
          InstallBrowser.other => [const TextSpan(text: '点浏览器的分享图示 '), share],
        },
        [const TextSpan(text: '往下滑，点「加入主画面」')],
        [const TextSpan(text: '点右上角的「加入」，之后从桌面的图示打开')],
      ],
      _ => [
        [const TextSpan(text: '点浏览器右上角的选单 '), icon(Icons.more_vert)],
        [const TextSpan(text: '点「安装应用程序」或「加到主画面」')],
        [const TextSpan(text: '点「安装」，之后从桌面的图示打开')],
      ],
    };
    return [
      for (final (index, spans) in steps.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}.',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(child: Text.rich(TextSpan(children: spans))),
            ],
          ),
        ),
    ];
  }
}
