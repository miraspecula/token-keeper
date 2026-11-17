// Скриншоты для RuStore: настоящие экраны приложения, отрисованные движком
// Flutter в тесте (эмулятора нет). Шрифты Roboto и Material Icons из SDK,
// иконки сервисов — локальные PNG (без сети), HTTP проверки — мок.
// Только демо-данные (sk-demo-…), никаких настоящих ключей.
//
//   TK_SCREENSHOTS=1 flutter test test/screenshots/store_screenshots_test.dart
//   (TK_SCREENSHOTS_OUT=<папка>, по умолчанию ../out/screenshots)
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:token_keeper/main.dart';
import 'package:token_keeper/models.dart';
import 'package:token_keeper/screens/card_edit_screen.dart';
import 'package:token_keeper/screens/home_screen.dart';
import 'package:token_keeper/screens/unlock_screen.dart';
import 'package:token_keeper/services.dart';
import 'package:token_keeper/widgets.dart';

final _enabled = Platform.environment['TK_SCREENSHOTS'] == '1';
final _outDir =
    Platform.environment['TK_SCREENSHOTS_OUT'] ??
    '${Directory.current.path}/../out/screenshots';
final _dark = Platform.environment['TK_SCREENSHOTS_DARK'] == '1';

const _sdkFonts = 'bin/cache/artifacts/material_fonts';

String _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null) return env;
  return '/home/box/tools/flutter';
}

Future<void> _loadFonts() async {
  final dir = '${_flutterRoot()}/$_sdkFonts';
  Future<ByteData> f(String n) async =>
      ByteData.sublistView(await File('$dir/$n').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final n in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Light.ttf',
    'Roboto-Italic.ttf',
  ]) {
    roboto.addFont(f(n));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(f('MaterialIcons-Regular.otf'));
  await icons.load();
}

String _sha(String s) => SHA256Digest()
    .process(utf8.encode(s))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Демо-ключ заведомо фейкового вида.
String _demo(String prefix, int seed, int len) {
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  final b = StringBuffer('${prefix}demo-');
  var x = seed * 7919 + 17;
  while (b.length < len) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    b.write(abc[x % abc.length]);
  }
  return b.toString();
}

ModelsCache _openAiModels() => ModelsCache(
  items: const [
    ModelInfo('gpt-4.1', owner: 'openai'),
    ModelInfo('gpt-4.1-mini', owner: 'openai'),
    ModelInfo('gpt-4.1-nano', owner: 'openai'),
    ModelInfo('gpt-4o', owner: 'openai'),
    ModelInfo('gpt-4o-mini', owner: 'openai'),
    ModelInfo('gpt-4o-mini-tts', owner: 'openai'),
    ModelInfo('gpt-4o-transcribe', owner: 'openai'),
    ModelInfo('gpt-image-1', owner: 'openai'),
    ModelInfo('o3', owner: 'openai'),
    ModelInfo('o3-mini', owner: 'openai'),
    ModelInfo('o4-mini', owner: 'openai'),
    ModelInfo('text-embedding-3-large', owner: 'openai'),
    ModelInfo('text-embedding-3-small', owner: 'openai'),
    ModelInfo('whisper-1', owner: 'openai-internal'),
  ],
  fetchedAt: DateTime(2026, 11, 17, 13, 42),
  providerId: 'openai',
);

