import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'public_suffix.dart';

/// Тип найденной иконки.
enum IconKind { png, raster, ico, svg }

/// Кандидат из `<link rel="...icon...">` или запасной `/favicon.ico`.
class IconCandidate {
  final Uri url;
  final IconKind kind;
  final int size; // наибольшая сторона из sizes=, 0 — неизвестно
  final int index; // порядок в документе (для стабильной сортировки)

  const IconCandidate(this.url, this.kind, this.size, this.index);

  /// Чем больше, тем лучше: PNG > прочий растр > ICO > SVG; внутри типа —
  /// размер, ближайший к 64–256 px.
  int get score {
    final base = switch (kind) {
      IconKind.png => 3000,
      IconKind.raster => 2000,
      IconKind.ico => 1000,
      IconKind.svg => 0,
    };
    final s = size == 0 ? 32 : size;
    final sizeScore = s >= 64 ? (s <= 256 ? 500 + s : 500) : s;
    return base + sizeScore;
  }

  @override
  String toString() => 'IconCandidate($kind ${size}px $url)';
}

/// Загруженная и нормализованная иконка: PNG (растр, ≤128 px) или SVG-текст.
class FetchedIcon {
  final Uint8List bytes;
  final bool isSvg;
  final Uri source;
  const FetchedIcon(this.bytes, this.isSvg, this.source);
}

class _Resp {
  final Uri url; // итоговый адрес после редиректов
  final int status;
  final String contentType;
  final Uint8List body;
  _Resp(this.url, this.status, this.contentType, this.body);
}

