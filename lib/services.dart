import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'container.dart';
import 'favicon_fetcher.dart';
import 'public_suffix.dart';
import 'crypto.dart';
import 'models.dart';
import 'platform_security.dart';
import 'store.dart';
import 'token_check.dart';
import 'vault_core.dart';

/// Настройки приложения, не являющиеся секретами.
class AppPrefs {
  static final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  static final lockMinutes = ValueNotifier<int>(1);
  static final secureScreen = ValueNotifier<bool>(true);
  static final biometryEnabled = ValueNotifier<bool>(false);
  static final faviconsEnabled = ValueNotifier<bool>(false);
  static final sortMode = ValueNotifier<SortMode>(SortMode.added);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    switch (p.getString('theme') ?? 'dark') {
      case 'light':
        themeMode.value = ThemeMode.light;
      case 'system':
        themeMode.value = ThemeMode.system;
      default:
        themeMode.value = ThemeMode.dark;
    }
    lockMinutes.value = (p.getInt('lockMinutes') ?? 1).clamp(0, 10);
    secureScreen.value = p.getBool('secureScreen') ?? true;
    biometryEnabled.value = p.getBool('biometry') ?? false;
    faviconsEnabled.value = p.getBool('favicons') ?? false;
    switch (p.getString('sortMode') ?? 'added') {
      case 'domain':
        sortMode.value = SortMode.domain;
      case 'name':
        sortMode.value = SortMode.name;
      case 'expiry':
        sortMode.value = SortMode.expiry;
      default:
        sortMode.value = SortMode.added;
    }
  }

  static Future<void> setTheme(ThemeMode m) async {
    themeMode.value = m;
    final p = await SharedPreferences.getInstance();
    await p.setString('theme', m.name);
  }

  /// 0..10 минут; 0 — блокировать сразу при уходе в фон.
  static Future<void> setLockMinutes(int v) async {
    final clamped = v.clamp(0, 10);
    lockMinutes.value = clamped;
    final p = await SharedPreferences.getInstance();
    await p.setInt('lockMinutes', clamped);
  }

  static Future<void> setSecureScreen(bool v) async {
    secureScreen.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('secureScreen', v);
  }

  static Future<void> setBiometry(bool v) async {
    biometryEnabled.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('biometry', v);
  }

  static Future<void> setFavicons(bool v) async {
    faviconsEnabled.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('favicons', v);
  }

  static Future<void> setSortMode(SortMode m) async {
    sortMode.value = m;
    final p = await SharedPreferences.getInstance();
    await p.setString('sortMode', m.name);
  }
}

/// Подавление автоблокировки на время внешних активностей
/// (выбор файла, системный шаринг, диалог биометрии): пока счётчик > 0,
/// мгновенная блокировка (lockMinutes == 0) не срабатывает.
class AutoLock {
  static int _suspend = 0;

  static bool get suspended => _suspend > 0;

  static Future<T> suspendWhile<T>(Future<T> Function() f) async {
    _suspend++;
    try {
      return await f();
    } finally {
      _suspend--;
    }
  }
}

/// Расшифрованное состояние в памяти: контейнер, DEK и данные.
/// Живёт до блокировки (autolock или ручной выход). Ключ нигде не кэшируется
/// в открытом виде; для биометрии он хранится только в Android Keystore
/// через PlatformSecurity.
class SessionVault {
  SessionVault._();
  static final instance = SessionVault._();

  VaultContainer? container;
  Uint8List? dek;
  VaultData? data;

  final ValueNotifier<bool> lockedNotifier = ValueNotifier<bool>(true);

  /// Последний вход по паролю мигрировал хранилище v1 -> v2.
  /// UI показывает уведомление и сбрасывает флаг.
  bool lastUnlockMigrated = false;

  bool get unlocked => dek != null;

  /// Растёт при каждой блокировке: результаты сетевых запросов, начатых
  /// до блокировки, отбрасываются.
  int lockEpoch = 0;

  void lock() {
    lockEpoch++;
    TokenService.cancelAll(); // обрываем незавершённые проверки токенов
    wipeBytes(dek);
    dek = null;
    // Строки Dart (токены) иммутабельны и не могут быть обнулены вручную:
    // после удаления ссылок они становятся недостижимыми и собираются GC.
    data = null;
    lockedNotifier.value = true;
  }

  /// Создаёт новое хранилище (Argon2id + свежий случайный DEK).
  Future<void> setupNewVault(String password) async {
    final opened = await _Heavy.create(password);
    await VaultStore.save(opened.container);
    container = opened.container;
    dek = opened.dek;
    data = opened.data;
    lastUnlockMigrated = false;
    lockedNotifier.value = false;
  }

