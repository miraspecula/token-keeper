// Реальная сеть. Запуск: TK_NETWORK_TESTS=1 flutter test test/favicon_network_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:token_keeper/favicon_fetcher.dart';
import 'package:token_keeper/public_suffix.dart';

void main() {
  final enabled = Platform.environment['TK_NETWORK_TESTS'] == '1';
  final psl = PublicSuffixList.parse(
    File('assets/public_suffix_list.dat').readAsStringSync(),
  );

  for (final url in [
    'https://api.deepseek.com/v1',
    'https://api.github.com',
    'https://api.openai.com/v1',
  ]) {
    test(
      'real icon for $url',
      () async {
        final client = http.Client();
        try {
          final icon = await FaviconFetcher(client, psl).fetch(url);
          expect(icon, isNotNull, reason: 'icon for $url');
          // ignore: avoid_print
          print(
            '$url -> ${icon!.source} (${icon.isSvg ? 'svg' : 'png'}, '
            '${icon.bytes.length} B)',
          );
          if (!icon.isSvg) {
            final d = img.decodePng(icon.bytes)!;
            // ignore: avoid_print
            print('   decoded ${d.width}x${d.height}');
            if (url.contains('deepseek')) {
              Directory('build').createSync(recursive: true);
              File('build/deepseek_icon.png').writeAsBytesSync(icon.bytes);
            }
          }
        } finally {
          client.close();
        }
      },
      skip: enabled ? false : 'set TK_NETWORK_TESTS=1',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
