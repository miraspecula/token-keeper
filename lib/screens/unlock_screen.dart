import 'package:material_ui/material_ui.dart';

import '../crypto.dart';
import '../main.dart';
import '../platform_security.dart';
import '../services.dart';
import '../widgets.dart';
import 'home_screen.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _biometryAvailable = false;
  bool _autoTried = false;
  AppLifecycleListener? _resumeListener;

  @override
  void initState() {
    super.initState();
    _checkBiometry();
  }

  @override
  void dispose() {
    _resumeListener?.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _checkBiometry() async {
    if (!AppPrefs.biometryEnabled.value) return;
    final ok = await PlatformSecurity.biometricAvailable();
    if (!mounted) return;
    setState(() => _biometryAvailable = ok);
    // Один автоматический вызов биометрии при открытии экрана. Если экран
    // открыт автоблокировкой в фоне, ждём возвращения приложения: показывать
    // BiometricPrompt из фона нельзя.
    if (ok && !_autoTried) {
      _autoTried = true;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        await _biometricUnlock();
      } else {
        _resumeListener = AppLifecycleListener(onResume: () {
          _resumeListener?.dispose();
          _resumeListener = null;
          if (mounted && !SessionVault.instance.unlocked) _biometricUnlock();
        });
      }
    }
  }

  void _goHome() {
    final migrated = SessionVault.instance.lastUnlockMigrated;
    SessionVault.instance.lastUnlockMigrated = false;
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
    if (migrated) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Хранилище обновлено до формата v2. Включите биометрию заново, если пользовались ей.'),
      ));
    }
  }

  Future<void> _unlock() async {
    if (_pw.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SessionVault.instance.unlockWithPassword(_pw.text);
      if (!mounted) return;
      _pw.clear();
      _goHome();
    } on WrongPasswordException {
      if (mounted) setState(() => _error = 'Неверный пароль');
    } on CorruptVaultException {
      if (mounted) setState(() => _error = 'Файл хранилища повреждён');
    } on UnsupportedVaultException {
      if (mounted) {
        setState(() => _error = 'Хранилище создано более новой версией');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Ошибка разблокировки');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometricUnlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await AutoLock.suspendWhile(
          () => SessionVault.instance.unlockWithBiometry());
      if (!mounted) return;
      switch (result) {
        case BioResult.success:
          _pw.clear();
          _goHome();
        case BioResult.invalidated:
          setState(() {
            _biometryAvailable = false;
            _error =
                'Набор отпечатков изменился — войдите по паролю и включите биометрию заново';
          });
        case BioResult.noData:
          setState(() {
            _biometryAvailable = false;
            _error = 'Биометрия сброшена — войдите по паролю';
          });
        case BioResult.unavailable:
          setState(() => _biometryAvailable = false);
        case BioResult.cancelled:
          break; // отмена — не ошибка
        case BioResult.error:
          setState(() => _error = 'Не удалось разблокировать');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Ошибка разблокировки');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: AppLogo(size: 112)),
                const SizedBox(height: 8),
                Text(
                  'Token Keeper',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _pw,
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (_) => _unlock(),
                  decoration: const InputDecoration(
                    labelText: 'Мастер-пароль',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                FilledButton(
                  onPressed: _busy ? null : _unlock,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_busy ? 'Проверяем…' : 'Разблокировать'),
                  ),
                ),
                if (_biometryAvailable) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _biometricUnlock,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Войти по биометрии'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
