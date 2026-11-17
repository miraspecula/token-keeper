import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_keeper/favicon_fetcher.dart';
import 'package:token_keeper/public_suffix.dart';

void main() {
  // Тот же файл, что вшит в приложение как ассет.
  final psl = PublicSuffixList.parse(
    File('assets/public_suffix_list.dat').readAsStringSync(),
  );

  test('bundled list is loaded (ICANN + PRIVATE sections)', () {
    expect(psl.ruleCount, greaterThan(9000));
  });

  group('registrableDomain (eTLD+1)', () {
    final cases = <String, String?>{
      'api.deepseek.com': 'deepseek.com',
      'deepseek.com': 'deepseek.com',
      'www.deepseek.com': 'deepseek.com',
      'API.DeepSeek.COM.': 'deepseek.com',
      'a.b.c.example.com': 'example.com',
      'www.bbc.co.uk': 'bbc.co.uk',
      'api.service.co.uk': 'service.co.uk',
      'shop.example.com.ru': 'example.com.ru',
      'yandex.ru': 'yandex.ru',
      'api.yandex.ru': 'yandex.ru',
      'carlsonchik.github.io': 'carlsonchik.github.io', // PRIVATE section
      'docs.carlsonchik.github.io': 'carlsonchik.github.io',
      'foo.bar.ck': 'foo.bar.ck', // *.ck
      'www.ck': 'www.ck', // !www.ck
      'a.www.ck': 'www.ck',
      'github.io': null, // сам публичный суффикс
      'co.uk': null,
      'com': null,
      'localhost': null,
      '192.168.1.10': null,
      '': null,
    };
    cases.forEach((host, expected) {
      test('$host -> $expected', () {
        expect(psl.registrableDomain(host), expected);
      });
    });
  });

  group('candidateHosts order: root, www.root, original host last', () {
    test('api subdomain', () {
      expect(FaviconFetcher.candidateHosts('api.deepseek.com', psl), [
        'deepseek.com',
        'www.deepseek.com',
        'api.deepseek.com',
      ]);
    });
    test('bare root has no duplicates', () {
      expect(FaviconFetcher.candidateHosts('deepseek.com', psl), [
        'deepseek.com',
        'www.deepseek.com',
      ]);
    });
    test('www host', () {
      expect(FaviconFetcher.candidateHosts('www.bbc.co.uk', psl), [
        'bbc.co.uk',
        'www.bbc.co.uk',
      ]);
    });
    test('co.uk subdomain', () {
      expect(FaviconFetcher.candidateHosts('api.service.co.uk', psl), [
        'service.co.uk',
        'www.service.co.uk',
        'api.service.co.uk',
      ]);
    });
    test('github.io user site keeps the user label', () {
      expect(FaviconFetcher.candidateHosts('docs.user.github.io', psl), [
        'user.github.io',
        'www.user.github.io',
        'docs.user.github.io',
      ]);
    });
    test('IP address — only itself', () {
      expect(FaviconFetcher.candidateHosts('10.0.0.1', psl), ['10.0.0.1']);
    });
    test('hostOf parses URLs and bare domains', () {
      expect(
        FaviconFetcher.hostOf('https://api.deepseek.com/v1'),
        'api.deepseek.com',
      );
      expect(
        FaviconFetcher.hostOf('platform.openai.com'),
        'platform.openai.com',
      );
      expect(FaviconFetcher.hostOf('  '), isNull);
    });
  });
}
