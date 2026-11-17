import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:token_keeper/crypto.dart';
import 'package:token_keeper/container.dart';
import 'package:token_keeper/models.dart';
import 'package:token_keeper/token_check.dart';
import 'package:token_keeper/vault_core.dart';

const token = 'sk-test-SECRET-1234567890abcdef';

/// Тело успешного ответа «список моделей» в формате провайдера.
String okBody(ProviderKind k) => switch (k) {
  ProviderKind.gemini => jsonEncode({
    'models': [
      {
        'name': 'models/gemini-2.5-pro',
        'displayName': 'Gemini 2.5 Pro',
        'inputTokenLimit': 1048576,
      },
      {'name': 'models/gemini-2.5-flash', 'displayName': 'Gemini 2.5 Flash'},
    ],
  }),
  ProviderKind.anthropic => jsonEncode({
    'data': [
      {'id': 'claude-opus-4', 'display_name': 'Claude Opus 4', 'type': 'model'},
      {
        'id': 'claude-sonnet-4',
        'display_name': 'Claude Sonnet 4',
        'type': 'model',
      },
    ],
    'has_more': false,
    'last_id': 'claude-sonnet-4',
  }),
  ProviderKind.github => jsonEncode({'login': 'octocat', 'id': 1}),
  ProviderKind.openAiCompatible => jsonEncode({
    'object': 'list',
    'data': [
      {'id': 'model-b', 'object': 'model', 'owned_by': 'org'},
      {'id': 'model-a', 'object': 'model', 'owned_by': 'org'},
    ],
  }),
};

