import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../crypto.dart';
import '../main.dart';
import '../platform_security.dart';
import '../services.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- Смена пароля ---------------------------------------------------------

  Future<void> _changePassword() async {
    final oldC = TextEditingController();
    final new1 = TextEditingController();
    final new2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Смена мастер-пароля'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldC,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Текущий пароль', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: new1,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Новый пароль', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: new2,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Повторите новый пароль',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Сменить')),
        ],
      ),
    );
    final oldPw = oldC.text;
    final newPw = new1.text;
    final repeatPw = new2.text;
    oldC.dispose();
    new1.dispose();
    new2.dispose();
    if (!mounted || ok != true) return;
    if (newPw.length < 8) {
      _toast('Новый пароль — минимум 8 символов');
      return;
    }
    if (newPw != repeatPw) {
      _toast('Новые пароли не совпадают');
      return;
    }
    final hadBiometry = AppPrefs.biometryEnabled.value;
    setState(() => _busy = true);
    try {
      await SessionVault.instance.changePassword(oldPw, newPw);
      if (!mounted) return;
      _toast(hadBiometry
          ? 'Пароль изменён. Ключ данных перевыпущен; биометрию нужно включить заново.'
          : 'Пароль изменён');
    } on WrongPasswordException {
      _toast('Неверный текущий пароль');
    } catch (e) {
      _toast('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Биометрия -----------------------------------------------------------

  Future<void> _toggleBiometry(bool v) async {
    if (v) {
      setState(() => _busy = true);
      try {
        final result = await AutoLock.suspendWhile(
            () => SessionVault.instance.enableBiometry());
        if (!mounted) return;
        switch (result) {
          case BioResult.success:
            _toast('Биометрия включена');
          case BioResult.unavailable:
            _toast('Биометрия недоступна на устройстве');
          case BioResult.cancelled:
            break; // отмена — без сообщений
          case BioResult.invalidated:
          case BioResult.noData:
          case BioResult.error:
            _toast('Не удалось включить биометрию');
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    } else {
      await SessionVault.instance.disableBiometry();
      if (mounted) setState(() {});
    }
  }

  // ---- Запрет скриншотов ---------------------------------------------------

  Future<void> _toggleSecure(bool v) async {
    await AppPrefs.setSecureScreen(v);
    await PlatformSecurity.setSecureFlag(v);
    if (mounted) setState(() {});
  }

  // ---- Иконки сайтов -------------------------------------------------------

  Future<void> _toggleFavicons(bool v) async {
    await AppPrefs.setFavicons(v);
    if (!v) await FaviconService.clearCache();
    if (mounted) setState(() {});
  }

  // ---- Экспорт -------------------------------------------------------------

  Future<void> _export() async {
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Экспорт хранилища'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Файл будет зашифрован отдельным паролем экспорта. '
                'Пароль нужно будет ввести при импорте.'),
            const SizedBox(height: 12),
            TextField(
              controller: p1,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Пароль экспорта', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: p2,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Повторите', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Экспортировать')),
        ],
      ),
    );
    final exportPw = p1.text;
    final repeatPw = p2.text;
    p1.dispose();
    p2.dispose();
    if (!mounted || ok != true) return;
    if (exportPw.length < 8 || exportPw != repeatPw) {
      _toast('Пароли должны совпадать и быть не короче 8 символов');
      return;
    }
    setState(() => _busy = true);
    File? temp;
    try {
      final jsonText = await SessionVault.instance.exportToString(exportPw);
      final dir = await getTemporaryDirectory();
      temp = File(
          '${dir.path}/token_keeper_export_${DateTime.now().millisecondsSinceEpoch}.tkenc');
      await temp.writeAsString(jsonText, flush: true);
      final file = temp;
      await AutoLock.suspendWhile(() => SharePlus.instance.share(ShareParams(
            files: [XFile(file.path)],
            text: 'Резервная копия Token Keeper',
          )));
    } catch (e) {
      _toast('Ошибка экспорта: $e');
    } finally {
      if (temp != null) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Импорт --------------------------------------------------------------

  Future<void> _import() async {
    final picked =
        await AutoLock.suspendWhile(() => FilePicker.pickFile());
    if (!mounted || picked == null) return;
    String text;
    try {
      text = utf8.decode(await picked.readAsBytes());
    } catch (_) {
      _toast('Не удалось прочитать файл');
      return;
    }
    if (!mounted) return;
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Импорт хранилища'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Текущие данные будут заменены содержимым файла. '
                'Введите пароль экспорта.'),
            const SizedBox(height: 12),
            TextField(
              controller: pw,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Пароль экспорта', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Импортировать')),
        ],
      ),
    );
    final importPw = pw.text;
    pw.dispose();
    if (!mounted || ok != true) return;
    setState(() => _busy = true);
    try {
      await SessionVault.instance.importAndReplace(text, importPw);
      if (!mounted) return;
      _toast('Импорт выполнен');
    } on WrongPasswordException {
      _toast('Неверный пароль экспорта');
    } on CorruptVaultException {
      _toast('Файл повреждён или это не экспорт Token Keeper');
    } on UnsupportedVaultException {
      _toast('Файл создан более новой версией приложения');
    } catch (e) {
      _toast('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Полное удаление -----------------------------------------------------

  Future<void> _wipeAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить всё?'),
        content: const Text(
            'Хранилище будет удалено безвозвратно. Восстановить данные будет невозможно.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    setState(() => _busy = true);
    try {
      await SessionVault.instance.wipeAll();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SetupScreen()),
      (route) => false,
    );
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          if (_busy) const LinearProgressIndicator(),
          const _Section('Внешний вид'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: AppPrefs.themeMode,
            builder: (context, mode, _) => RadioGroup<ThemeMode>(
              groupValue: mode,
              onChanged: (m) {
                if (m != null) AppPrefs.setTheme(m);
              },
              child: const Column(
                children: [
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.light,
                    title: Text('Светлая тема'),
                  ),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.dark,
                    title: Text('Тёмная тема'),
                  ),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.system,
                    title: Text('Как в системе'),
                  ),
                ],
              ),
            ),
          ),
          const Divider(),
          const _Section('Безопасность'),
          ValueListenableBuilder<bool>(
            valueListenable: AppPrefs.biometryEnabled,
            builder: (context, v, _) => SwitchListTile(
              title: const Text('Вход по биометрии'),
              subtitle: const Text('Разблокировка отпечатком или лицом'),
              value: v,
              onChanged: _busy ? null : _toggleBiometry,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: AppPrefs.secureScreen,
            builder: (context, v, _) => SwitchListTile(
              title: const Text('Запретить скриншоты'),
              subtitle: const Text('Превью в списке задач будет скрыто'),
              value: v,
              onChanged: _busy ? null : _toggleSecure,
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: AppPrefs.lockMinutes,
            builder: (context, minutes, _) {
              final label = minutes == 0 ? 'сразу' : '$minutes мин';
              return ListTile(
                title: const Text('Автоблокировка в фоне'),
                subtitle: Slider(
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: label,
                  value: minutes.toDouble(),
                  onChanged: (v) => AppPrefs.setLockMinutes(v.round()),
                ),
                trailing: Text(label),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.password_outlined),
            title: const Text('Сменить мастер-пароль'),
            onTap: _busy ? null : _changePassword,
          ),
          const Divider(),
          const _Section('Приватность'),
          ValueListenableBuilder<bool>(
            valueListenable: AppPrefs.faviconsEnabled,
            builder: (context, v, _) => SwitchListTile(
              title: const Text('Загружать иконки сайтов'),
              subtitle: const Text(
                  'Выключено по умолчанию: при загрузке сайты узнают, какими сервисами вы пользуетесь.'),
              value: v,
              onChanged: _busy ? null : _toggleFavicons,
            ),
          ),
          const Divider(),
          const _Section('Резервные копии'),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Экспорт хранилища'),
            subtitle: const Text('Зашифрованный файл с отдельным паролем'),
            onTap: _busy ? null : _export,
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Импорт хранилища'),
            subtitle: const Text('Заменит текущие данные'),
            onTap: _busy ? null : _import,
          ),
          const Divider(),
          const _Section('Опасная зона'),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text('Удалить все данные',
                style: TextStyle(color: scheme.error)),
            onTap: _busy ? null : _wipeAll,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;

  const _Section(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
