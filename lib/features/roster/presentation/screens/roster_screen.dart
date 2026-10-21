import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/service_roster.dart';
import 'package:church_staff_pwa/core/types/service_type.dart';
import '../../../auth/presentation/providers/session_provider.dart';
import '../providers/roster_provider.dart';
import '../widgets/roster_view_card.dart';
import '../../../../core/utils/error_messages.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/utils/scroll_anchor.dart';
import '../../../../core/utils/snappy_page_scroll_physics.dart';
import 'roster_edit_screen.dart' deferred as roster_edit_screen;

class RosterScreen extends StatefulWidget {
  const RosterScreen({super.key, this.allowEdit = true});

  final bool allowEdit;

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen>
    with TickerProviderStateMixin {
  bool _editReady = false;
  bool _isLoadingEdit = false;
  TabController? _tabController;

  Future<void> _loadEditLibrary(
    BuildContext context,
    Future<void> Function() loadLibrary,
  ) async {
    if (_isLoadingEdit) return;
    _isLoadingEdit = true;
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
      setState(() {
        _editReady = true;
      });
      final rosterProvider = context.read<RosterProvider>();
      if (!rosterProvider.isEditMode) {
        // 先记下现在看到哪一天，编辑清单挂好后才换得回来。
        rosterProvider.captureScrollAnchors();
        rosterProvider.toggleEditMode();
      }
    } catch (error, st) {
      log('载入编辑模式失败', error: error, stackTrace: st);
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
      _isLoadingEdit = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rosterProvider = context.read<RosterProvider>();

      if (rosterProvider.rosters.isEmpty) {
        rosterProvider.fetchInitialData();
      }

      if (rosterProvider.isEditMode) {
        rosterProvider.toggleEditMode();
      }
    });
  }

  void _updateTabController(int length) {
    if (length <= 0) {
      _tabController?.dispose();
      _tabController = null;
      return;
    }
    if (_tabController == null || _tabController!.length != length) {
      final previousIndex = _tabController?.index ?? 0;
      _tabController?.dispose();
      _tabController = TabController(
        length: length,
        vsync: this,
        initialIndex: previousIndex.clamp(0, length - 1),
      );
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _exitEditMode() {
    final rosterProvider = context.read<RosterProvider>();
    if (rosterProvider.isEditMode) {
      rosterProvider.captureScrollAnchors();
      rosterProvider.toggleEditMode();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    // 聚会别只看牧区，不看编辑权：给了 roster-editors 不等于多看得到别的牧区。
    // 只有 admin 拿得到全部（见 [User.allowedRosterTypes]）。编辑权决定
    // 「能不能改」，牧区决定「能改哪一本」。
    final canEditRoster = session.canEditRoster;
    final canEdit = canEditRoster && widget.allowEdit;
    final allowedTypes =
        session.currentUser?.allowedRosterTypes ?? const <ServiceType>[];
    // 标题不分本季／下季：对同工来说那只是「服事表」，范围怎么算他不用管。
    const titleText = '服事表';
    // select 而非 watch：否则每次 fetch 的 loading 开关都会重建整个 Scaffold
    // （含 AppBar / TabBar / TabController）。
    final isEditMode = context.select<RosterProvider, bool>(
      (provider) => provider.isEditMode,
    );

    _updateTabController(allowedTypes.length);

    if (isEditMode && _editReady && canEdit) {
      return roster_edit_screen.RosterEditScreen(
        onExit: _exitEditMode,
        tabController: _tabController,
        allowedTypes: allowedTypes,
      );
    }

    final appBar = AppBar(
      title: Text(titleText),
      centerTitle: true,
      actions: [
        if (canEdit)
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '切换至编辑模式',
            onPressed: () =>
                _loadEditLibrary(context, roster_edit_screen.loadLibrary),
          ),
      ],
      bottom: allowedTypes.isEmpty
          ? null
          : TabBar(
              isScrollable: allowedTypes.length > 3,
              controller: _tabController,
              tabs: allowedTypes.map((type) => Tab(text: type.label)).toList(),
              indicatorSize: TabBarIndicatorSize.label,
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
    );

    if (allowedTypes.isEmpty) {
      return Scaffold(
        appBar: appBar,
        body: const EmptyState(
          icon: Icons.folder_off_outlined,
          message: '尚未设置可查看的牧区',
          hint: '请联系管理员为您添加服事牧区',
        ),
      );
    }

    return DefaultTabController(
      length: allowedTypes.length,
      child: Scaffold(
        appBar: appBar,
        // 刻意不用 Consumer 包住整个 body：Consumer 会在每一次
        // notifyListeners 重建整棵 TabBarView，连带产生全新的 ListView 与
        // 全新的卡片 widget，底下卡片再怎么 select 也挡不住。改成只订阅
        // 「要不要显示 spinner／错误」这两个 bool，清单自己去订阅自己那份资料。
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
                      '加载服事信息中…',
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

            return TabBarView(
              // 收尾动画越久，「换完分页马上想往下滑却没反应」的窗口就越长。
              physics: const SnappyPageScrollPhysics(),
              controller: _tabController,
              children: allowedTypes.map((type) {
                return _RosterViewList(
                  key: PageStorageKey(type.toString()),
                  type: type,
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}

class _RosterViewList extends StatefulWidget {
  final ServiceType type;

  const _RosterViewList({super.key, required this.type});

  @override
  State<_RosterViewList> createState() => _RosterViewListState();
}

class _RosterViewListState extends State<_RosterViewList>
    with AutomaticKeepAliveClientMixin, ScrollAnchorSupport {
  @override
  bool get wantKeepAlive => true;

  // dispose 期间 context 已经查不到 InheritedWidget，所以进场时就把 provider
  // 抓在手上，撤销登记时才有东西可用。
  late final RosterProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<RosterProvider>();
    _provider.registerScrollAnchorCapture(widget.type, captureScrollAnchor);
    // 从编辑模式切回来时，把当初顶端那一天挪回原本的位置。
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
    super.build(context);

    // 只订阅这个牧区的清单。getRostersByType 有快取，资料没变时回传同一个
    // List instance，所以其他牧区被编辑、或单纯的 loading 开关都不会重建这页。
    final rosters = context.select<RosterProvider, List<ServiceRoster>>(
      (provider) => provider.getRostersByType(widget.type),
    );

    if (rosters.isEmpty) {
      // 能编辑的人第一次进来看到空表，要知道从哪里开始，而不是「等管理员」。
      final canEdit = context.select<SessionProvider, bool>(
        (session) => session.canEditRoster,
      );
      return EmptyState(
        icon: Icons.event_busy_outlined,
        message: '此类别目前没有服事信息',
        hint: canEdit
            ? '点击右上角的铅笔开始编辑：先点击右上角列表图标「服事项目设置」添加服事项目，再到各日期点击「新增服事项目」排班。'
            : '管理员创建后会在此显示',
      );
    }

    // 事件选项换过就要重建（标签颜色是从 provider 查的，不在 roster 里）。
    context.select<RosterProvider, int>(
      (provider) => provider.eventOptionsRevision,
    );
    // 一个 tear-off 重复用，不要在 itemBuilder 里每张卡各配一个 closure。
    final resolveEventColor = context.read<RosterProvider>().eventColorOf;

    return ListView.builder(
      key: anchorListKey,
      controller: anchorController,
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      itemCount: rosters.length,
      itemBuilder: (context, index) {
        final roster = rosters[index];
        return ScrollAnchorItem(
          key: ValueKey(roster.id),
          id: roster.id,
          child: RosterViewCard(
            roster: roster,
            initiallyExpanded: index == 0,
            resolveEventColor: resolveEventColor,
          ),
        );
      },
    );
  }
}