  /// Вход по мастер-паролю. Неверный пароль / повреждение -> исключение.
  Future<void> unlockWithPassword(String password) async {
    final c = await VaultStore.load();
    final opened = await _Heavy.unlock(c, password);
    if (opened.migrated) {
      await VaultStore.save(opened.container);
      await PlatformSecurity.clearBiometric();
      await AppPrefs.setBiometry(false);
      lastUnlockMigrated = true;
    } else {
      lastUnlockMigrated = false;
    }
    container = opened.container;
    dek = opened.dek;
    data = opened.data;
    lockedNotifier.value = false;
  }

  /// Вход по биометрии: DEK выдаёт Android Keystore после BIOMETRIC_STRONG.
  Future<BioResult> unlockWithBiometry() async {
    if (!AppPrefs.biometryEnabled.value) return BioResult.unavailable;
    final res = await PlatformSecurity.unlockBiometric();
    switch (res.result) {
      case BioResult.invalidated:
      case BioResult.noData:
        await PlatformSecurity.clearBiometric();
        await AppPrefs.setBiometry(false);
        return res.result;
      case BioResult.success:
        break;
      case BioResult.cancelled:
      case BioResult.unavailable:
      case BioResult.error:
        return res.result;
    }
    final key = res.dek;
    if (key == null) {
      await PlatformSecurity.clearBiometric();
      await AppPrefs.setBiometry(false);
      return BioResult.error;
    }
    try {
      final c = await VaultStore.load();
      // AES-GCM расшифровка быстрая — изолят не нужен.
      final d = c.openData(key);
      container = c;
      dek = key;
      data = d;
      lastUnlockMigrated = false;
      lockedNotifier.value = false;
      return BioResult.success;
    } catch (_) {
      wipeBytes(key);
      await PlatformSecurity.clearBiometric();
      await AppPrefs.setBiometry(false);
      return BioResult.error;
    }
  }

  /// Включает биометрию для текущего разблокированного хранилища.
  Future<BioResult> enableBiometry() async {
    final k = dek;
    if (k == null) return BioResult.unavailable;
    // Плагин обнуляет переданный буфер — отдаём копию.
    final result =
        await PlatformSecurity.enrollBiometric(Uint8List.fromList(k));
    if (result == BioResult.success) {
      await AppPrefs.setBiometry(true);
    }
    return result;
  }

  Future<void> disableBiometry() async {
    await PlatformSecurity.clearBiometric();
    await AppPrefs.setBiometry(false);
  }

  /// Сохраняет изменения: пересоздаёт data-blob (свежий nonce) и пишет файл.
  Future<void> persist() async {
    final d = data;
    final c = container;
    final k = dek;
    if (d == null || c == null || k == null) return;
    d.updatedAt = DateTime.now();
    final nc = VaultCore.seal(c, k, d);
    container = nc;
    await VaultStore.save(nc);
  }

  /// Смена мастер-пароля: проверяет старый пароль и перевыпускает DEK.
  /// Биометрический кэш старого ключа удаляется — нужно включить заново.
  Future<void> changePassword(String oldPassword, String newPassword) async {
    final c = container;
    if (c == null || dek == null) {
      throw StateError('Хранилище заблокировано');
    }
    final opened = await _Heavy.changePassword(c, oldPassword, newPassword);
    await VaultStore.save(opened.container);
    if (dek == null) {
      // Пока считался KDF, приложение успело заблокироваться: файл уже
      // перешифрован новым паролем, но в память ключ не возвращаем.
      wipeBytes(opened.dek);
      await PlatformSecurity.clearBiometric();
      await AppPrefs.setBiometry(false);
      return;
    }
    wipeBytes(dek);
    container = opened.container;
    dek = opened.dek;
    data = opened.data;
    await PlatformSecurity.clearBiometric();
    await AppPrefs.setBiometry(false);
  }

  /// Экспорт: отдельный контейнер kind=export со своим случайным DEK.
  Future<String> exportToString(String exportPassword) async {
    final d = data;
    if (d == null) throw StateError('Хранилище заблокировано');
    return _Heavy.export(d, exportPassword);
  }

