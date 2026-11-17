import 'package:material_ui/material_ui.dart';

import '../main.dart';
import '../services.dart';
import '../widgets.dart';
import 'home_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _show = false;
  bool _busy = false;

  @override
  void dispose() {
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final pw = _pw1.text;
    if (pw.length < 8) {
      _toast('Мастер-пароль — минимум 8 символов');
      return;
    }
    if (pw != _pw2.text) {
      _toast('Пароли не совпадают');
      return;
    }
    setState(() => _busy = true);
    try {
      await SessionVault.instance.setupNewVault(pw);
      if (!mounted) return;
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      _toast('Не удалось создать хранилище: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
                  'Создайте хранилище',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Мастер-пароль выводит ключ шифрования. '
                  'Восстановления не существует: забытый пароль = потерянные данные.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _pw1,
                  obscureText: !_show,
                  decoration: InputDecoration(
                    labelText: 'Мастер-пароль',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon:
                          Icon(_show ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pw2,
                  obscureText: !_show,
                  onSubmitted: (_) => _create(),
                  decoration: const InputDecoration(
                    labelText: 'Повторите пароль',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _create,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              ),
                              SizedBox(width: 12),
                              Text('Создаём…'),
                            ],
                          )
                        : const Text('Создать хранилище'),
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Вычисляем ключ шифрования (Argon2id) — это занимает пару секунд.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Биометрию можно включить в настройках.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