TokenChecker checkerReturning(
  int status,
  String body, {
  List<http.BaseRequest>? log,
}) {
  return TokenChecker(
    MockClient((req) async {
      log?.add(req);
      return http.Response(
        body,
        status,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

void main() {
  group('provider detection', () {
    final cases = <String, String?>{
      'https://api.openai.com/v1': 'openai',
      'platform.openai.com': 'openai',
      'https://api.deepseek.com/v1': 'deepseek',
      'https://openrouter.ai/api/v1': 'openrouter',
      'https://api.groq.com/openai/v1': 'groq',
      'https://console.mistral.ai': 'mistral',
      'https://api.x.ai/v1': 'xai',
      'https://api.together.xyz/v1': 'together',
      'https://dashscope.aliyuncs.com/compatible-mode/v1': 'dashscope',
      'https://dashscope-intl.aliyuncs.com/compatible-mode/v1':
          'dashscope-intl',
      'https://api.fireworks.ai/inference/v1': 'fireworks',
      'https://api.perplexity.ai': 'perplexity',
      'https://console.anthropic.com/settings/keys': 'anthropic',
      'https://generativelanguage.googleapis.com/v1beta': 'gemini',
      'https://aistudio.google.com/app/apikey': 'gemini',
      'https://github.com/settings/tokens': 'github',
      'https://api.github.com': 'github',
      'https://llm.mycompany.example/v1': 'custom',
    };
    cases.forEach((url, id) {
      test('$url -> $id', () {
        expect(Providers.detect(url: url)?.id, id);
      });
    });

    test('known providers use their own API base, not the card URL', () {
      expect(
        Providers.detect(url: 'https://platform.openai.com/api-keys')!.checkUrl
            .toString(),
        'https://api.openai.com/v1/models',
      );
      expect(
        Providers.detect(url: 'https://api.deepseek.com')!.checkUrl.toString(),
        'https://api.deepseek.com/v1/models',
      );
      expect(
        Providers.detect(url: 'groq.com')!.checkUrl.toString(),
        'https://api.groq.com/openai/v1/models',
      );
    });

    test(
      'unknown URL: OpenAI-compatible {url}/models, trailing /models stripped',
      () {
        final p = Providers.detect(
          url: 'https://llm.example.org/api/v1/models/',
        )!;
        expect(p.known, isFalse);
        expect(p.checkUrl.toString(), 'https://llm.example.org/api/v1/models');
      },
    );

    test('unknown http:// URL is refused (https only)', () {
      expect(Providers.detect(url: 'http://llm.example.org/v1'), isNull);
    });

    test('no URL: detection by card name; otherwise null', () {
      expect(Providers.detect(name: 'OpenAI')?.id, 'openai');
      expect(Providers.detect(name: 'deepseek.com')?.id, 'deepseek');
      expect(Providers.detect(name: 'Мой GitHub')?.id, 'github');
      expect(Providers.detect(name: 'Банк'), isNull);
      expect(Providers.detect(), isNull);
    });

    test('OpenRouter is checked via /key (its /models is public)', () {
      expect(Providers.openrouter.checkUrl.path, '/api/v1/key');
      expect(Providers.openrouter.modelsUrl().path, '/api/v1/models');
    });
  });

  group('auth headers per provider (token only in headers, never in URL)', () {
    Future<http.BaseRequest> captured(Provider p) async {
      final log = <http.BaseRequest>[];
      await checkerReturning(200, okBody(p.kind), log: log).check(p, token);
      return log.single;
    }

    test('OpenAI-compatible: Bearer', () async {
      final r = await captured(Providers.openai);
      expect(r.headers['Authorization'], 'Bearer $token');
      expect(r.url.toString(), 'https://api.openai.com/v1/models');
    });
    test('Anthropic: x-api-key + anthropic-version', () async {
      final r = await captured(Providers.anthropic);
      expect(r.headers['x-api-key'], token);
      expect(r.headers['anthropic-version'], '2023-06-01');
      expect(r.headers.containsKey('Authorization'), isFalse);
      expect(r.url.host, 'api.anthropic.com');
      expect(r.url.path, '/v1/models');
    });
    test('Gemini: x-goog-api-key header, no key in query', () async {
      final r = await captured(Providers.gemini);
      expect(r.headers['x-goog-api-key'], token);
      expect(r.url.queryParameters.containsKey('key'), isFalse);
      expect(r.url.toString(), isNot(contains(token)));
      expect(r.url.path, '/v1beta/models');
    });
    test('GitHub: GET /user with Bearer', () async {
      final r = await captured(Providers.github);
      expect(r.url.toString(), 'https://api.github.com/user');
      expect(r.headers['Authorization'], 'Bearer $token');
    });
  });

  group('status mapping per provider', () {
    final providers = [
      Providers.openai,
      Providers.deepseek,
      Providers.openrouter,
      Providers.groq,
      Providers.mistral,
      Providers.xai,
      Providers.together,
      Providers.dashscope,
      Providers.fireworks,
      Providers.perplexity,
      Providers.anthropic,
      Providers.gemini,
      Providers.github,
    ];
    for (final p in providers) {
      group(p.name, () {
        test('200 -> valid', () async {
          final r = await checkerReturning(200, okBody(p.kind)).check(p, token);
          expect(r.status, CheckStatus.valid);
        });
        test('401 -> invalid', () async {
          final r = await checkerReturning(
            401,
            '{"error":{"message":"Incorrect API key"}}',
          ).check(p, token);
          expect(r.status, CheckStatus.invalid);
          expect(r.httpCode, 401);
        });
        test('403 -> invalid', () async {
          final r = await checkerReturning(
            403,
            '{"message":"Forbidden"}',
          ).check(p, token);
          expect(r.status, CheckStatus.invalid);
        });
        test('429 -> rate limited', () async {
          final r = await checkerReturning(
            429,
            '{"error":"slow down"}',
          ).check(p, token);
          expect(r.status, CheckStatus.rateLimited);
        });
        test('offline -> noNetwork', () async {
          final c = TokenChecker(
            MockClient(
              (_) async => throw const SocketException('Failed host lookup'),
            ),
          );
          expect((await c.check(p, token)).status, CheckStatus.noNetwork);
        });
        test('500 -> serverError', () async {
          final r = await checkerReturning(503, 'oops').check(p, token);
          expect(r.status, CheckStatus.serverError);
        });
      });
    }

    test('Gemini/xAI style 400 "API key not valid" -> invalid', () async {
      final r = await checkerReturning(
        400,
        '{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}',
      ).check(Providers.gemini, token);
      expect(r.status, CheckStatus.invalid);
      final x = await checkerReturning(
        400,
        '{"code":"invalid-argument","error":"Incorrect API key provided."}',
      ).check(Providers.xai, token);
      expect(x.status, CheckStatus.invalid);
    });
    test('400 unrelated to key -> error, not invalid', () async {
      final r = await checkerReturning(
        400,
        '{"error":"bad request"}',
      ).check(Providers.openai, token);
      expect(r.status, CheckStatus.error);
    });
    test('402 -> paymentRequired', () async {
      final r = await checkerReturning(
        402,
        '{"error":"Insufficient Balance"}',
      ).check(Providers.deepseek, token);
      expect(r.status, CheckStatus.paymentRequired);
    });
    test('timeout -> noNetwork', () async {
      final c = TokenChecker(
        MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response('{}', 200);
        }),
        timeout: const Duration(milliseconds: 20),
      );
      expect(
        (await c.check(Providers.openai, token)).status,
        CheckStatus.noNetwork,
      );
    });
    test('no provider -> unknownService without any request', () async {
      final log = <http.BaseRequest>[];
      final r = await checkerReturning(200, '{}', log: log).check(null, token);
      expect(r.status, CheckStatus.unknownService);
      expect(log, isEmpty);
    });
    test('custom URL: 404 -> unknownService, HTML 200 -> unknownService, JSON 200 -> valid', () async {
      final p = Providers.detect(url: 'https://llm.example.org/v1')!;
      expect(
        (await checkerReturning(404, 'not found').check(p, token)).status,
        CheckStatus.unknownService,
      );
      expect(
        (await checkerReturning(200, '<html>hi</html>').check(p, token)).status,
        CheckStatus.unknownService,
      );
      expect(
        (await checkerReturning(
          200,
          okBody(ProviderKind.openAiCompatible),
        ).check(p, token)).status,
        CheckStatus.valid,
      );
    });
    test('error detail never contains the token or its fragments', () async {
      final r = await checkerReturning(
        401,
        '{"error":{"message":"Authentication Fails, Your api key: ****cdef is invalid; got $token"}}',
      ).check(Providers.deepseek, token);
      expect(r.detail, isNot(contains(token)));
      expect(r.detail, isNot(contains('cdef')));
      expect(r.toString(), isNot(contains('SECRET')));
    });
  });

  group('redirects', () {
    test(
      'cross-host redirect is NOT followed: auth never reaches other host',
      () async {
        final log = <http.BaseRequest>[];
        final c = TokenChecker(
          MockClient((req) async {
            log.add(req);
            if (req.url.host == 'api.openai.com') {
              return http.Response(
                '',
                302,
                headers: {'location': 'https://evil.example.com/collect'},
              );
            }
            return http.Response('{"data":[]}', 200);
          }),
        );
        final r = await c.check(Providers.openai, token);
        expect(r.status, CheckStatus.error);
        expect(r.detail, contains('evil.example.com'));
        expect(log.map((e) => e.url.host), ['api.openai.com']);
        expect(log.every((e) => e.followRedirects == false), isTrue);
      },
    );
    test('same-host https redirect is followed', () async {
      final log = <http.BaseRequest>[];
      final c = TokenChecker(
        MockClient((req) async {
          log.add(req);
          if (req.url.path == '/v1/models') {
            return http.Response('', 301, headers: {'location': '/v1/models/'});
          }
          return http.Response(okBody(ProviderKind.openAiCompatible), 200);
        }),
      );
      final r = await c.check(Providers.openai, token);
      expect(r.status, CheckStatus.valid);
      expect(log.length, 2);
      expect(log.last.headers['Authorization'], 'Bearer $token');
    });
    test('redirect to http on same host is refused', () async {
      final c = TokenChecker(
        MockClient(
          (req) async => http.Response(
            '',
            302,
            headers: {'location': 'http://api.openai.com/v1/models'},
          ),
        ),
      );
      expect(
        (await c.check(Providers.openai, token)).status,
        CheckStatus.error,
      );
    });
  });

  group('models parsing per provider', () {
    test('OpenAI-compatible {data:[...]}', () {
      final r = TokenChecker.parseModels(
        ProviderKind.openAiCompatible,
        okBody(ProviderKind.openAiCompatible),
      )!;
      expect(r.$1.map((m) => m.id), ['model-b', 'model-a']);
      expect(r.$1.first.owner, 'org');
    });
    test('Together: bare array', () {
      final r = TokenChecker.parseModels(
        ProviderKind.openAiCompatible,
        '[{"id":"meta-llama/Llama-3","display_name":"Llama 3","context_length":8192}]',
      )!;
      expect(r.$1.single.id, 'meta-llama/Llama-3');
      expect(r.$1.single.name, 'Llama 3');
      expect(r.$1.single.contextLength, 8192);
    });
    test('OpenRouter: name + context_length', () {
      final r = TokenChecker.parseModels(
        ProviderKind.openAiCompatible,
        '{"data":[{"id":"openai/gpt-4o","name":"OpenAI: GPT-4o","context_length":128000}]}',
      )!;
      expect(r.$1.single.name, 'OpenAI: GPT-4o');
      expect(r.$1.single.contextLength, 128000);
    });
    test('Anthropic: display_name and pagination cursor', () {
      final r = TokenChecker.parseModels(
        ProviderKind.anthropic,
        '{"data":[{"id":"claude-x","display_name":"Claude X"}],"has_more":true,"last_id":"claude-x"}',
      )!;
      expect(r.$1.single.name, 'Claude X');
      expect(r.$2, 'claude-x');
    });
    test('Gemini: strips models/ prefix, nextPageToken', () {
      final r = TokenChecker.parseModels(
        ProviderKind.gemini,
        '{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","inputTokenLimit":1048576}],"nextPageToken":"abc"}',
      )!;
      expect(r.$1.single.id, 'gemini-2.5-pro');
      expect(r.$1.single.contextLength, 1048576);
      expect(r.$2, 'abc');
    });
    test('garbage -> null', () {
      expect(
        TokenChecker.parseModels(ProviderKind.openAiCompatible, '<html>'),
        isNull,
      );
      expect(
        TokenChecker.parseModels(ProviderKind.anthropic, '{"x":1}'),
        isNull,
      );
    });
    test(
      'models(): sorted, de-duplicated; Gemini pages are followed',
      () async {
        var calls = 0;
        final c = TokenChecker(
          MockClient((req) async {
            calls++;
            if (req.url.queryParameters['pageToken'] == null) {
              return http.Response(
                '{"models":[{"name":"models/b"},{"name":"models/a"}],"nextPageToken":"p2"}',
                200,
              );
            }
            return http.Response(
              '{"models":[{"name":"models/c"},{"name":"models/a"}]}',
              200,
            );
          }),
        );
        final r = await c.models(Providers.gemini, token);
        expect(r.check.isValid, isTrue);
        expect(r.models.map((m) => m.id), ['a', 'b', 'c']);
        expect(calls, 2);
      },
    );
    test('models(): 401 propagates as invalid; GitHub has no models', () async {
      final r = await checkerReturning(
        401,
        '{}',
      ).models(Providers.openai, token);
      expect(r.check.status, CheckStatus.invalid);
      final g = await checkerReturning(
        200,
        '{}',
      ).models(Providers.github, token);
      expect(g.check.status, CheckStatus.unknownService);
    });
  });

  group('models cache in the encrypted vault', () {
    const fast = KdfParams.argon2id(
      memoryKiB: 64,
      iterations: 1,
      parallelism: 1,
    );

    test('roundtrip through encrypt/decrypt keeps the list and its date', () {
      final card = ServiceCard.create(
        name: 'OpenAI',
        token: token,
        url: 'https://api.openai.com/v1',
        colorIndex: 1,
      );
      final at = DateTime(2026, 11, 17, 11, 45);
      card.models = ModelsCache(
        items: const [
          ModelInfo('gpt-x', owner: 'openai'),
          ModelInfo('o9', name: 'O9', contextLength: 200000),
        ],
        fetchedAt: at,
        providerId: 'openai',
      );
      final data = VaultData(cards: [card], updatedAt: DateTime.now());
      final opened = VaultCore.create('pw', data, kdf: fast);
      final c = VaultContainer.parse(opened.container.serialize());
      final again = VaultCore.unlock(c, 'pw', kdf: fast);
      final m = again.data.cards.single.models!;
      expect(m.fetchedAt, at);
      expect(m.providerId, 'openai');
      expect(m.items.map((e) => e.id), ['gpt-x', 'o9']);
      expect(m.items[1].contextLength, 200000);
      expect(m.items[0].owner, 'openai');
    });

    test(
      'old data without models (v0.2) still decodes; card.models == null',
      () {
        final legacy = jsonEncode({
          'updatedAt': '2026-11-01T10:00:00.000',
          'cards': [
            {
              'id': 'abc',
              'name': 'x',
              'token': 't',
              'url': null,
              'expiry': null,
              'colorIndex': 0,
              'createdAt': '2026-11-01T10:00:00.000',
              'updatedAt': '2026-11-01T10:00:00.000',
            },
          ],
        });
        final d = VaultData.decode(legacy);
        expect(d.cards.single.models, isNull);
        expect(jsonDecode(d.encode())['schema'], 2);
        expect(
          (jsonDecode(d.encode())['cards'] as List).single,
          isNot(contains('models')),
        );
      },
    );

    test('corrupt models field is ignored, card survives', () {
      final j = {
        'id': 'abc',
        'name': 'x',
        'token': 't',
        'colorIndex': 0,
        'models': {'fetchedAt': 'nope', 'items': 5},
      };
      expect(ServiceCard.fromJson(j).models, isNull);
      final j2 = {
        ...j,
        'models': {
          'fetchedAt': '2026-11-17T00:00:00.000',
          'items': [
            {'id': 'ok'},
            7,
            {'x': 1},
          ],
        },
      };
      expect(ServiceCard.fromJson(j2).models!.items.single.id, 'ok');
    });
  });
}