  /// Импорт: заменяет текущие данные расшифрованными из файла экспорта,
  /// затем перешифровывает их под ЛОКАЛЬНЫМ DEK со свежим nonce.
  Future<void> importAndReplace(String jsonText, String password) async {
    final imported = await _Heavy.import(jsonText, password);
    final c = container;
    final k = dek;
    if (c == null || k == null) throw StateError('Хранилище заблокировано');
    imported.updatedAt = DateTime.now();
    // Сначала шифруем и пишем на диск, потом подменяем данные в памяти:
    // при ошибке записи текущее хранилище остаётся нетронутым.
    final nc = VaultCore.seal(c, k, imported);
    await VaultStore.save(nc);
    container = nc;
    data = imported;
    await PlatformSecurity.clearBiometric();
    await AppPrefs.setBiometry(false);
  }

  /// Полное удаление: файл, биометрический ключ, кэш иконок, память.
  Future<void> wipeAll() async {
    await VaultStore.delete();
    await PlatformSecurity.clearBiometric();
    await AppPrefs.setBiometry(false);
    await FaviconService.clearCache();
    lock();
  }
}

/// Тяжёлые операции (Argon2id) в отдельном изоляте. Статические функции,
/// чтобы замыкание Isolate.run не захватывало `this` и UI-объекты.
class _Heavy {
  static Future<OpenedVault> create(String pw) =>
      Isolate.run(() => VaultCore.create(pw, VaultData.empty()));
  static Future<OpenedVault> unlock(VaultContainer c, String pw) =>
      Isolate.run(() => VaultCore.unlock(c, pw));
  static Future<OpenedVault> changePassword(
          VaultContainer c, String oldPw, String newPw) =>
      Isolate.run(() => VaultCore.changePassword(c, oldPw, newPw));
  static Future<String> export(VaultData d, String pw) =>
      Isolate.run(() => VaultCore.exportVault(d, pw));
  static Future<VaultData> import(String json, String pw) =>
      Isolate.run(() => VaultCore.importExport(json, pw));
}

/// Копирование токена с автоочисткой буфера обмена.
class ClipboardService {
  static Timer? _timer;
  static String? _lastCopied;

  static void copyToken(String token,
      {Duration ttl = const Duration(seconds: 45)}) {
    Clipboard.setData(ClipboardData(text: token));
    _lastCopied = token;
    _timer?.cancel();
    _timer = Timer(ttl, () async {
      try {
        final current = await Clipboard.getData('text/plain');
        if (current?.text == _lastCopied) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
        _lastCopied = null;
      } catch (_) {}
    });
  }
}

/// Шаринг одного токена (полный экспорт — только через настройки).
class ShareService {
  static Future<void> shareToken(ServiceCard c) async {
    final buf = StringBuffer()
      ..writeln(c.name.isEmpty ? 'Token' : c.name)
      ..writeln();
    final domain = c.domain;
    if (domain != null) buf.writeln('Сервис: $domain');
    buf.writeln('Токен: ${c.token}');
    if (c.expiry != null) {
      final e = c.expiry!;
      buf.writeln(
          'Истекает: ${e.day.toString().padLeft(2, '0')}.${e.month.toString().padLeft(2, '0')}.${e.year}');
    }
    await AutoLock.suspendWhile(() =>
        SharePlus.instance.share(ShareParams(text: buf.toString())));
  }
}

/// Палитра из 16 оттенков: соседние карточки не получают близкие цвета.
class ColorPalette {
  static const int size = 16;
  static const double _goldenAngle = 137.508;

  static Color colorFor(int index) {
    final hue = (index * _goldenAngle) % 360;
    return HSLColor.fromAHSL(1.0, hue, 0.55, 0.52).toColor();
  }

  /// Выбирает индекс, максимально удалённый по оттенку от уже используемых.
  static int pickIndex(Iterable<ServiceCard> cards) {
    final used = cards.map((c) => (c.colorIndex * _goldenAngle) % 360).toList();
    int best = 0;
    double bestDist = -1;
    for (int i = 0; i < size; i++) {
      final hue = (i * _goldenAngle) % 360;
      double minD = 360;
      for (final h in used) {
        final d = _hueDist(hue, h);
        if (d < minD) minD = d;
      }
      if (minD > bestDist) {
        bestDist = minD;
        best = i;
      }
    }
    return best;
  }

  static double _hueDist(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }
}

/// Загрузка и кэширование favicon с сайта сервиса.
/// По умолчанию выключено (приватность): при выключенном флаге нет ни сети,
/// ни обращений к диску. Все запросы — только по https. Поиск: корневой
/// домен (eTLD+1 по вшитому Public Suffix List) → www.корень → исходный хост.
class FaviconService {
  static PublicSuffixList? _psl;
  static final Set<String> _failedThisSession = {};

  /// Список публичных суффиксов из ассета (без сети), грузится один раз.
  static Future<PublicSuffixList> psl() async => _psl ??=
      PublicSuffixList.parse(
          await rootBundle.loadString('assets/public_suffix_list.dat'));

