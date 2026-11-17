// Реальная сеть, ЗАВЕДОМО ФАЛЬШИВЫЕ ключи: ожидаем «недействителен».
// Запуск: TK_NETWORK_TESTS=1 flutter test test/token_check_network_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:token_keeper/token_check.dart';

void main() {
  final enabled = Platform.environment['TK_NETWORK_TESTS'] == '1';
  final cases = <(String, String)>[
    ('https://api.openai.com/v1', 'sk-tk-fake-0000000000000000000000'),
    ('https://api.deepseek.com/v1', 'sk-tk-fake-0000000000000000000000'),
    ('https://openrouter.ai/api/v1', 'sk-or-v1-0000000000000000000000000000'),
    ('https://api.groq.com', 'gsk_fake000000000000000000000000'),
    ('https://api.mistral.ai', 'fake0000000000000000000000000000'),
    ('https://api.x.ai/v1', 'xai-fake00000000000000000000000'),
    ('https://api.together.xyz', 'fake0000000000000000000000000000'),
    (
      'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
      'sk-fake000000000000000000000000',
    ),
    ('https://api.fireworks.ai', 'fw_fake000000000000000000000000'),
    ('https://api.perplexity.ai', 'pplx-fake0000000000000000000000'),
    ('https://console.anthropic.com', 'sk-ant-api03-fake000000000000000000'),
    ('https://aistudio.google.com', 'AIzaSyFake000000000000000000000000000'),
    ('https://github.com', 'ghp_fake000000000000000000000000000000'),
  ];
  for (final (url, key) in cases) {
    test(
      'fake key for $url -> invalid',
      () async {
        final client = http.Client();
        try {
          final p = Providers.detect(url: url);
          final r = await TokenChecker(client).check(p, key);
          // ignore: avoid_print
          print(
            '${p?.name.padRight(32)} ${p?.checkUrl.host.padRight(36)} '
            '-> ${r.status.name} (HTTP ${r.httpCode}) ${r.detail ?? ''}',
          );
          expect(r.status, CheckStatus.invalid);
        } finally {
          client.close();
        }
      },
      skip: enabled ? false : 'set TK_NETWORK_TESTS=1',
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  test('OpenRouter public /models parses into a model list', () async {
    final client = http.Client();
    try {
      final r = await TokenChecker(client)
          .models(Providers.openrouter, 'sk-or-v1-public-list-needs-no-key');
      // ignore: avoid_print
      print(
        'OpenRouter /models -> ${r.check.status.name}, ${r.models.length} models, '
        'e.g. ${r.models.take(3).map((m) => m.id).join(', ')}',
      );
      expect(r.check.isValid, isTrue);
      expect(r.models.length, greaterThan(50));
    } finally {
      client.close();
    }
  }, skip: enabled ? false : 'set TK_NETWORK_TESTS=1');
}
