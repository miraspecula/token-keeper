
import 'package:flutter/services.dart';

/// Результат биометрической операции (имена совпадают с Kotlin-стороной).
enum BioResult { success, cancelled, invalidated, unavailable, noData, error }

class BioUnlock {
  final BioResult result;
  final Uint8List? dek;
  const BioUnlock(this.result, [this.dek]);
}

/// Мост к Android Keystore + BiometricPrompt. Все ошибки гасятся
/// безопасными значениями — канал никогда не роняет приложение.
class PlatformSecurity {
  static const MethodChannel _ch = MethodChannel('token_keeper/security');

  static Future<bool> biometricAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('isBiometricAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<BioResult> enrollBiometric(Uint8List dek) async {
    try {
      final r = await _ch
          .invokeMethod<String>('enrollBiometric', {'dek': dek});
      return _parse(r);
    } on PlatformException {
      return BioResult.error;
    } on MissingPluginException {
      return BioResult.error;
    }
  }

  static Future<BioUnlock> unlockBiometric() async {
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>(
          'unlockBiometric');
      if (m == null) return const BioUnlock(BioResult.error);
      final result = _parse(m['result'] as String?);
      final dek = m['dek'];
      return BioUnlock(
        result,
        result == BioResult.success && dek is Uint8List ? dek : null,
      );
    } on PlatformException {
      return const BioUnlock(BioResult.error);
    } on MissingPluginException {
      return const BioUnlock(BioResult.error);
    }
  }

  static Future<bool> hasBiometricData() async {
    try {
      return await _ch.invokeMethod<bool>('hasBiometricData') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> clearBiometric() async {
    try {
      await _ch.invokeMethod<void>('clearBiometric');
    } on PlatformException {
      // no-op
    } on MissingPluginException {
      // no-op
    }
  }

  static Future<void> setSecureFlag(bool on) async {
    try {
      await _ch.invokeMethod<void>('setSecureFlag', {'on': on});
    } on PlatformException {
      // no-op
    } on MissingPluginException {
      // no-op
    }
  }

  /// Старый MVP хранил DEK в SharedPreferences flutter_secure_storage — стираем.
  static Future<void> wipeLegacySecureStorage() async {
    try {
      await _ch.invokeMethod<void>('wipeLegacySecureStorage');
    } on PlatformException {
      // no-op
    } on MissingPluginException {
      // no-op
    }
  }

  static BioResult _parse(String? name) {
    for (final r in BioResult.values) {
      if (r.name == name) return r;
    }
    return BioResult.error;
  }
}
