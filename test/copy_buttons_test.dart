import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:token_keeper/models.dart';
import 'package:token_keeper/screens/card_edit_screen.dart';
import 'package:token_keeper/screens/models_screen.dart';
import 'package:token_keeper/services.dart';

/// Кнопки «Копировать» в карточке и в списке моделей (0.3.1).
void main() {
  late List<String> clip; // история записей в буфер

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.load();
    clip = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clip.add((call.arguments as Map)['text'] as String);
          } else if (call.method == 'Clipboard.getData') {
            return {'text': clip.isEmpty ? null : clip.last};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpAt(WidgetTester t, Widget w, {double width = 320}) async {
    t.view.physicalSize = Size(width, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: w));
    await t.pump(const Duration(milliseconds: 100));
  }

  ServiceCard card({String token = 'sk-or-v1-0123456789abcdef'}) =>
      ServiceCard.create(
        name: 'OpenRouter',
        token: token,
        url: 'https://openrouter.ai/api/v1',
        colorIndex: 0,
      );

  Finder copyBtn() => find.byTooltip('Копировать');

  IconButton btn(WidgetTester t, int i) => t.widget<IconButton>(
    find.ancestor(of: copyBtn().at(i), matching: find.byType(IconButton)).first,
  );

  testWidgets('320 px: three copy buttons, eye stays, no overflow', (t) async {
    await pumpAt(t, CardEditScreen(existing: card()));
    expect(t.takeException(), isNull); // RenderFlex overflow был бы здесь
    expect(copyBtn(), findsNWidgets(3));
    expect(find.byTooltip('Показать'), findsOneWidget);

    // Кнопки не наезжают друг на друга и на текст токена.
    final eye = t.getRect(find.byTooltip('Показать'));
    final copyToken = t.getRect(copyBtn().at(1));
    expect(eye.overlaps(copyToken), isFalse);
    expect(eye.right <= copyToken.left, isTrue);
    final tokenText = t.getRect(find.byType(EditableText).at(1));
    expect(tokenText.right <= eye.left + 0.5, isTrue);
    for (var i = 0; i < 3; i++) {
      final f = find.byType(EditableText).at(i);
      expect(
        t.getRect(f).right <= t.getRect(copyBtn().at(i)).left + 0.5,
        isTrue,
        reason: 'field $i text overlaps its copy button',
      );
    }

    // Семантика.
    final h = t.ensureSemantics();
    await t.pump();
    for (var i = 0; i < 3; i++) {
      expect(
        t.getSemantics(copyBtn().at(i)),
        isSemantics(tooltip: 'Копировать', isButton: true),
      );
    }
    h.dispose();
  });

  testWidgets('copy name/url without auto-clear, token with 45 s auto-clear', (
    t,
  ) async {
    await pumpAt(t, CardEditScreen(existing: card()), width: 360);
    await t.tap(copyBtn().at(0));
    await t.pump();
    expect(clip.last, 'OpenRouter');
    expect(find.text('Скопировано'), findsOneWidget);

    await t.tap(copyBtn().at(2));
    await t.pump();
    expect(clip.last, 'https://openrouter.ai/api/v1');

    await t.tap(copyBtn().at(1));
    await t.pump();
    expect(clip.last, 'sk-or-v1-0123456789abcdef');
    final n = clip.length;
    await t.pump(const Duration(seconds: 44));
    expect(clip.length, n, reason: 'cleared too early');
    await t.pump(const Duration(seconds: 2));
    expect(clip.last, '', reason: 'token must be wiped after 45 s');
    await t.pump(const Duration(seconds: 3)); // SnackBar timers
  });

  testWidgets('copy disabled for empty field', (t) async {
    await pumpAt(t, const CardEditScreen());
    expect(copyBtn(), findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(btn(t, i).onPressed, isNull, reason: 'button $i');
    }
    await t.enterText(find.byType(TextField).at(1), 'tok');
    await t.pump();
    expect(btn(t, 1).onPressed, isNotNull);
    expect(btn(t, 0).onPressed, isNull);
  });

  testWidgets('models list: copy button per model id and tap-to-copy', (
    t,
  ) async {
    final c = card()
      ..models = ModelsCache(
        items: const [
          ModelInfo('openai/gpt-x-with-a-very-long-model-identifier-name'),
          ModelInfo('anthropic/claude-z'),
        ],
        fetchedAt: DateTime(2026, 11, 17, 11, 0),
      );
    await pumpAt(t, ModelsScreen(card: c));
    expect(t.takeException(), isNull);
    expect(copyBtn(), findsNWidgets(2));
    await t.tap(copyBtn().at(1));
    await t.pump();
    expect(clip.last, 'anthropic/claude-z');
    expect(find.text('Скопировано'), findsOneWidget);
    await t.tap(
      find.text('openai/gpt-x-with-a-very-long-model-identifier-name'),
    );
    await t.pump();
    expect(clip.last, 'openai/gpt-x-with-a-very-long-model-identifier-name');
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('pasting a token with spaces/zero-width keeps it clean', (
    t,
  ) async {
    await pumpAt(t, const CardEditScreen());
    await t.enterText(
      find.byType(TextField).at(1),
      ' sk-sp-ab.cd \u200Bef\u00A0gh\t ',
    );
    await t.pump();
    final tf = t.widget<TextField>(find.byType(TextField).at(1));
    expect(tf.controller!.text, 'sk-sp-ab.cdefgh');
    expect(find.text('Длина: 15 симв.'), findsOneWidget);
    expect(tf.autocorrect, isFalse);
    expect(tf.enableSuggestions, isFalse);
    expect(t.takeException(), isNull);
  });
}
