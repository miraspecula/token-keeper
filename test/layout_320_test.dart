
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:token_keeper/models.dart';
import 'package:token_keeper/screens/card_edit_screen.dart';
import 'package:token_keeper/screens/home_screen.dart';
import 'package:token_keeper/screens/models_screen.dart';
import 'package:token_keeper/screens/settings_screen.dart';
import 'package:token_keeper/screens/setup_screen.dart';
import 'package:token_keeper/screens/unlock_screen.dart';
import 'package:token_keeper/services.dart';
import 'package:token_keeper/widgets.dart';

import 'support/fonts.dart';

/// 0.3.2: экраны на узком телефоне (320 dp) — без переполнений и обрезанных
/// подписей; кнопка «+» не закрывает действия последней карточки.
void main() {
  setUpAll(loadRealFonts);

  late List<ServiceCard> cards;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.load();
    final now = DateTime.now();
    cards = [
      for (var i = 0; i < 12; i++)
        ServiceCard(
          id: 'c$i',
          // Имена — обычной длины: длинные пользовательские данные (имя,
          // домен) по задумке обрезаются «…», проверяем только подписи UI.
          name: i == 0 ? 'OpenAI' : 'Сервис $i',
          token: 'sk-demo-${'x' * 30}$i',
          url: i == 0
              ? 'https://api.openai.com/v1'
              : (i.isEven ? 'https://api.service$i.example.com/v1' : null),
          expiry: i == 1 ? now.add(const Duration(days: 3)) : null,
          colorIndex: i,
          createdAt: now.subtract(Duration(days: i)),
          updatedAt: now,
        ),
    ];
    final v = SessionVault.instance;
    v.data = VaultData(cards: cards, updatedAt: now);
    v.dek = Uint8List(32);
  });

  tearDown(() => SessionVault.instance.lock());

  Future<void> pumpAt(
    WidgetTester t,
    Widget w, {
    double width = 320,
    double height = 640,
    double bottomInset = 0,
  }) async {
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = Size(width * 3, height * 3);
    t.view.padding = FakeViewPadding(bottom: bottomInset * 3);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: w));
    await t.pump(const Duration(milliseconds: 100));
  }

  /// Все абзацы текста, не поместившиеся в отведённые строки (обрезка «…»).
  List<String> truncated(WidgetTester t) {
    final out = <String>[];
    void visit(RenderObject r) {
      if (r is RenderParagraph && r.didExceedMaxLines) {
        out.add(r.text.toPlainText());
      }
      r.visitChildren(visit);
    }

    visit(t.binding.renderViews.first);
    return out;
  }

  void expectClean(WidgetTester t, String screen) {
    expect(t.takeException(), isNull, reason: '$screen: исключение/overflow');
    expect(truncated(t), isEmpty, reason: '$screen: обрезанный текст');
  }

  final screens = <String, Widget Function(List<ServiceCard>)>{
    'setup': (_) => const SetupScreen(),
    'unlock': (_) => const UnlockScreen(),
    'home': (_) => const HomeScreen(),
    'settings': (_) => const SettingsScreen(),
    'card new': (_) => const CardEditScreen(),
    'card existing': (c) => CardEditScreen(existing: c[0]),
    'card custom url': (c) => CardEditScreen(
      existing: c[2]
        ..url = 'https://llm-gateway.internal-company.example.org/openai/v1',
    ),
    'models': (c) => ModelsScreen(
      card: c[0]
        ..models = ModelsCache(
          items: [
            for (var i = 0; i < 30; i++)
              ModelInfo('provider/model-$i', owner: 'demo'),
          ],
          fetchedAt: DateTime(2026, 11, 17, 14, 0),
        ),
    ),
  };

  for (final e in screens.entries) {
    testWidgets('320 dp: ${e.key} — no overflow, no truncated labels', (
      t,
    ) async {
      await pumpAt(t, e.value(cards));
      expectClean(t, e.key);
    });
  }

  testWidgets('320 dp: search hint is fully visible', (t) async {
    await pumpAt(t, const HomeScreen());
    expect(find.text('Поиск'), findsOneWidget);
    expectClean(t, 'home');
  });

  for (final inset in [0.0, 24.0]) {
    testWidgets('FAB does not cover last card actions (bottom inset $inset)', (
      t,
    ) async {
      await pumpAt(t, const HomeScreen(), bottomInset: inset);
      await t.drag(find.byType(ListView), const Offset(0, -10000));
      await t.pumpAndSettle();
      expectClean(t, 'home scrolled');
      final fab = t.getRect(find.byType(FloatingActionButton));
      final last = find.byType(ServiceTile).last;
      // Последняя карточка в данных — та, что внизу списка после сортировки.
      final tile = t.widget<ServiceTile>(last);
      expect(tile.card.id, 'c11');
      final buttons = find.descendant(
        of: last,
        matching: find.byType(IconButton),
      );
      expect(buttons, findsWidgets);
      for (final b in buttons.evaluate()) {
        final r = t.getRect(find.byWidget(b.widget));
        expect(
          r.overlaps(fab),
          isFalse,
          reason: 'кнопка карточки $r под FAB $fab',
        );
      }
      expect(
        t.getRect(last).bottom <= fab.top,
        isTrue,
        reason: 'последняя карточка заходит под FAB',
      );
    });
  }
}
