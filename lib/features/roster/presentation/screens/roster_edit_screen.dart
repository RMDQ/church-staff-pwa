import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/service_roster.dart';
import 'package:church_staff_pwa/core/config/church_config.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../auth/presentation/providers/session_provider.dart';
import '../../../auth/presentation/providers/user_admin_provider.dart';
import '../../../auth/domain/entities/user.dart';
import '../../data/roster_import_service.dart';
import '../../data/roster_photo.dart';
import '../../data/roster_photo_picker.dart';
import '../providers/roster_provider.dart';
import '../widgets/roster_card.dart';
import '../widgets/photo_import_progress.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/utils/scroll_anchor.dart';
import '../../../../core/utils/snappy_page_scroll_physics.dart';
import '../../../../core/widgets/settings_bottom_sheet.dart';
import 'event_settings_screen.dart' deferred as event_settings_screen;
import 'role_settings_screen.dart' deferred as role_settings_screen;
import '../../domain/roster_import.dart';
import 'roster_import_summary.dart';

bool get _photoImportAvailable =>
    ChurchConfig.current.features.photoImport && canPickRosterPhotos;

class RosterEditScreen extends StatefulWidget {
  final VoidCallback onExit;
  final TabController? tabController;
  final List<ServiceType> allowedTypes;

  const RosterEditScreen({
    super.key,
    required this.onExit,
    required this.tabController,
    required this.allowedTypes,
  });

  @override
  State<RosterEditScreen> createState() => _RosterEditScreenState();
}

