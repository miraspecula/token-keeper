import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'container.dart';

/// Файловое хранилище: один зашифрованный JSON-контейнер.
/// Запись атомарная: сначала .tmp с flush, затем rename поверх основного файла,
/// чтобы внезапное завершение процесса не оставило полузаписанный контейнер.
class VaultStore {
  static const String fileName = 'vault.tkenc';
  static const String tmpFileName = 'vault.tkenc.tmp';

  static Future<File> vaultFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$fileName');
  }

  static Future<bool> exists() async => (await vaultFile()).existsSync();

  static Future<void> save(VaultContainer c) async {
    final f = await vaultFile();
    final tmp = File('${f.parent.path}/$tmpFileName');
    await tmp.writeAsString(c.serialize(), flush: true);
    await tmp.rename(f.path);
  }

  static Future<VaultContainer> load() async {
    final f = await vaultFile();
    return VaultContainer.parse(await f.readAsString());
  }

  static Future<void> delete() async {
    final f = await vaultFile();
    if (await f.exists()) await f.delete();
    final tmp = File('${f.parent.path}/$tmpFileName');
    if (await tmp.exists()) await tmp.delete();
  }
}