  static Future<Directory> _dir({bool create = true}) async {
    final d = await getApplicationDocumentsDirectory();
    final dir = Directory('${d.path}/favicons');
    if (create && !dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Имя файла кэша — hex SHA-256 домена (без раскрытия домена в имени файла).
  static String _key(String domain) {
    final digest = SHA256Digest().process(utf8.encode(domain));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Возвращает кэшированный файл (PNG или SVG), при отсутствии скачивает.
  /// Null сразу, если иконки выключены в настройках. Неудачный поиск
  /// запоминается до перезапуска, чтобы список не ходил в сеть на каждой
  /// перерисовке; [force] (кнопка «Загрузить») это игнорирует.
  static Future<File?> ensureCached(String domain, String? url,
      {bool force = false}) async {
    if (!AppPrefs.faviconsEnabled.value) return null;
    final dir = await _dir();
    final f = File('${dir.path}/${_key(domain)}');
    if (!force && f.existsSync()) return f;
    if (!force && _failedThisSession.contains(domain)) return null;
    final client = http.Client();
    try {
      final fetcher = FaviconFetcher(client, await psl());
      final icon = await fetcher.fetch(
          (url != null && url.trim().isNotEmpty) ? url : domain);
      if (icon == null) {
        _failedThisSession.add(domain);
        return f.existsSync() ? f : null;
      }
      _failedThisSession.remove(domain);
      await f.writeAsBytes(icon.bytes, flush: true);
      PaintingBinding.instance.imageCache.clear(); // сбросить старую картинку
      return f;
    } catch (_) {
      _failedThisSession.add(domain);
      return null;
    } finally {
      client.close();
    }
  }

  /// SVG или растр (PNG) — по первым байтам файла кэша.
  static bool isSvgFile(File f) {
    try {
      final raf = f.openSync();
      try {
        final head = utf8
            .decode(raf.readSync(512), allowMalformed: true)
            .trimLeft()
            .toLowerCase();
        return head.startsWith('<svg') ||
            head.startsWith('<?xml') ||
            head.startsWith('<!--');
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// Фоновая загрузка при сохранении карточки (не блокирует UI).
  static void prefetch(String? domain, String? url) {
    if (domain == null || !AppPrefs.faviconsEnabled.value) return;
    unawaited(ensureCached(domain, url));
  }

  static Future<void> clearCache() async {
    _failedThisSession.clear();
    try {
      final dir = await _dir(create: false);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Проверка токенов и списки моделей. Сеть — только по явному действию
/// пользователя (кнопки «Проверить», «Модели», сохранение карточки);
/// фоновых запросов нет. При блокировке все запросы обрываются, а их
/// результаты отбрасываются (возвращается null).
class TokenService {
  static final Set<http.Client> _active = {};

  static void cancelAll() {
    for (final c in _active.toList()) {
      c.close();
    }
    _active.clear();
  }

  static Future<T?> _guarded<T>(Future<T> Function(TokenChecker) run) async {
    final vault = SessionVault.instance;
    if (!vault.unlocked) return null;
    final epoch = vault.lockEpoch;
    final client = http.Client();
    _active.add(client);
    try {
      final r = await run(TokenChecker(client));
      if (!vault.unlocked || vault.lockEpoch != epoch) return null;
      return r;
    } catch (_) {
      return null;
    } finally {
      _active.remove(client);
      client.close();
    }
  }

  /// Проверка токена (значения ещё не сохранённой формы тоже подходят).
  static Future<CheckResult?> check(
          {String? url, String? name, required String token}) =>
      _guarded((c) => c.check(Providers.detect(url: url, name: name), token));

  /// Загружает модели и сохраняет их в карточку (в зашифрованное хранилище).
  static Future<ModelsResult?> refreshModels(ServiceCard card) async {
    final provider = Providers.detect(url: card.url, name: card.name);
    final epoch = SessionVault.instance.lockEpoch;
    final r = await _guarded((c) => c.models(provider, card.token));
    if (r == null || !r.check.isValid) return r;
    final vault = SessionVault.instance;
    if (!vault.unlocked || vault.lockEpoch != epoch) return null;
    final inVault = vault.data?.cards.where((c) => c.id == card.id);
    if (inVault == null || inVault.isEmpty) return r;
    final target = inVault.first;
    final prev = target.models;
    target.models = ModelsCache(
        items: r.models, fetchedAt: DateTime.now(), providerId: provider?.id);
    try {
      await vault.persist();
    } catch (_) {
      target.models = prev;
      rethrow;
    }
    return r;
  }
}