class _RosterEditScreenState extends State<RosterEditScreen> {
  Future<void> _loadAndPush(
    BuildContext context,
    Future<void> Function() loadLibrary,
    Widget Function() builder,
  ) async {
    var dialogShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await loadLibrary();
      if (!context.mounted) return;
      if (dialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogShown = false;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => builder()));
    } catch (error, st) {
      log('载入设定画面失败', error: error, stackTrace: st);
      if (context.mounted) {
        if (dialogShown) {
          Navigator.of(context, rootNavigator: true).pop();
          dialogShown = false;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('载入失败：${mapErrorToUserMessage(error)}')),
        );
      }
    } finally {
      if (dialogShown && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final session = context.read<SessionProvider>();

      if (!session.canEditRoster) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有权限进入编辑模式')));
        widget.onExit();
        return;
      }

      // 进入编辑模式时，背景补齐本季 + 下季的 roster（backfill）。
      // 在无编辑权的路径下已 return，此处一定有写入权 —— 但只在自己的牧区内，
      // 所以补的范围限制在 allowedTypes（同一个 batch 混进别的聚会别会整批被
      // rules 拒绝）。失败静默处理（ensureQuarterRosters 内部 catch），不影响 UI。
      context.read<RosterProvider>().ensureQuarterRostersForEditor(
        widget.allowedTypes,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final allowedTypes = widget.allowedTypes;
    // settings 的写入权在 firestore.rules 里是 admin only，所以非 admin 看到
    // 这两颗按钮只会按下去然后失败 —— 不如不要显示。
    final isAdmin = context.select<SessionProvider, bool>((s) => s.isAdmin);
    const titleText = '编辑服事表';

    final appBar = AppBar(
      title: Text(titleText),
      centerTitle: true,
      actions: [
        if (isAdmin) ...[
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: '事件选项设定',
            onPressed: () => _loadAndPush(
              context,
              event_settings_screen.loadLibrary,
              () => event_settings_screen.EventSettingsScreen(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt_outlined),
            tooltip: '服事项目设定',
            onPressed: () => _loadAndPush(
              context,
              role_settings_screen.loadLibrary,
              () => role_settings_screen.RoleSettingsScreen(),
            ),
          ),
        ],
        // 以前是 view_list 图示，跟旁边「服事项目设定」的清单图示几乎一样，
        // 照著「按清单图示」的说明就会按到这颗、直接离开编辑模式。
        Tooltip(
          message: '切换至检视模式',
          child: TextButton(onPressed: widget.onExit, child: const Text('完成')),
        ),
      ],
      bottom: allowedTypes.isEmpty
          ? null
          : TabBar(
              controller: widget.tabController,
              isScrollable: allowedTypes.length > 3,
              tabs: allowedTypes.map((type) => Tab(text: type.label)).toList(),
              indicatorSize: TabBarIndicatorSize.label,
              // 让切换时的动画更平滑
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
    );

    if (allowedTypes.isEmpty) {
      return Scaffold(
        appBar: appBar,
        body: const EmptyState(
          icon: Icons.folder_off_outlined,
          message: '尚未设定可检视的牧区',
          hint: '请先到使用者管理为您指派服事牧区',
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      // 同 roster_screen：不要用 Consumer 包住整个 body，否则每次
      // notifyListeners 都会重建整棵 TabBarView 与所有卡片。
      body: Builder(
        builder: (context) {
          // stale-while-revalidate: only block the UI with a spinner when
          // there is truly no data to show yet.  If we already have cached
          // rosters the TabBarView renders immediately while the background
          // server fetch runs silently.
          final showSpinner = context.select<RosterProvider, bool>(
            (provider) => provider.isLoading && provider.rosters.isEmpty,
          );
          if (showSpinner) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    '载入服事资讯中…',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            );
          }

          final error = context.select<RosterProvider, String?>(
            (provider) => provider.error,
          );
          if (error != null) {
            return EmptyState(
              icon: Icons.error_outline,
              message: error,
              action: FilledButton.icon(
                onPressed: () =>
                    context.read<RosterProvider>().fetchInitialData(),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            );
          }

          // TabBarView 预设支援左右滑动
          return TabBarView(
            // 收尾动画越久，「换完分页马上想往下滑却没反应」的窗口就越长。
            physics: const SnappyPageScrollPhysics(),
            controller: widget.tabController,
            children: allowedTypes.map((type) {
              return _RosterList(
                key: PageStorageKey(type.toString()),
                type: type,
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

class _RosterList extends StatefulWidget {
  final ServiceType type;

  const _RosterList({super.key, required this.type});

  @override
  State<_RosterList> createState() => _RosterListState();
}

// 使用 AutomaticKeepAliveClientMixin 来保持滑动位置
class _RosterListState extends State<_RosterList>
    with AutomaticKeepAliveClientMixin, ScrollAnchorSupport {
  @override
  bool get wantKeepAlive => true; // 告诉 Flutter 保持这个页面的状态

  // dispose 期间 context 已经查不到 InheritedWidget，所以进场时就把 provider
  // 抓在手上，撤销登记时才有东西可用。
  late final RosterProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<RosterProvider>();
    _provider.registerScrollAnchorCapture(widget.type, captureScrollAnchor);
    // 检视模式切进来时，把当初顶端那一天挪回原本的位置：编辑清单多了一张汇入
    // 卡、每列多了两颗按钮，同一个 pixel offset 在这里指到的是别天。
    final anchor = _provider.scrollAnchorFor(widget.type);
    if (anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => restoreScrollAnchor(anchor),
      );
    }
  }

  @override
  void dispose() {
    _provider.unregisterScrollAnchorCapture(widget.type, captureScrollAnchor);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须呼叫 super.build
    final isEditMode = context.select<RosterProvider, bool>(
      (provider) => provider.isEditMode,
    );
    // 只订阅这个牧区的清单（getRostersByType 有快取，资料没变时 identity 不变）。
    final rosters = context.select<RosterProvider, List<ServiceRoster>>(
      (provider) => provider.getRostersByType(widget.type),
    );

    if (rosters.isEmpty) {
      return EmptyState(
        icon: Icons.event_busy_outlined,
        message: '此类别目前没有服事资讯',
        hint: isEditMode
            ? (_photoImportAvailable ? '可以用服事表照片快速建立' : '懂技术的同工可以贴上 JSON 快速建立')
            : '管理员建立后会在这里显示',
        action: isEditMode
            ? OutlinedButton.icon(
                onPressed: () => _showImportJsonDialog(context),
                icon: const Icon(Icons.upload_file),
                label: const Text('汇入服事表'),
              )
            : null,
      );
    }

    final showImport = isEditMode;
    return ListView.builder(
      key: anchorListKey,
      controller: anchorController,
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      itemCount: rosters.length + (showImport ? 1 : 0),
      itemBuilder: (context, index) {
        if (showImport && index == 0) {
          return _buildImportCard(context);
        }
        final rosterIndex = index - (showImport ? 1 : 0);
        final roster = rosters[rosterIndex];
        return ScrollAnchorItem(
          key: ValueKey(roster.id),
          id: roster.id,
          child: RosterCard(
            roster: roster,
            initiallyExpanded: rosterIndex == 0,
          ),
        );
      },
    );
  }

  Widget _buildImportCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _photoImportAvailable ? '汇入服事表' : '进阶：汇入整季服事表',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  // 没有照片辨识时只剩贴 JSON，那是给技术同工的。新教会第一次
                  // 进编辑模式最先看到这张卡，要让他知道可以跳过。
                  Text(
                    _photoImportAvailable
                        ? '用服事表照片辨识，依日期批次填入'
                        : '给懂技术的同工用（贴上 JSON 资料）。一般直接在下面各日期按「新增服事项目」排班即可。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (_photoImportAvailable)
              FilledButton.icon(
                onPressed: () => _showImportJsonDialog(context),
                icon: const Icon(Icons.upload_file),
                label: const Text('汇入'),
              )
            else
              OutlinedButton.icon(
                onPressed: () => _showImportJsonDialog(context),
                icon: const Icon(Icons.upload_file),
                label: const Text('汇入'),
              ),
          ],
        ),
      ),
    );
  }

  /// 照片转 JSON。建一次就好 —— 它没有状态，每次开 sheet 都新建一个
  /// http.Client 只是多开连线池。
  late final RosterImportService _importService = RosterImportService();

  Future<void> _showImportJsonDialog(BuildContext context) async {
    final result = await showModalBottomSheet<_JsonImportResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => _ImportJsonSheet(
        type: widget.type,
        importService: _importService,
        onSubmit: (raw) => _applyJsonImport(sheetContext, raw),
      ),
    );
    // sheet 自己关掉时才有结果。成功之后的报告留在这里而不是 sheet 里：
    // 汇入结果视窗要活得比 sheet 久，挂在正在退场的那棵子树上会被一起带走。
    if (result == null || !context.mounted) return;

    final summary = result.summary;
    if (summary == null) return;
    if (summary.hasIssues) {
      await _showImportSummaryDialog(context, summary);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(importResultMessage(summary))));
  }

  /// 依姓名把服事补进该同工的设定。
  ///
  /// 失败一律丢 [ImportFixException]：这几种原因使用者看得懂也处理得了，被
  /// mapErrorToUserMessage 压成「操作失败，请稍后再试」的话就只剩重试可按。
  Future<void> _addMinistryToUser(
    UserAdminProvider userAdminProvider,
    List<String> templateRoles,
    String name,
    List<String> roles,
  ) async {
    // 样板里没有的服事写进去也留不住：帐号管理的选单只渲染样板内的项目，
    // 看不到也删不掉，而下次有人存档服事项目设定时 cleanupUserMinistries 会
    // 把它清掉 —— 使用者只会看到自己按过「已新增」的东西过阵子又被报一次。
    // 与其让它悄悄消失，不如当场说清楚。
    final outside = roles.where((r) => !templateRoles.contains(r)).toList();
    if (outside.isNotEmpty) {
      throw ImportFixException(
        '「${outside.join('、')}」不在服事项目样板里，加了也会被清掉。'
        '请先到服事项目设定新增这个项目',
      );
    }

    final users = await userAdminProvider.getUsers();
    final matches = users.where((u) => u.name.trim() == name.trim()).toList();
    if (matches.isEmpty) {
      throw ImportFixException('找不到同工「$name」，可能已被删除');
    }
    // 同名同姓时刻意不猜：补错人的设定没有任何迹象，会一路错到下次排班。
    if (matches.length > 1) {
      throw ImportFixException('有 ${matches.length} 位同工都叫「$name」，请到帐号管理手动设定');
    }
    await userAdminProvider.updateUser(
      addMinistriesToUser(matches.single, widget.type, roles),
    );
  }

  Future<void> _showImportSummaryDialog(
    BuildContext context,
    RosterImportSummary summary,
  ) async {
    final userAdminProvider = context.read<UserAdminProvider>();
    // 补设定写的是 users/{uid}、加活动写的是 settings/，firestore.rules 里
    // 两个都是 admin only。服事表编辑者进得来汇入流程，但这两项都补不了。
    final isAdmin = context.read<SessionProvider>().isAdmin;
    final rosterProvider = context.read<RosterProvider>();
    final templateRoles = rosterProvider.templates[widget.type] ?? const [];
    await showDialog(
      context: context,
      builder: (context) {
        return RosterImportSummaryDialog(
          type: widget.type,
          summary: summary,
          onAddMinistry: isAdmin
              ? (name, roles) => _addMinistryToUser(
                  userAdminProvider,
                  templateRoles,
                  name,
                  roles,
                )
              : null,
          onAddEvent: isAdmin
              ? (name) => rosterProvider.addEventOption(widget.type, name)
              : null,
        );
      },
    );
  }

  /// 读现况、交给 [planRosterImport]、把它要写的写进去。
  ///
  /// 怎么对名字、怎么排顺序、哪天要改什么都在 planRosterImport 里，这里只剩
  /// 它碰不到的两件事：读同工名单、写 Firestore。
  Future<_JsonImportResult> _applyJsonImport(
    BuildContext context,
    String raw,
  ) async {
    final userAdminProvider = context.read<UserAdminProvider>();
    final rosterProvider = context.read<RosterProvider>();

    final List<User> users;
    try {
      users = await userAdminProvider.getUsers();
    } catch (_) {
      return const _JsonImportResult.failed('无法载入同工名单');
    }

    final plan = planRosterImport(
      input: raw,
      type: widget.type,
      users: users,
      rosters: rosterProvider.getRostersByType(widget.type),
      templates: rosterProvider.templatesLoaded
          ? rosterProvider.templates
          : null,
      eventOptions: rosterProvider.eventOptionsFor(widget.type),
    );
    final RosterImportReady ready;
    switch (plan) {
      case RosterImportRejected(:final message):
        return _JsonImportResult.failed(message);
      case RosterImportReady():
        ready = plan;
    }

    try {
      await rosterProvider.applyRosterImport(widget.type, ready);
    } catch (e, st) {
      log('汇入过程写入 Firestore 失败', error: e, stackTrace: st);
      String msg;
      if (e is PartialUpdateException) {
        // Log the underlying cause's stack too so future Sentry has the
        // real Firestore error, not just the wrapping exception's stack.
        log('汇入部分失败的代表性 cause', error: e.cause, stackTrace: e.causeStackTrace);
        final failedDates = e.failedRosters
            .map((r) => rosterDateKey(r.date))
            .join('、');
        msg =
            '${e.successCount} 笔已写入、${e.failureCount} 笔失败。'
            '失败日期：$failedDates。请重新整理确认状态后重试';
      } else {
        // 服事表那一步失败一律是 PartialUpdateException，走到这里的是更早
        // 的同工排序那一步 —— 服事表一张都还没写。
        msg = '${mapErrorToUserMessage(e)}。服事表没有动，可以直接重试';
      }
      return _JsonImportResult.failed('汇入过程写入失败：$msg');
    }

    return _JsonImportResult.done(ready.summary);
  }
}

/// sheet 交回来的东西：写完的报告，或是要留在 sheet 上的错误。
class _JsonImportResult {
  const _JsonImportResult.done(RosterImportSummary this.summary) : error = null;
  const _JsonImportResult.failed(String this.error) : summary = null;

  final RosterImportSummary? summary;
  final String? error;
}

/// 汇入用的 bottom sheet。
///
/// 抽成独立的 widget 而不是留在 `_showImportJsonDialog` 里的 StatefulBuilder：
/// 那个函式长到两百行，而其中真正属于画面的状态有四个（错误、送出中、辨识中、
/// JSON 栏位开合），全靠闭包变数撑著。有了 State 之后 controller 也能自己
/// dispose —— dispose 是在退场动画结束后才跑的，不会像 sheet 的 future 那样
/// 在 pop 当下就把 TextField 底下的东西抽掉。
class _ImportJsonSheet extends StatefulWidget {
  const _ImportJsonSheet({
    required this.type,
    required this.importService,
    required this.onSubmit,
  });

  final ServiceType type;
  final RosterImportService importService;

  /// 真正写进 Firestore 的那一步。留在画面外面是因为它要用到 provider 与
  /// 服事表样板，那些是 screen 的事，不是这张 sheet 的。
  final Future<_JsonImportResult> Function(String raw) onSubmit;

  @override
  State<_ImportJsonSheet> createState() => _ImportJsonSheetState();
}

class _ImportJsonSheetState extends State<_ImportJsonSheet> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;
  bool _isSubmitting = false;
  bool _isConverting = false;

  /// 选照片的那段时间也要算「忙碌」。只在辨识开始后才锁按钮的话，iPhone 上
  /// 一次点击偶尔会触发两次，第二个选择器排在第一个后面，选完一张又跳出一个。
  /// 用栏位而不是 setState 判断：第二次触发跟第一次在同一个 frame 内，等不到
  /// 重建按钮就已经进来了。
  bool _isPicking = false;

  /// 有照片辨识可用时，贴 JSON 是备援而不是主要动作 —— 预设收起来。
  /// 辨识完会自动展开，因为那时它变成「看一眼再汇入」的地方。
  bool _showJsonField = !_photoImportAvailable;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _convertFromPhoto() async {
    if (!_photoImportAvailable || _isPicking || _isConverting) return;
    _isPicking = true;
    setState(() => _errorText = null);
    final RosterPhoto? photo;
    try {
      photo = await pickRosterPhoto();
    } on RosterPhotoException catch (e) {
      if (mounted) setState(() => _errorText = e.message);
      return;
    } catch (e, st) {
      _reportUnexpected(e, st);
      return;
    } finally {
      _isPicking = false;
    }
    // 使用者按了取消。那不是错误，什么都不做。
    if (photo == null || !mounted) return;

    setState(() => _isConverting = true);
    try {
      final json = await widget.importService.convert(
        type: widget.type,
        photos: [photo],
      );
      if (!mounted) return;
      _controller.text = json;
      setState(() {
        _isConverting = false;
        _showJsonField = true;
      });
    } on RosterImportException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _errorText = e.message;
      });
    } catch (e, st) {
      _reportUnexpected(e, st);
    }
  }

  /// 预期外的失败（读档、拿登入 token 之类）也要让画面有反应。只接自己
  /// 定义的例外的话，其他错误会被 async 吞掉 —— 使用者看到的就是「选完照片
  /// 什么都没有」，连转圈都没有。
  void _reportUnexpected(Object error, StackTrace stackTrace) {
    debugPrint('roster photo import failed: $error\n$stackTrace');
    if (!mounted) return;
    setState(() {
      _isConverting = false;
      _errorText = '辨识失败：$error';
    });
  }

  Future<void> _submit() async {
    // 空白时 parser 只会说「请贴上 JSON 内容」，但这个画面上根本没有可以贴的
    // 地方（文字框收著）—— 要讲得出下一步在哪。
    if (_controller.text.trim().isEmpty && _photoImportAvailable) {
      setState(() {
        _errorText = '请先从照片辨识，或展开下面自己贴 JSON';
        _showJsonField = true;
      });
      return;
    }

    setState(() {
      _errorText = null;
      _isSubmitting = true;
    });
    final result = await widget.onSubmit(_controller.text);
    if (!mounted) return;
    if (result.error != null) {
      setState(() {
        _errorText = result.error;
        _isSubmitting = false;
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isSubmitting || _isConverting;
    return SettingsBottomSheet(
      title: '汇入服事表（${widget.type.label}）',
      submitLabel: '汇入',
      isSubmitting: _isSubmitting,
      onSubmit: busy ? null : _submit,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 辨识结果填回下面那个文字框，不直接汇入：看一眼再按汇入是这个流程
          // 唯一的把关，而按下汇入走的还是跟手动贴上完全一样的那条路。
          if (_photoImportAvailable) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : _convertFromPhoto,
                icon: _isConverting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_camera_outlined, size: 18),
                label: Text(_isConverting ? '辨识中…' : '从照片辨识'),
              ),
            ),
            if (_isConverting) ...[
              const SizedBox(height: 6),
              const PhotoImportProgress(),
            ],
            const SizedBox(height: 4),
            // 收合的理由不是版面好看，是这条路平常用不到：Gemini 挂掉、额度
            // 用完、模型下架时，从别处转好再贴进来是唯一还走得通的路，所以它
            // 要在，但不该挡在前面。
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() => _showJsonField = !_showJsonField),
                icon: Icon(
                  _showJsonField
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 18,
                ),
                label: const Text('自己贴 JSON'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
          if (_showJsonField)
            TextField(
              controller: _controller,
              maxLines: 12,
              decoration: InputDecoration(
                hintText:
                    '[\n  {\n    "date": "2026-01-04",\n    "duties": [\n      {"people": ["待定"], "role": "敬拜主领"}\n    ],\n    "events": ["圣餐", {"name": "受洗礼", "color": "#F39C12"}]\n  }\n]',
                hintStyle: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.35),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          if (_errorText != null) ...[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _errorText!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _photoImportAvailable
                ? '可以直接选服事表照片辨识，或自己贴上 JSON。'
                      '格式需为阵列，每笔含 date，并至少含 duties 或 events'
                : '格式需为 JSON 阵列，每笔含 date，并至少含 duties 或 events',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
