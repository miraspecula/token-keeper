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

/// Дымовые тесты UI: экраны строятся без исключений (платформенные каналы
/// в тестовой среде отсутствуют — код обязан это переживать).
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.load();
  });

  Future<void> pump(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(home: w));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
  }

  testWidgets('setup screen builds', (t) => pump(t, const SetupScreen()));
  testWidgets('unlock screen builds', (t) => pump(t, const UnlockScreen()));
  testWidgets(
    'home screen builds while locked (no data)',
    (t) => pump(t, const HomeScreen()),
  );
  testWidgets('settings screen builds; favicons switch is OFF by default', (
    t,
  ) async {
    await pump(t, const SettingsScreen());
    expect(AppPrefs.faviconsEnabled.value, isFalse);
    await t.scrollUntilVisible(find.text('Загружать иконки сайтов'), 200);
    expect(find.text('Загружать иконки сайтов'), findsOneWidget);
  });
  testWidgets('favicon view shows a letter avatar when favicons are off', (
    t,
  ) async {
    final card = ServiceCard.create(
      name: 'github',
      token: 't',
      url: 'https://github.com',
      colorIndex: 3,
    );
    await pump(t, Scaffold(body: FaviconView(card: card)));
    expect(find.text('G'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('card edit shows provider hint and Проверить/Модели buttons', (
    t,
  ) async {
    final card = ServiceCard.create(
      name: 'DeepSeek',
      token: 't',
      url: 'https://api.deepseek.com/v1',
      colorIndex: 0,
    );
    await pump(t, CardEditScreen(existing: card));
    expect(find.text('Проверить'), findsOneWidget);
    expect(find.text('Модели'), findsOneWidget);
    expect(find.textContaining('Сервис: DeepSeek'), findsOneWidget);
  });
  testWidgets('models screen shows cached list with search, no network', (
    t,
  ) async {
    final card =
        ServiceCard.create(
            name: 'OpenAI',
            token: 't',
            url: 'https://api.openai.com/v1',
            colorIndex: 0,
          )
          ..models = ModelsCache(
            items: const [
              ModelInfo('gpt-x'),
              ModelInfo('o9-mini'),
              ModelInfo('whisper-1'),
            ],
            fetchedAt: DateTime(2026, 11, 17, 12, 0),
          );
    await pump(t, ModelsScreen(card: card));
    expect(find.text('gpt-x'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'o9');
    await t.pump();
    expect(find.text('o9-mini'), findsOneWidget);
    expect(find.text('gpt-x'), findsNothing);
    expect(find.textContaining('Обновлено 17.11.2026 12:00'), findsOneWidget);
  });
}