/// Поиск favicon сервиса. Чистый Dart (без Flutter), чтобы проверять тестами
/// и с компьютера. Только https; редиректы обрабатываются вручную, чтобы
/// не уйти на http.
class FaviconFetcher {
  final http.Client client;
  final PublicSuffixList psl;
  final Duration timeout;
  static const int maxPageBytes = 768 * 1024; // HTML читаем не больше (head в начале)
  static const int maxIconBytes = 1024 * 1024;
  static const int maxRedirects = 5;
  static const int outputSize = 128;

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,image/avif,image/webp,image/png,image/*;q=0.8,*/*;q=0.5',
  };

  FaviconFetcher(this.client, this.psl,
      {this.timeout = const Duration(seconds: 8)});

  /// Хост из URL или «голого» домена.
  static String? hostOf(String urlOrHost) {
    final t = urlOrHost.trim();
    if (t.isEmpty) return null;
    try {
      final u = Uri.parse(t.contains('://') ? t : 'https://$t');
      return u.host.isEmpty ? null : PublicSuffixList.normalizeHost(u.host);
    } catch (_) {
      return null;
    }
  }

  /// Порядок хостов: корневой домен, www.корень, исходный хост последним.
  static List<String> candidateHosts(String host, PublicSuffixList psl) {
    final h = PublicSuffixList.normalizeHost(host);
    final root = psl.registrableDomain(h);
    if (root == null) return [h];
    final out = <String>[];
    for (final c in [root, 'www.$root', h]) {
      if (!out.contains(c)) out.add(c);
    }
    return out;
  }

  static IconKind _kindOf(String? type, Uri url) {
    final t = (type ?? '').toLowerCase();
    final p = url.path.toLowerCase();
    if (t.contains('svg') || p.endsWith('.svg')) return IconKind.svg;
    if (t.contains('png') || p.endsWith('.png')) return IconKind.png;
    if (t.contains('icon') || t.contains('ico') || p.endsWith('.ico')) {
      return IconKind.ico;
    }
    if (url.scheme == 'data') {
      final d = url.toString().toLowerCase();
      if (d.startsWith('data:image/png')) return IconKind.png;
      if (d.startsWith('data:image/svg')) return IconKind.svg;
    }
    return IconKind.raster;
  }

  static Map<String, String> _attrs(String tag) {
    final out = <String, String>{};
    final re = RegExp(
        r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))''');
    for (final m in re.allMatches(tag)) {
      out[m.group(1)!.toLowerCase()] =
          _unescape(m.group(2) ?? m.group(3) ?? m.group(4) ?? '');
    }
    return out;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x2F;', '/');

  /// Разбирает `<link rel=icon|shortcut icon|apple-touch-icon ...>`,
  /// разрешает относительные адреса (с учётом `<base href>`) и сортирует
  /// по предпочтению. http-адреса повышаются до https, прочие схемы
  /// (кроме data:image) отбрасываются.
  static List<IconCandidate> parseIconLinks(String html, Uri pageUrl) {
    var base = pageUrl;
    final baseTag =
        RegExp(r'<base\s[^>]*>', caseSensitive: false).firstMatch(html);
    if (baseTag != null) {
      final href = _attrs(baseTag.group(0)!)['href'];
      if (href != null && href.isNotEmpty) {
        try {
          base = pageUrl.resolve(href);
        } catch (_) {}
      }
    }
    final out = <IconCandidate>[];
    var index = 0;
    for (final m
        in RegExp(r'<link\s[^>]*>', caseSensitive: false).allMatches(html)) {
      final a = _attrs(m.group(0)!);
      final rel = (a['rel'] ?? '').toLowerCase().split(RegExp(r'\s+'));
      final isIcon = rel.contains('icon') ||
          rel.contains('apple-touch-icon') ||
          rel.contains('apple-touch-icon-precomposed');
      if (!isIcon) continue; // mask-icon и прочее — нет
      final href = a['href']?.trim();
      if (href == null || href.isEmpty) continue;
      Uri url;
      try {
        url = href.startsWith('data:') ? Uri.parse(href) : base.resolve(href);
      } catch (_) {
        continue;
      }
      if (url.scheme == 'http') url = url.replace(scheme: 'https');
      if (url.scheme == 'data') {
        if (!href.toLowerCase().startsWith('data:image/')) continue;
      } else if (url.scheme != 'https' || url.host.isEmpty) {
        continue;
      }
      var size = 0;
      final sizes = (a['sizes'] ?? '').toLowerCase();
      for (final s in RegExp(r'(\d+)x(\d+)').allMatches(sizes)) {
        final v = int.parse(s.group(1)!);
        if (v > size) size = v;
      }
      if (size == 0 && rel.any((r) => r.startsWith('apple-touch-icon'))) {
        size = 180; // по умолчанию у apple-touch-icon
      }
      out.add(IconCandidate(url, _kindOf(a['type'], url), size, index++));
    }
    out.sort((x, y) {
      final c = y.score.compareTo(x.score);
      return c != 0 ? c : x.index.compareTo(y.index);
    });
    return out;
  }

  /// GET с ручными редиректами (только https) и ограничением размера.
  /// [truncate]: для HTML обрезаем, для картинок превышение — отказ.
  Future<_Resp?> _get(Uri url, {required int limit, required bool truncate}) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (current.scheme == 'http') current = current.replace(scheme: 'https');
      if (current.scheme != 'https' || current.host.isEmpty) return null;
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(_headers);
      final resp = await client.send(req).timeout(timeout);
      if (resp.isRedirect ||
          (resp.statusCode >= 300 && resp.statusCode < 400)) {
        final loc = resp.headers['location'];
        await resp.stream.drain<void>().catchError((_) {});
        if (loc == null) return null;
        current = current.resolve(loc);
        continue;
      }
      final len = resp.contentLength;
      if (!truncate && len != null && len > limit) {
        await resp.stream.drain<void>().catchError((_) {});
        return null;
      }
      final builder = BytesBuilder(copy: false);
      var tooBig = false;
      await for (final chunk in resp.stream.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > limit) {
          tooBig = true;
          break; // отмена подписки закрывает соединение
        }
      }
      if (tooBig && !truncate) return null;
      var body = builder.takeBytes();
      if (body.length > limit) body = Uint8List.sublistView(body, 0, limit);
      return _Resp(current, resp.statusCode,
          resp.headers['content-type'] ?? '', body);
    }
    return null;
  }

  static bool _looksLikeSvg(Uint8List b) {
    final head = utf8
        .decode(b.length > 1024 ? b.sublist(0, 1024) : b, allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return head.startsWith('<svg') ||
        (head.startsWith('<?xml') && head.contains('<svg')) ||
        (head.startsWith('<!--') && head.contains('<svg'));
  }

  static bool _isIco(Uint8List b) =>
      b.length > 6 && b[0] == 0 && b[1] == 0 && b[2] == 1 && b[3] == 0;

  /// Проверяет и приводит к единому виду: растр (PNG/ICO/JPEG/GIF/WebP/BMP)
  /// декодируется пакетом image, у ICO берётся самый крупный кадр, результат
  /// уменьшается до 128 px и кодируется в PNG. SVG сохраняется как текст.
  /// Мусор (HTML вместо картинки, битые файлы) — null.
  static Uint8List? normalizeRaster(Uint8List bytes) {
    try {
      final img.Image? decoded = _isIco(bytes)
          ? img.IcoDecoder().decodeImageLargest(bytes)
          : img.decodeImage(bytes);
      if (decoded == null || decoded.width < 8 || decoded.height < 8) {
        return null;
      }
      var out = decoded;
      if (out.width > outputSize || out.height > outputSize) {
        out = out.width >= out.height
            ? img.copyResize(out,
                width: outputSize, interpolation: img.Interpolation.average)
            : img.copyResize(out,
                height: outputSize, interpolation: img.Interpolation.average);
      }
      return img.encodePng(out);
    } catch (_) {
      return null;
    }
  }

  Future<FetchedIcon?> _download(IconCandidate c) async {
    Uint8List? bytes;
    var source = c.url;
    if (c.url.scheme == 'data') {
      bytes = c.url.data?.contentAsBytes();
    } else {
      final r = await _get(c.url, limit: maxIconBytes, truncate: false);
      if (r == null || r.status != 200 || r.body.isEmpty) return null;
      bytes = r.body;
      source = r.url;
    }
    if (bytes == null || bytes.isEmpty) return null;
    if (_looksLikeSvg(bytes)) {
      return FetchedIcon(bytes, true, source);
    }
    final png = normalizeRaster(bytes);
    return png == null ? null : FetchedIcon(png, false, source);
  }

  /// Ищет иконку для адреса сервиса (`https://api.deepseek.com/v1`,
  /// `github.com` …). Порядок: для каждого хоста из [candidateHosts] —
  /// растровые `<link>`-иконки главной страницы, затем `/favicon.ico`
  /// (и на хосте, куда привёл редирект). SVG — только если растра нигде нет.
  Future<FetchedIcon?> fetch(String urlOrHost) async {
    final host = hostOf(urlOrHost);
    if (host == null) return null;
    final svgFallbacks = <IconCandidate>[];
    final triedIco = <String>{};
    for (final h in candidateHosts(host, psl)) {
      _Resp? page;
      try {
        page = await _get(Uri.https(h, '/'),
            limit: maxPageBytes, truncate: true);
      } catch (_) {
        page = null;
      }
      final icoHosts = <String>[h];
      if (page != null) {
        if (page.url.host != h) icoHosts.insert(0, page.url.host);
        if (page.status == 200) {
          final html = utf8.decode(page.body, allowMalformed: true);
          for (final c in parseIconLinks(html, page.url)) {
            if (c.kind == IconKind.svg) {
              svgFallbacks.add(c);
              continue;
            }
            try {
              final r = await _download(c);
              if (r != null) return r;
            } catch (_) {}
          }
        }
      }
      for (final ih in icoHosts) {
        if (!triedIco.add(ih)) continue;
        try {
          final r = await _download(IconCandidate(
              Uri.https(ih, '/favicon.ico'), IconKind.ico, 0, 0));
          if (r != null) return r;
        } catch (_) {}
      }
    }
    for (final c in svgFallbacks) {
      try {
        final r = await _download(c);
        if (r != null) return r;
      } catch (_) {}
    }
    return null;
  }
}
