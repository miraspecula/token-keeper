import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

export 'models.dart' show ModelInfo, ModelsCache;

/// Проверка API-токенов и получение списка моделей. Чистый Dart.
///
/// Правила безопасности:
/// - токен уходит только на API-хост самого сервиса и только по https;
/// - редирект на другой хост не выполняется (заголовок авторизации никуда
///   не пересылается), редирект на тот же хост — только https;
/// - токен не пишется в логи, исключения и результаты (тексты ошибок сервиса
///   обрезаются и очищаются от фрагментов токена).

enum ProviderKind { openAiCompatible, anthropic, gemini, github }

class Provider {
  final String id;
  final String name;
  final ProviderKind kind;

  /// База API без завершающего «/», например `https://api.openai.com/v1`.
  final Uri base;

  /// Известный сервис (true) или угаданный OpenAI-совместимый по URL карточки.
  final bool known;

  const Provider(this.id, this.name, this.kind, this.base, {this.known = true});

  bool get supportsModels => kind != ProviderKind.github;

  /// Адрес лёгкой проверки ключа.
  Uri get checkUrl => switch (kind) {
    ProviderKind.github => _join(base, '/user'),
    ProviderKind.gemini => _join(base, '/models', {'pageSize': '1'}),
    ProviderKind.anthropic => _join(base, '/models', {'limit': '1'}),
    // У OpenRouter /models публичный (200 с любым ключом) — проверяем /key.
    ProviderKind.openAiCompatible =>
      id == 'openrouter' ? _join(base, '/key') : _join(base, '/models'),
  };

  Uri modelsUrl({String? pageToken, String? afterId}) => switch (kind) {
    ProviderKind.gemini => _join(base, '/models', {
      'pageSize': '1000',
      'pageToken': ?pageToken,
    }),
    ProviderKind.anthropic => _join(base, '/models', {
      'limit': '1000',
      'after_id': ?afterId,
    }),
    _ => _join(base, '/models'),
  };

  static Uri _join(Uri base, String path, [Map<String, String>? q]) {
    final p = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$p$path',
      queryParameters: (q == null || q.isEmpty) ? null : q,
    );
  }

  @override
  String toString() => 'Provider($id, $base)';
}

/// Очистка вставленного токена и URL.
///
/// API-ключи не содержат пробелов и невидимых символов, а при копировании из
/// мессенджеров/заметок в них попадают переносы, неразрывные пробелы,
/// мягкие переносы, zero-width и BOM. Пробел или таб внутри ключа сервис
/// видит как другой ключ (401), а \r, \n, NBSP, U+00AD, U+200B делают
/// заголовок недопустимым. Поэтому из токена удаляются все такие символы.
class TokenText {
  static final _invisible = RegExp(
    '[\\s\u00A0\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180E'
    '\u2000-\u200F\u2028-\u202F\u205F-\u206F\u3000\u3164\uFEFF\uFFA0]',
  );

  /// Токен без пробелов, переносов и невидимых символов.
  static String sanitizeToken(String raw) => raw.replaceAll(_invisible, '');

  /// URL без пробелов по краям и невидимых символов внутри.
  static String sanitizeUrl(String raw) => raw.replaceAll(_invisible, '');

  /// Токен состоит только из печатных ASCII (0x21–0x7E)?
  static bool isHeaderSafe(String token) =>
      token.isNotEmpty && token.codeUnits.every((c) => c >= 0x21 && c <= 0x7E);
}

/// Известные сервисы: (суффикс хоста) → провайдер.
class Providers {
  static Provider _oa(String id, String name, String base) =>
      Provider(id, name, ProviderKind.openAiCompatible, Uri.parse(base));