/// (иконка, карточка). Даты фиксированы относительно «сегодня».
List<(String, ServiceCard)> _cards() {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day);
  ServiceCard c(
    String name,
    String token,
    String url,
    int color,
    int ageDays, {
    DateTime? expiry,
    ModelsCache? models,
  }) => ServiceCard(
    id: 'demo-$name',
    name: name,
    token: token,
    url: url,
    expiry: expiry,
    colorIndex: color,
    createdAt: now.subtract(Duration(days: ageDays)),
    updatedAt: now.subtract(Duration(days: ageDays)),
    models: models,
  );
  return [
    (
      'openai',
      c(
        'OpenAI',
        _demo('sk-proj-', 1, 64),
        'https://api.openai.com/v1',
        0,
        1,
        models: _openAiModels(),
      ),
    ),
    (
      'deepseek',
      c(
        'DeepSeek',
        _demo('sk-', 2, 40),
        'https://api.deepseek.com/v1',
        1,
        2,
        expiry: d.add(const Duration(days: 5)),
      ),
    ),
    (
      'qwen',
      c(
        'Qwen',
        _demo('sk-', 3, 48),
        'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
        2,
        3,
      ),
    ),
    (
      'anthropic',
      c(
        'Anthropic',
        _demo('sk-ant-', 4, 72),
        'https://api.anthropic.com/v1',
        3,
        4,
      ),
    ),
    (
      'gemini',
      c('Gemini', _demo('AIza-', 5, 39), 'https://aistudio.google.com', 4, 5),
    ),
    (
      'openrouter',
      c(
        'OpenRouter',
        _demo('sk-or-v1-', 6, 73),
        'https://openrouter.ai/api/v1',
        5,
        6,
      ),
    ),
    (
      'github',
      c('GitHub', _demo('ghp_', 7, 40), 'https://api.github.com', 6, 0),
    ),
  ];
}

