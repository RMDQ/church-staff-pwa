import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'core/config/church_config.dart';
import 'core/config/service_catalog.dart';
import 'core/services/push_notification_service.dart';
import 'features/roster/data/repositories/firestore_roster_repository.dart';
import 'features/roster/presentation/providers/roster_provider.dart';
import 'features/auth/data/repositories/firebase_auth_repository.dart';
import 'features/auth/data/repositories/firestore_group_settings_repository.dart';
import 'features/auth/presentation/providers/session_provider.dart';
import 'features/auth/presentation/providers/user_admin_provider.dart';
import 'features/auth/presentation/providers/group_settings_provider.dart';
import 'features/auth/presentation/screens/login_screen.dart';
import 'features/services/data/service_settings_repository.dart';
import 'features/services/presentation/providers/service_catalog_provider.dart';
import 'presentation/screens/main_scaffold.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = ChurchConfig.current;

  // Run independent inits in parallel to shave startup latency.
  await Future.wait([
    initializeDateFormatting('zh_CN', null),
    initializeDateFormatting('zh_TW', null),
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    // 管理员在 App 里改过的聚会清单（上一次读到的），不等网路。
    ServiceCatalog.applyCached(),
  ]);

  // Force long polling on web instead of WebSocket. WebSocket transport is
  // unstable on Safari (iOS + macOS), causing dropped Firestore subscriptions
  // for our iPhone users. Long polling is slightly slower but reliable across
  // browsers. See commit 7d6b4e2.
  FirebaseFirestore.instance.settings = const Settings(
    webExperimentalForceLongPolling: true,
    // persistenceEnabled 预设为 true（IndexedDB），明示以确保行为清晰。
    // cacheSizeBytes 维持预设 40MB，对本应用来说足够。
    persistenceEnabled: true,
  );

  // PushNotificationService.initialize only registers stream listeners; we
  // don't need to block runApp on it.
  final pushNotificationService = PushNotificationService();
  if (config.features.pushNotifications) {
    unawaited(pushNotificationService.initialize());
  }

  runApp(ChurchApp(pushNotificationService: pushNotificationService));
}

class ChurchApp extends StatelessWidget {
  const ChurchApp({super.key, required this.pushNotificationService});

  final PushNotificationService pushNotificationService;

  // fromSeed 会跑一整套 Material color 演算法，结果永远一样，算一次就好。
  static final ColorScheme _colorScheme = ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.light,
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = _colorScheme;
    return MultiProvider(
      providers: [
        Provider<PushNotificationService>.value(value: pushNotificationService),

        // SessionProvider — 管理登入状态，最上游。
        ChangeNotifierProvider(
          create: (_) => SessionProvider(FirebaseAuthRepository()),
        ),

        // UserAdminProvider — 依赖 SessionProvider。
        // 使用 ChangeNotifierProxyProvider 注入 session，让它在登出时自动清 cache。
        ChangeNotifierProxyProvider<SessionProvider, UserAdminProvider>(
          create: (ctx) => UserAdminProvider(
            FirebaseAuthRepository(),
            ctx.read<SessionProvider>(),
          ),
          update: (_, session, prev) {
            // prev 不会是 null（create 已建立）；update 仅在依赖变动时呼叫。
            // UserAdminProvider 自己监听 session，此处不需额外操作。
            return prev!;
          },
        ),

        // RosterProvider — session 变动时清 cache 并重抓。
        ChangeNotifierProxyProvider<SessionProvider, RosterProvider>(
          create: (_) => RosterProvider(FirestoreRosterRepository()),
          update: (_, session, prev) {
            prev ??= RosterProvider(FirestoreRosterRepository());
            prev.onSessionChanged(session.currentUser?.id);
            return prev;
          },
        ),

        // ServiceCatalogProvider — 登入后读 settings/services，聚会清单变了就重载。
        // lazy: false：平常没有画面读它（只有「聚会设定」会），预设的 lazy
        // 会让它到打开设定页才建立，其他装置就永远不会去读新的聚会清单。
        ChangeNotifierProxyProvider<SessionProvider, ServiceCatalogProvider>(
          lazy: false,
          create: (_) =>
              ServiceCatalogProvider(FirestoreServiceSettingsRepository()),
          update: (_, session, prev) {
            prev ??= ServiceCatalogProvider(
              FirestoreServiceSettingsRepository(),
            );
            prev.onSessionChanged(session.currentUser?.id);
            return prev;
          },
        ),

        // GroupSettingsProvider — session 变动时清 cache 并重抓。
        ChangeNotifierProxyProvider<SessionProvider, GroupSettingsProvider>(
          create: (_) =>
              GroupSettingsProvider(FirestoreGroupSettingsRepository()),
          update: (_, session, prev) {
            prev ??= GroupSettingsProvider(FirestoreGroupSettingsRepository());
            prev.onSessionChanged(session.currentUser?.id);
            return prev;
          },
        ),
      ],
      child: MaterialApp(
        title: ChurchConfig.current.appName,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: colorScheme,
          inputDecorationTheme: InputDecorationTheme(
            hintStyle: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
          appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
        ),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('zh'),
          Locale('en', 'US'),
        ],
        home: AuthWrapper(pushNotificationService: pushNotificationService),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key, required this.pushNotificationService});

  final PushNotificationService pushNotificationService;

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  SessionProvider? _sessionProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextSessionProvider = context.read<SessionProvider>();
    if (_sessionProvider == nextSessionProvider) return;

    _sessionProvider?.removeListener(_onSessionChanged);
    _sessionProvider = nextSessionProvider;
    _sessionProvider!.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  @override
  void dispose() {
    _sessionProvider?.removeListener(_onSessionChanged);
    unawaited(widget.pushNotificationService.dispose());
    super.dispose();
  }

  void _onSessionChanged() {
    final userId = _sessionProvider?.currentUser?.id;
    unawaited(widget.pushNotificationService.syncTokenForUser(userId));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionProvider>(
      builder: (context, session, _) {
        if (session.isRestoring) {
          return const _AuthRestoringShell();
        }
        if (!session.isAuthenticated) {
          return const LoginScreen();
        }
        return const MainScaffold();
      },
    );
  }
}

/// Shown while SessionProvider is awaiting Firebase Auth state from IndexedDB on
/// app start. Faster perceived load than a blank screen + spinner: the user
/// sees the church branding immediately and an inline status row below it.
class _AuthRestoringShell extends StatelessWidget {
  const _AuthRestoringShell();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ChurchConfig.current.appName,
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 12),
                  Text('载入中…', style: theme.textTheme.titleMedium),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