  static final openai = _oa('openai', 'OpenAI', 'https://api.openai.com/v1');
  static final deepseek = _oa(
    'deepseek',
    'DeepSeek',
    'https://api.deepseek.com/v1',
  );
  static final openrouter = _oa(
    'openrouter',
    'OpenRouter',
    'https://openrouter.ai/api/v1',
  );
  static final groq = _oa('groq', 'Groq', 'https://api.groq.com/openai/v1');
  static final mistral = _oa('mistral', 'Mistral', 'https://api.mistral.ai/v1');
  static final xai = _oa('xai', 'xAI', 'https://api.x.ai/v1');
  static final together = _oa(
    'together',
    'Together AI',
    'https://api.together.xyz/v1',
  );
  static final dashscope = _oa(
    'dashscope',
    'Qwen (DashScope, Китай)',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
  );
  static final dashscopeIntl = _oa(
    'dashscope-intl',
    'Qwen (DashScope International)',
    'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
  );
  static final fireworks = _oa(
    'fireworks',
    'Fireworks AI',
    'https://api.fireworks.ai/inference/v1',
  );
  static final perplexity = _oa(
    'perplexity',
    'Perplexity',
    'https://api.perplexity.ai/v1',
  );
  static final anthropic = Provider(
    'anthropic',
    'Anthropic',
    ProviderKind.anthropic,
    Uri.parse('https://api.anthropic.com/v1'),
  );
  static final gemini = Provider(
    'gemini',
    'Google Gemini',
    ProviderKind.gemini,
    Uri.parse('https://generativelanguage.googleapis.com/v1beta'),
  );
  static final github = Provider(
    'github',
    'GitHub',
    ProviderKind.github,
    Uri.parse('https://api.github.com'),
  );

  /// Порядок важен: более длинные/специфичные суффиксы раньше.
  static final List<(String, Provider)> _bySuffix = [
    ('dashscope-intl.aliyuncs.com', dashscopeIntl),
    ('dashscope.aliyuncs.com', dashscope),
    ('generativelanguage.googleapis.com', gemini),
    ('aistudio.google.com', gemini),
    ('ai.google.dev', gemini),
    ('openai.com', openai),
    ('deepseek.com', deepseek),
    ('openrouter.ai', openrouter),
    ('groq.com', groq),
    ('mistral.ai', mistral),
    ('x.ai', xai),
    ('together.xyz', together),
    ('together.ai', together),
    ('fireworks.ai', fireworks),
    ('perplexity.ai', perplexity),
    ('anthropic.com', anthropic),
    ('claude.ai', anthropic),
    ('github.com', github),
  ];

  static List<Provider> get all => {for (final e in _bySuffix) e.$2}.toList();

  static Uri? _parse(String raw) {
    final t = TokenText.sanitizeUrl(raw);
    if (t.isEmpty) return null;
    try {
      final u = Uri.parse(t.contains('://') ? t : 'https://$t');
      return u.host.isEmpty ? null : u;
    } catch (_) {
      return null;
    }
  }

  static bool _hostMatches(String host, String suffix) =>
      host == suffix || host.endsWith('.$suffix');

  /// Определяет сервис по URL карточки. Известный домен (в т.ч. сайт или
  /// консоль сервиса: platform.openai.com, console.anthropic.com) → его API.
  /// Неизвестный https-URL → OpenAI-совместимый `{url}/models`.
  /// Без URL — по названию карточки («OpenAI», «deepseek.com»). Иначе null.
  static Provider? detect({String? url, String? name}) {
    final u = url == null ? null : _parse(url);
    if (u != null) {
      final host = u.host.toLowerCase();
      for (final (suffix, p) in _bySuffix) {
        if (_hostMatches(host, suffix)) return p;
      }
      if (u.scheme != 'https') return null; // только https
      var path = u.path;
      while (path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
      if (path.endsWith('/models')) {
        path = path.substring(0, path.length - '/models'.length);
      }
      return Provider(
        'custom',
        host,
        ProviderKind.openAiCompatible,
        Uri(
          scheme: 'https',
          host: u.host,
          port: u.hasPort ? u.port : null,
          path: path,
        ),
        known: false,
      );
    }
    final n = (name ?? '').trim().toLowerCase();
    if (n.isEmpty) return null;
    final asHost = _parse(n)?.host;
    if (asHost != null && asHost.contains('.')) {
      for (final (suffix, p) in _bySuffix) {
        if (_hostMatches(asHost, suffix)) return p;
      }
    }
    for (final p in all) {
      final pn = p.name.toLowerCase().split(' ').first;
      if (pn.length >= 3 && n.split(RegExp(r'[\s.:/_-]+')).contains(pn)) {
        return p;
      }
    }
    return null;
  }
}

enum CheckStatus {
  valid, // ключ принят
  invalid, // 401/403 или явное «ключ недействителен»
  paymentRequired, // 402: ключ принят, но нет баланса
  rateLimited, // 429
  noNetwork, // нет соединения, DNS, таймаут
  unknownService, // сервис не распознан / эндпоинт не найден
  serverError, // 5xx
  error, // прочее (неожиданный ответ, TLS, редирект на чужой хост)
}

class _HttpsOnly implements Exception {
  const _HttpsOnly();
}

class CheckResult {
  final CheckStatus status;
  final int? httpCode;
  final String? detail; // короткое пояснение, без токена
  final Provider? provider;
  const CheckResult(this.status, {this.httpCode, this.detail, this.provider});

