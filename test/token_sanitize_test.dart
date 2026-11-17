import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:token_keeper/token_check.dart';

/// 0.3.1: ключ формата Qwen Token Plan (113 символов, sk-sp-, с точками)
/// с мусором от вставки. Фейковый ключ; сервер-мок принимает только чистый.
void main() {
  // 113 символов: sk-sp- + три сегмента через точки, как у настоящего.
  final key =
      'sk-sp-${'A1b2C3d4E5' * 4}.${'f6G7h8I9j0' * 4}.${'kLmNoPqRsT' * 2}uv_-Q';
  const url =
      'https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1';

  test('fake key has the real key shape', () {
    expect(key.length, 113);
    expect(key.startsWith('sk-sp-'), isTrue);
    expect('.'.allMatches(key).length, 2);
  });

  late List<http.Request> seen;
  MockClient server() {
    seen = [];
    return MockClient((r) async {
      seen.add(r);
      if (r.headers['authorization'] == 'Bearer $key') {
        return http.Response(
          '{"object":"list","data":[{"id":"qwen3-max"}]}',
          200,
        );
      }
      return http.Response(
        '{"error":{"message":"Invalid API-key provided.","code":"invalid_api_key"}}',
        401,
      );
    });
  }

  test('detects custom provider and calls {url}/models with Bearer', () async {
    final p = Providers.detect(url: url)!;
    expect(p.id, 'custom');
    expect(p.checkUrl.toString(), '$url/models');
    final r = await TokenChecker(server()).check(p, key);
    expect(r.status, CheckStatus.valid);
    expect(seen.single.url.toString(), '$url/models');
    expect(seen.single.headers['authorization'], 'Bearer $key');
  });

  final m = key.length ~/ 2;
  String ins(String s) => key.substring(0, m) + s + key.substring(m);
  final dirty = <String, String>{
    'inner space (reproduces 401 before fix)': ins(' '),
    'inner tab': ins('\t'),
    'inner LF': ins('\n'),
    'inner CRLF': ins('\r\n'),
    'inner NBSP': ins('\u00A0'),
    'inner soft hyphen': ins('\u00AD'),
    'inner zero-width space': ins('\u200B'),
    'inner ZWJ/ZWNJ': ins('\u200C\u200D'),
    'word joiner': ins('\u2060'),
    'leading BOM': '\uFEFF$key',
    'trailing newline + spaces': '$key\n  ',
    'surrounding spaces': '  $key  ',
    'narrow nbsp + ideographic space': ins('\u202F\u3000'),
  };

  for (final e in dirty.entries) {
    test('pasted token with ${e.key} is cleaned and accepted', () async {
      expect(TokenText.sanitizeToken(e.value), key);
      final r = await TokenChecker(server())
          .check(Providers.detect(url: url), e.value);
      expect(r.status, CheckStatus.valid, reason: '${r.detail}');
      expect(seen.single.headers['authorization'], 'Bearer $key');
    });
  }

  test('URL with invisible chars and spaces is cleaned', () async {
    final p = Providers.detect(url: ' \u200B$url\uFEFF \n')!;
    expect(p.checkUrl.toString(), '$url/models');
  });

  test('really wrong key (truncated) is still invalid 401', () async {
    final r = await TokenChecker(server())
        .check(Providers.detect(url: url), key.substring(0, 112));
    expect(r.status, CheckStatus.invalid);
    expect(r.httpCode, 401);
  });

  test('non-ASCII in token: no request, no token in message', () async {
    final bad = ins('é');
    final r = await TokenChecker(server())
        .check(Providers.detect(url: url), bad);
    expect(r.status, CheckStatus.error);
    expect(seen, isEmpty);
    expect(r.detail, isNot(contains('A1b2')));
    expect(r.detail, contains('недопустимые'));
  });

  test('exception text with the header never reaches detail', () async {
    // Клиент, бросающий исключение с заголовком (как dart:io при плохом значении).
    final c = MockClient(
      (r) async => throw FormatException(
        'Invalid HTTP header field value: "Bearer $key"',
      ),
    );
    final r = await TokenChecker(c).check(Providers.detect(url: url), key);
    expect(r.status, CheckStatus.error);
    expect(r.detail ?? '', isNot(contains('A1b2')));
    expect(r.detail ?? '', isNot(contains('Bearer')));
  });

  test('models() also sanitizes the token', () async {
    final r = await TokenChecker(server())
        .models(Providers.detect(url: url), ins(' \u200B'));
    expect(r.check.status, CheckStatus.valid);
    expect(r.models.map((m) => m.id), ['qwen3-max']);
  });

  test('isHeaderSafe', () {
    expect(TokenText.isHeaderSafe(key), isTrue);
    expect(TokenText.isHeaderSafe(''), isFalse);
    expect(TokenText.isHeaderSafe('a b'), isFalse);
    expect(TokenText.isHeaderSafe('ключ'), isFalse);
  });
}
