import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:token_keeper/favicon_fetcher.dart';
import 'package:token_keeper/public_suffix.dart';

Uint8List _ico(int size) {
  final im = img.Image(width: size, height: size, numChannels: 4);
  img.fill(im, color: img.ColorRgba8(30, 120, 255, 255));
  return img.encodeIco(im);
}

Uint8List _png(int size) {
  final im = img.Image(width: size, height: size, numChannels: 4);
  img.fill(im, color: img.ColorRgba8(200, 50, 50, 255));
  return img.encodePng(im);
}

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
    '<rect width="10" height="10" fill="red"/></svg>';

void main() {
  final psl = PublicSuffixList.parse(
    File('assets/public_suffix_list.dat').readAsStringSync(),
  );

  group('parseIconLinks', () {
    final page = Uri.parse('https://example.com/app/index.html');

    test('relative/absolute URLs, rel variants, preference order', () {
      const html = '''
<html><head>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel='shortcut icon' href='favicon.ico'>
<link href="/icons/icon-32.png" rel="icon" sizes="32x32" type="image/png">
<link rel=apple-touch-icon href=//cdn.example.com/apple.png>
<link rel="mask-icon" href="/mask.svg">
<link rel="stylesheet" href="/a.css">
</head></html>''';
      final c = FaviconFetcher.parseIconLinks(html, page);
      expect(c.map((e) => e.url.toString()).toList(), [
        'https://cdn.example.com/apple.png', // PNG 180 (apple-touch)
        'https://example.com/icons/icon-32.png', // PNG 32
        'https://example.com/app/favicon.ico', // ICO
        'https://example.com/favicon.svg', // SVG последним
      ]);
      expect(c.first.kind, IconKind.png);
      expect(c.last.kind, IconKind.svg);
    });

    test('<base href> is honoured, http upgraded, javascript: dropped', () {
      const html =
          '<base href="https://static.example.com/s/">'
          '<link rel="icon" href="i.png">'
          '<link rel="icon" href="http://example.com/x.png">'
          '<link rel="icon" href="javascript:alert(1)">';
      final c = FaviconFetcher.parseIconLinks(html, page);
      expect(c.map((e) => e.url.toString()).toSet(), {
        'https://static.example.com/s/i.png',
        'https://example.com/x.png',
      });
    });

    test('larger PNG beats smaller PNG', () {
      const html =
          '<link rel="icon" sizes="16x16" href="/16.png">'
          '<link rel="icon" sizes="192x192" href="/192.png">';
      final c = FaviconFetcher.parseIconLinks(html, page);
      expect(c.first.url.path, '/192.png');
    });
  });

  group('normalizeRaster', () {
    test('ICO is decoded (largest frame) and re-encoded as PNG', () {
      final png = FaviconFetcher.normalizeRaster(_ico(48))!;
      final back = img.decodePng(png)!;
      expect(back.width, 48);
    });
    test('large PNG is downscaled to 128 px', () {
      final back = img.decodePng(FaviconFetcher.normalizeRaster(_png(512))!)!;
      expect(back.width, 128);
    });
    test('HTML/JSON garbage is rejected', () {
      expect(
        FaviconFetcher.normalizeRaster(
          Uint8List.fromList(utf8.encode('{"error":"unauthorized"}')),
        ),
        isNull,
      );
    });
  });

  group('fetch (mocked network)', () {
    test('API host (401) → falls back to the root domain favicon', () async {
      final requested = <String>[];
      final client = MockClient((req) async {
        requested.add(req.url.toString());
        switch (req.url.toString()) {
          case 'https://deepseek.com/':
            return http.Response(
              '<html><head><link rel="icon" href="/favicon.ico" '
              'type="image/x-icon" sizes="225x225"/></head></html>',
              200,
              headers: {'content-type': 'text/html'},
            );
          case 'https://deepseek.com/favicon.ico':
            return http.Response.bytes(
              _ico(64),
              200,
              headers: {'content-type': 'image/vnd.microsoft.icon'},
            );
          default:
            return http.Response('{"error":"Authentication Fails"}', 401);
        }
      });
      final icon = await FaviconFetcher(
        client,
        psl,
      ).fetch('https://api.deepseek.com/v1');
      expect(icon, isNotNull);
      expect(icon!.isSvg, isFalse);
      expect(img.decodePng(icon.bytes)!.width, 64);
      expect(requested.first, 'https://deepseek.com/');
      expect(
        requested.any((u) => u.contains('api.deepseek.com')),
        isFalse,
        reason: 'исходный хост пробуется последним и не понадобился',
      );
    });

    test('host order when nothing is found: root, www, original', () async {
      final requested = <String>[];
      final client = MockClient((req) async {
        requested.add(req.url.toString());
        return http.Response('nope', 404);
      });
      final icon = await FaviconFetcher(
        client,
        psl,
      ).fetch('https://api.example.co.uk/x');
      expect(icon, isNull);
      expect(requested, [
        'https://example.co.uk/',
        'https://example.co.uk/favicon.ico',
        'https://www.example.co.uk/',
        'https://www.example.co.uk/favicon.ico',
        'https://api.example.co.uk/',
        'https://api.example.co.uk/favicon.ico',
      ]);
    });

    test(
      'redirects are followed and http Location is upgraded to https',
      () async {
        final client = MockClient((req) async {
          final u = req.url.toString();
          if (u == 'https://example.com/') {
            return http.Response(
              '',
              301,
              headers: {'location': 'http://www.example.com/home'},
            );
          }
          if (u == 'https://www.example.com/home') {
            return http.Response('<link rel="icon" href="/i.png">', 200);
          }
          if (u == 'https://www.example.com/i.png') {
            return http.Response.bytes(_png(32), 200);
          }
          if (req.url.scheme == 'http') fail('cleartext request: $u');
          return http.Response('', 404);
        });
        final icon = await FaviconFetcher(client, psl).fetch('example.com');
        expect(icon?.source.toString(), 'https://www.example.com/i.png');
      },
    );

    test('SVG is used only when no raster icon exists', () async {
      final client = MockClient((req) async {
        final u = req.url.toString();
        if (u == 'https://example.com/') {
          return http.Response('<link rel="icon" href="/i.svg">', 200);
        }
        if (u == 'https://example.com/i.svg') {
          return http.Response(
            _svg,
            200,
            headers: {'content-type': 'image/svg+xml'},
          );
        }
        return http.Response('', 404);
      });
      final icon = await FaviconFetcher(client, psl).fetch('example.com');
      expect(icon?.isSvg, isTrue);
    });

    test('SVG is skipped when /favicon.ico exists', () async {
      final client = MockClient((req) async {
        final u = req.url.toString();
        if (u == 'https://example.com/') {
          return http.Response('<link rel="icon" href="/i.svg">', 200);
        }
        if (u == 'https://example.com/i.svg') {
          return http.Response(_svg, 200);
        }
        if (u == 'https://example.com/favicon.ico') {
          return http.Response.bytes(_ico(32), 200);
        }
        return http.Response('', 404);
      });
      final icon = await FaviconFetcher(client, psl).fetch('example.com');
      expect(icon?.isSvg, isFalse);
    });
  });
}