  bool get isValid => status == CheckStatus.valid;
  bool get isInvalid => status == CheckStatus.invalid;

  String get title => switch (status) {
    CheckStatus.valid => 'Токен действителен',
    CheckStatus.invalid => 'Токен недействителен или отозван',
    CheckStatus.paymentRequired => 'Токен принят, но нужна оплата',
    CheckStatus.rateLimited => 'Слишком много запросов (429)',
    CheckStatus.noNetwork => 'Нет сети',
    CheckStatus.unknownService => 'Сервис не распознан',
    CheckStatus.serverError => 'Ошибка на стороне сервиса',
    CheckStatus.error => 'Не удалось проверить',
  };

  @override
  String toString() => 'CheckResult($status, $httpCode, $detail)';
}

class ModelsResult {
  final CheckResult check; // статус запроса
  final List<ModelInfo> models;
  const ModelsResult(this.check, this.models);
}

/// Исключение для отказа следовать редиректу на другой хост.
class CrossHostRedirect implements Exception {
  final String toHost;
  CrossHostRedirect(this.toHost);
}

class _Resp {
  final int status;
  final String body;
  _Resp(this.status, this.body);
}

class TokenChecker {
  final http.Client client;
  final Duration timeout;
  static const int maxBodyBytes = 8 * 1024 * 1024;
  static const int maxRedirects = 3;
  static const int maxModels = 5000;

  TokenChecker(this.client, {this.timeout = const Duration(seconds: 15)});

