import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Настоящие шрифты (Roboto + Material Icons из Flutter SDK) вместо Ahem,
/// чтобы ширина текста в тестах раскладки совпадала с устройством.
Future<void> loadRealFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ?? '/home/box/tools/flutter';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String n) async =>
      ByteData.sublistView(await File('$dir/$n').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final n in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Light.ttf',
    'Roboto-Italic.ttf',
  ]) {
    roboto.addFont(f(n));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(f('MaterialIcons-Regular.otf'))).load();
}