void main() {
  late Directory docs;
  late List<(String, ServiceCard)> demo;

  setUpAll(() async {
    if (!_enabled) return;
    await _loadFonts();
    Directory(_outDir).createSync(recursive: true);
  });

  setUp(() async {
    if (!_enabled) return;
    docs = Directory.systemTemp.createTempSync('tk_shots_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => docs.path,
      )
      ..setMockMethodCallHandler(SystemChannels.platform, (call) async => null)
      ..setMockMethodCallHandler(const MethodChannel('token_keeper/security'), (
        call,
      ) async {
        if (call.method == 'isBiometricAvailable') return true;
        if (call.method == 'unlockBiometric') return {'result': 'cancelled'};
        return null;
      });
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.load();
    AppPrefs.themeMode.value = _dark ? ThemeMode.dark : ThemeMode.light;
    AppPrefs.faviconsEnabled.value = true;
    AppPrefs.biometryEnabled.value = false;
    // Иконки сервисов: кладём в кэш favicon так же, как это делает приложение
    // после загрузки (имя файла — SHA-256 домена).
    demo = _cards();
    final fav = Directory('${docs.path}/favicons')..createSync();
    for (final (icon, card) in demo) {
      File('test/screenshots/icons/$icon.png')
          .copySync('${fav.path}/${_sha(card.domain!)}');
    }
    final v = SessionVault.instance;
    v.data = VaultData(
      cards: [for (final e in demo) e.$2],
      updatedAt: DateTime.now(),
    );
    v.dek = Uint8List(
      32,
    ); // «разблокировано» без KDF; persist() без container — no-op
    v.lockedNotifier.value = false;
  });

  tearDown(() {
    if (!_enabled) return;
    SessionVault.instance.lock();
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> setView(WidgetTester t) async {
    // В тестах тени по умолчанию рисуются чёрной рамкой — включаем настоящие.
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    t.view.physicalSize = const Size(1080, 1920);
    // 1080×1920 (9:16) при плотности 2.625 (xxhdpi-класс) → 411×731 dp,
    // как у типичного Android-телефона; сверху — место под статус-бар,
    // снизу — под жестовую навигацию.
    t.view.devicePixelRatio = 2.625;
    t.view.padding = const FakeViewPadding(top: 24 * 2.625, bottom: 16 * 2.625);
    t.view.viewPadding = const FakeViewPadding(
      top: 24 * 2.625,
      bottom: 16 * 2.625,
    );
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    t.platformDispatcher.platformBrightnessTestValue = _dark
        ? Brightness.dark
        : Brightness.light;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  /// Даём завершиться настоящему вводу-выводу (файлы иконок) и декодированию.
  Future<void> settle(WidgetTester t) async {
    // Файлы и декодирование картинок идут в реальном цикле событий, а
    // уведомления — в фейковом времени теста: чередуем одно и другое.
    for (var i = 0; i < 8; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    final errors = t.takeException();
    expect(errors, isNull, reason: 'исключение/overflow на $name');
    final element = t.element(find.byType(MaterialApp));
    final bytes = await t.runAsync(() async {
      final image = await captureImage(element);
      expect(image.width, 1080);
      expect(image.height, 1920);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    File('$_outDir/$name').writeAsBytesSync(bytes!);
    // ignore: avoid_print
    print('$name: ${bytes.length} B');
  }

  Future<void> boot(WidgetTester t, Widget screen) async {
    await setView(t);
    await t.pumpWidget(const TokenKeeperApp());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
    PageRouteBuilder<void> route(Widget w) => PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => w,
      transitionDuration: Duration.zero,
    );
    // Экран открывается поверх списка карточек, как в приложении
    // (у вложенных экранов есть стрелка «назад»).
    final nested = screen is! UnlockScreen && screen is! HomeScreen;
    final root = nested ? const HomeScreen() : screen;
    navigatorKey.currentState!.pushAndRemoveUntil(route(root), (_) => false);
    if (nested) {
      await t.pump();
      navigatorKey.currentState!.push(route(screen));
    }
    await t.pump();
    await settle(t);
  }

  ServiceCard card(String name) => demo.firstWhere((e) => e.$2.name == name).$2;

  final skip = !_enabled;
  const to = Timeout(Duration(seconds: 90)); // включается TK_SCREENSHOTS=1

  testWidgets(
    '01_login',
    (t) async {
      AppPrefs.biometryEnabled.value =
          true; // кнопка биометрии; запрос — «отмена»
      await boot(t, const UnlockScreen());
      await t.enterText(find.byType(TextField).first, 'demo-password');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      await shot(t, '01_login.png');
    },
    skip: skip,
    timeout: to,
  );

  testWidgets(
    '02_cards',
    (t) async {
      await boot(t, const HomeScreen());
      // Прокручено до конца: видно, что «+» не закрывает последнюю карточку.
      // GitHub — самая новая карточка, она уходит за верх; верхняя видимая
      // карточка выравнивается по краю списка, чтобы не была обрезана.
      await t.drag(find.byType(ListView), const Offset(0, -3000));
      await t.pumpAndSettle();
      final listTop = t.getRect(find.byType(ListView)).top;
      final tops = [
        for (final e in find.byType(ServiceTile).evaluate())
          t.getRect(find.byWidget(e.widget)),
      ].where((r) => r.bottom > listTop);
      final firstVisible = tops.first;
      if (firstVisible.top < listTop) {
        final pos = t
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(ListView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        pos.jumpTo(pos.pixels - (listTop - firstVisible.top));
        await t.pump();
      }
      final fab = t.getRect(find.byType(FloatingActionButton));
      final last = find.byType(ServiceTile).last;
      for (final b
          in find
              .descendant(of: last, matching: find.byType(IconButton))
              .evaluate()) {
        expect(t.getRect(find.byWidget(b.widget)).overlaps(fab), isFalse);
      }
      await settle(t);
      await shot(t, '02_cards.png');
    },
    skip: skip,
    timeout: to,
  );

  testWidgets(
    '03_edit + 06_copied',
    (t) async {
      await boot(t, CardEditScreen(existing: card('OpenAI')));
      await shot(t, '03_edit.png');
      await t.tap(find.byTooltip('Копировать').at(1));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await shot(t, '06_copied.png');
      await t.pump(const Duration(seconds: 50)); // таймер автоочистки
    },
    skip: skip,
    timeout: to,
  );

  testWidgets(
    '04_check',
    (t) async {
      final mock = MockClient((r) async {
        expect(r.url.host, 'api.deepseek.com');
        return http.Response(
          '{"object":"list","data":[{"id":"deepseek-chat","object":"model",'
          '"owned_by":"deepseek"},{"id":"deepseek-reasoner","object":"model",'
          '"owned_by":"deepseek"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      await http.runWithClient(() async {
        await boot(t, CardEditScreen(existing: card('DeepSeek')));
        await t.tap(find.text('Проверить'));
        await t.pump();
        await settle(t);
      }, () => mock);
      expect(find.textContaining('Токен действителен'), findsOneWidget);
      await shot(t, '04_check.png');
    },
    skip: skip,
    timeout: to,
  );

  testWidgets(
    '05_models',
    (t) async {
      await boot(t, CardEditScreen(existing: card('OpenAI')));
      await t.tap(find.text('Модели'));
      await t.pump();
      await settle(t);
      await t.enterText(find.byType(TextField).first, 'gpt-4');
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t);
      await shot(t, '05_models.png');
    },
    skip: skip,
    timeout: to,
  );
}