  Map<String, String> _authHeaders(Provider p, String token) {
    final h = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'TokenKeeper/0.3 (Android)',
    };
    switch (p.kind) {
      case ProviderKind.anthropic:
        h['x-api-key'] = token;
        h['anthropic-version'] = '2023-06-01';
      case ProviderKind.gemini:
        h['x-goog-api-key'] = token; // не в query: не попадает в логи URL
      case ProviderKind.github:
        h['Authorization'] = 'Bearer $token';
        h['Accept'] = 'application/vnd.github+json';
        h['X-GitHub-Api-Version'] = '2022-11-28';
      case ProviderKind.openAiCompatible:
        h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  /// GET без автоматических редиректов. Тот же хост (https) — следуем с теми
  /// же заголовками; другой хост — НЕ следуем (токен не уходит наружу).
  Future<_Resp> _get(Uri url, Map<String, String> headers) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (current.scheme != 'https') {
        throw const _HttpsOnly();
      }
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final resp = await client.send(req).timeout(timeout);
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final loc = resp.headers['location'];
        await resp.stream.drain<void>().catchError((_) {});
        if (loc == null) return _Resp(resp.statusCode, '');
        final next = current.resolve(loc);
        if (next.host.toLowerCase() != url.host.toLowerCase() ||
            next.scheme != 'https' ||
            next.port != url.port) {
          throw CrossHostRedirect(next.host);
        }
        current = next;
        continue;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.stream.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBodyBytes) break;
      }
      return _Resp(
        resp.statusCode,
        utf8.decode(builder.takeBytes(), allowMalformed: true),
      );
    }
    throw CrossHostRedirect('too many redirects');
  }

  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is HttpException ||
      (e is http.ClientException && e is! http.RequestAbortedException);

  /// Короткое пояснение из тела ошибки, без фрагментов токена.
  static String? _errorDetail(String body, String token) {
    String? msg;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map && e['message'] is String) {
          msg = e['message'] as String;
        } else if (e is String) {
          msg = e;
        } else if (j['message'] is String) {
          msg = j['message'] as String;
        } else if (j['detail'] is String) {
          msg = j['detail'] as String;
        }
      }
    } catch (_) {}
    if (msg == null) return null;
    if (token.length >= 4) {
      // Сервисы иногда цитируют часть ключа — вырезаем любые его фрагменты.
      msg = msg.replaceAll(token, '•••');
      for (var n = token.length - 1; n >= 4; n--) {
        msg = msg!.replaceAll(token.substring(0, n), '•••');
        msg = msg.replaceAll(token.substring(token.length - n), '•••');
      }
    }
    msg = msg!.replaceAll(RegExp(r'\s+'), ' ').trim();
    return msg.length > 160 ? '${msg.substring(0, 160)}…' : msg;
  }

  static final _keyInvalidRe = RegExp(
    r'(api[ _-]?key|apikey|x-api-key|credential|token|authenticat).{0,40}'
    r'(invalid|not valid|incorrect|bad|expired|revoked|fail)'
    r'|(invalid|incorrect|bad|expired|revoked).{0,20}(api[ _-]?key|credential|token)'
    r'|API_KEY_INVALID|PERMISSION_DENIED|UNAUTHENTICATED',
    caseSensitive: false,
  );

  CheckResult _classify(Provider p, _Resp r, String token) {
    final code = r.status;
    final detail = _errorDetail(r.body, token);
    if (code >= 200 && code < 300) {
      // Некоторые прокси отвечают 200 HTML-страницей — это не API.
      final t = r.body.trimLeft();
      if (!p.known && !(t.startsWith('{') || t.startsWith('['))) {
        return CheckResult(
          CheckStatus.unknownService,
          httpCode: code,
          detail: 'ответ не похож на API',
          provider: p,
        );
      }
      return CheckResult(CheckStatus.valid, httpCode: code, provider: p);
    }
    if (code == 401 || code == 403) {
      return CheckResult(
        CheckStatus.invalid,
        httpCode: code,
        detail: detail,
        provider: p,
      );
    }
    if (code == 400 && _keyInvalidRe.hasMatch(r.body)) {
      // Gemini и xAI сообщают о неверном ключе кодом 400.
      return CheckResult(
        CheckStatus.invalid,
        httpCode: code,
        detail: detail,
        provider: p,
      );
    }
    if (code == 402) {
      return CheckResult(
        CheckStatus.paymentRequired,
        httpCode: code,
        detail: detail,
        provider: p,
      );
    }
    if (code == 429) {
      return CheckResult(
        CheckStatus.rateLimited,
        httpCode: code,
        detail: detail,
        provider: p,
      );
    }
    if ((code == 404 || code == 405) && !p.known) {
      return CheckResult(
        CheckStatus.unknownService,
        httpCode: code,
        detail: 'по адресу нет OpenAI-совместимого /models',
        provider: p,
      );
    }
    if (code >= 500) {
      return CheckResult(
        CheckStatus.serverError,
        httpCode: code,
        detail: detail,
        provider: p,
      );
    }
    return CheckResult(
      CheckStatus.error,
      httpCode: code,
      detail: detail,
      provider: p,
    );
  }

  static CheckResult? _badToken(String token, Provider p) {
    if (token.isEmpty) {
      return CheckResult(
        CheckStatus.error,
        detail: 'пустой токен',
        provider: p,
      );
    }
    if (!TokenText.isHeaderSafe(token)) {
      return CheckResult(
        CheckStatus.error,
        detail:
            'в токене есть недопустимые символы (не латиница/цифры/знаки); '
            'вставьте его заново',
        provider: p,
      );
    }
    return null;
  }

  CheckResult _fromException(Object e, Provider p) {
    if (e is CrossHostRedirect) {
      return CheckResult(
        CheckStatus.error,
        detail:
            'сервис перенаправил на другой адрес (${e.toHost}); '
            'токен туда не отправлялся',
        provider: p,
      );
    }
    if (e is HandshakeException || e is TlsException) {
      return CheckResult(
        CheckStatus.error,
        detail: 'ошибка TLS-соединения',
        provider: p,
      );
    }
    if (_isNetworkError(e)) {
      return CheckResult(CheckStatus.noNetwork, provider: p);
    }
    if (e is _HttpsOnly) {
      return CheckResult(
        CheckStatus.error,
        detail: 'разрешён только https',
        provider: p,
      );
    }
    // Текст прочих исключений не показываем: он может содержать заголовок
    // с токеном (например, «Invalid HTTP header field value: "Bearer …"»).
    return CheckResult(CheckStatus.error, provider: p);
  }

  /// Лёгкая проверка ключа. [provider] == null → «сервис не распознан»
  /// без единого сетевого запроса.
  Future<CheckResult> check(Provider? provider, String token) async {
    if (provider == null) {
      return const CheckResult(
        CheckStatus.unknownService,
        detail: 'укажите URL сервиса (например, https://api.openai.com/v1)',
      );
    }
    token = TokenText.sanitizeToken(token);
    final bad = _badToken(token, provider);
    if (bad != null) return bad;
    try {
      final r = await _get(provider.checkUrl, _authHeaders(provider, token));
      return _classify(provider, r, token);
    } catch (e) {
      return _fromException(e, provider);
    }
  }

  /// Список моделей (с постраничной загрузкой у Gemini и Anthropic).
  Future<ModelsResult> models(Provider? provider, String token) async {
    if (provider == null || !provider.supportsModels) {
      return ModelsResult(
        CheckResult(
          CheckStatus.unknownService,
          detail: provider == null
              ? 'сервис не распознан'
              : '${provider.name} не отдаёт список моделей',
          provider: provider,
        ),
        const [],
      );
    }
    token = TokenText.sanitizeToken(token);
    final bad = _badToken(token, provider);
    if (bad != null) return ModelsResult(bad, const []);
    final headers = _authHeaders(provider, token);
    final out = <ModelInfo>[];
    String? pageToken;
    String? afterId;
    try {
      for (var page = 0; page < 20; page++) {
        final r = await _get(
          provider.modelsUrl(pageToken: pageToken, afterId: afterId),
          headers,
        );
        final c = _classify(provider, r, token);
        if (!c.isValid) return ModelsResult(c, out);
        final parsed = parseModels(provider.kind, r.body);
        if (parsed == null) {
          return ModelsResult(
            CheckResult(
              CheckStatus.error,
              httpCode: r.status,
              detail: 'неожиданный формат ответа',
              provider: provider,
            ),
            out,
          );
        }
        out.addAll(parsed.$1);
        if (out.length >= maxModels) break;
        if (provider.kind == ProviderKind.gemini && parsed.$2 != null) {
          pageToken = parsed.$2;
        } else if (provider.kind == ProviderKind.anthropic &&
            parsed.$2 != null) {
          afterId = parsed.$2;
        } else {
          break;
        }
      }
    } catch (e) {
      return ModelsResult(_fromException(e, provider), out);
    }
    final seen = <String>{};
    final unique = [
      for (final m in out)
        if (seen.add(m.id)) m,
    ]..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return ModelsResult(
      CheckResult(CheckStatus.valid, httpCode: 200, provider: provider),
      unique.take(maxModels).toList(),
    );
  }

  /// Разбор ответа. Возвращает (модели, курсор следующей страницы) или null.
  /// - OpenAI-совместимые: `{"data":[{"id","owned_by",...}]}` или голый массив
  ///   (Together); OpenRouter добавляет `name`, `context_length`.
  /// - Anthropic: `{"data":[{"id","display_name"}],"has_more","last_id"}`.
  /// - Gemini: `{"models":[{"name":"models/x","displayName","inputTokenLimit"}],
  ///   "nextPageToken"}`.
  static (List<ModelInfo>, String?)? parseModels(
    ProviderKind kind,
    String body,
  ) {
    Object? j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      return null;
    }
    int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    switch (kind) {
      case ProviderKind.gemini:
        if (j is! Map || j['models'] is! List) {
          return j is Map ? (const <ModelInfo>[], null) : null;
        }
        final list = <ModelInfo>[];
        for (final m in j['models'] as List) {
          if (m is! Map || m['name'] is! String) continue;
          var id = m['name'] as String;
          if (id.startsWith('models/')) id = id.substring(7);
          list.add(
            ModelInfo(
              id,
              name: m['displayName'] as String?,
              contextLength: asInt(m['inputTokenLimit']),
            ),
          );
        }
        final next = j['nextPageToken'];
        return (list, next is String && next.isNotEmpty ? next : null);
      case ProviderKind.anthropic:
        if (j is! Map || j['data'] is! List) return null;
        final list = <ModelInfo>[
          for (final m in j['data'] as List)
            if (m is Map && m['id'] is String)
              ModelInfo(m['id'] as String, name: m['display_name'] as String?),
        ];
        final more = j['has_more'] == true;
        final last = j['last_id'];
        return (list, more && last is String ? last : null);
      case ProviderKind.openAiCompatible:
        final List<dynamic>? data = j is List
            ? j
            : (j is Map && j['data'] is List)
            ? j['data'] as List
            : (j is Map && j['models'] is List)
            ? j['models'] as List
            : null;
        if (data == null) return null;
        final list = <ModelInfo>[];
        for (final m in data) {
          if (m is String) {
            list.add(ModelInfo(m));
          } else if (m is Map && m['id'] is String) {
            list.add(
              ModelInfo(
                m['id'] as String,
                name: (m['name'] ?? m['display_name']) as String?,
                owner: (m['owned_by'] ?? m['organization']) as String?,
                contextLength: asInt(
                  m['context_length'] ?? m['context_window'],
                ),
              ),
            );
          }
        }
        return (list, null);
      case ProviderKind.github:
        return null;
    }
  }
}
