import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:token_keeper/token_check.dart';

/// Opt-in: проверка настоящим ключом из файла (ключ не печатается).
/// TK_REAL_KEY_FILE=/path TK_REAL_URL=https://... flutter test test/real_key_network_test.dart
void main() {
  final file = Platform.environment['TK_REAL_KEY_FILE'];
  final url = Platform.environment['TK_REAL_URL'];
  final skip = (file == null || url == null)
      ? 'set TK_REAL_KEY_FILE and TK_REAL_URL'
      : false;

  test('real key via app checker', () async {
    final raw = File(file!).readAsStringSync();
    final token = raw.trim();
    final p = Providers.detect(url: url);
    // ignore: avoid_print
    print(
      'provider=${p?.id} base=${p?.base} check=${p?.checkUrl} '
      'keyLen=${token.length} rawLen=${raw.length}',
    );
    final client = http.Client();
    try {
      final r = await TokenChecker(client).check(p!, token);
      // ignore: avoid_print
      print('result=${r.status.name} http=${r.httpCode} detail=${r.detail}');
      expect(r.status, CheckStatus.valid);
    } finally {
      client.close();
    }
  }, skip: skip);

  test(
    'real key with paste garbage is cleaned by the app and accepted',
    () async {
      final k = File(file!).readAsStringSync().trim();
      final m = k.length ~/ 2;
      final dirty =
          '\uFEFF ${k.substring(0, m)} \u200B\u00A0\r\n${k.substring(m)}\n';
      final client = http.Client();
      try {
        final r = await TokenChecker(client)
            .check(Providers.detect(url: url), dirty);
        // ignore: avoid_print
        print('dirty -> ${r.status.name} http=${r.httpCode}');
        expect(r.status, CheckStatus.valid);
      } finally {
        client.close();
      }
    },
    skip: skip,
  );
}
