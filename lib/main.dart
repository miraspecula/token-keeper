import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'platform_security.dart';
import 'services.dart';
import 'store.dart';
import 'screens/setup_screen.dart';
import 'screens/unlock_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPrefs.load();
  // Удаляем открытый кэш DEK, оставшийся от старого MVP.
  await PlatformSecurity.wipeLegacySecureStorage();
  // Запрет скриншотов/превью в списке задач (Android FLAG_SECURE).
  await PlatformSecurity.setSecureFlag(AppPrefs.secureScreen.value);
  runApp(const TokenKeeperApp());
}

class TokenKeeperApp extends StatefulWidget {
  const TokenKeeperApp({super.key});

  @override
  State<TokenKeeperApp> createState() => _TokenKeeperAppState();
}

class _TokenKeeperAppState extends State<TokenKeeperApp>
    with WidgetsBindingObserver {
  DateTime? _pausedAt;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _lockNow() {
    _lockTimer?.cancel();
    _lockTimer = null;
    SessionVault.instance.lock();
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const UnlockScreen()),
      (route) => false,
    );
  }

  // Autolock: свернули приложение — блокируем сразу (0 мин) или по таймеру;
  // вернулись позже лимита — блокируем немедленно.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pausedAt ??= DateTime.now();
        if (!SessionVault.instance.unlocked) return;
        final minutes = AppPrefs.lockMinutes.value;
        if (minutes == 0 && !AutoLock.suspended) {
          _lockNow();
        } else {
          _lockTimer?.cancel();
          _lockTimer = Timer(
            Duration(minutes: math.max(minutes, 1)),
            () {
              if (SessionVault.instance.unlocked) _lockNow();
            },
          );
        }
      case AppLifecycleState.resumed:
        _lockTimer?.cancel();
        _lockTimer = null;
        final pausedAt = _pausedAt;
        _pausedAt = null;
        if (pausedAt == null) return;
        if (!SessionVault.instance.unlocked) return;
        final minutes = AppPrefs.lockMinutes.value;
        final limit = (minutes == 0 && AutoLock.suspended) ? 1 : minutes;
        final elapsed = DateTime.now().difference(pausedAt);
        if (elapsed >= Duration(minutes: limit)) {
          _lockNow();
        }
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppPrefs.themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Token Keeper',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: mode,
          home: const SplashScreen(),
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B6ABF),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
      ),
    );
  }
}

/// Определяет первый экран: настройка или разблокировка.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    final exists = await VaultStore.exists();
    if (!mounted) return;
    final nav = navigatorKey.currentState ?? Navigator.of(context);
    nav.pushReplacement(MaterialPageRoute(
      builder: (_) => exists ? const UnlockScreen() : const SetupScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
