package dev.tokenkeeper.token_keeper

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import java.util.Arrays
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Биометрическая разблокировка: DEK оборачивается ключом AndroidKeyStore,
 * который требует BIOMETRIC_STRONG на каждое использование (CryptoObject).
 */
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val CHANNEL = "token_keeper/security"
        const val KEY_ALIAS = "tk_bio_dek_v2"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val PREFS = "tk_bio"
        const val PREF_IV = "iv"
        const val PREF_CT = "ct"
        const val LEGACY_PREFS = "FlutterSecureStorage"
        const val LEGACY_KEY_PREFS = "FlutterSecureKeyStorage"
        const val GCM_TAG_BITS = 128
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // Ответ ровно один раз, всегда на UI-потоке.
                val replied = AtomicBoolean(false)
                val reply: (Any?) -> Unit = { value ->
                    if (replied.compareAndSet(false, true)) {
                        // На UI-потоке отвечаем синхронно: кодек сериализует
                        // значение сразу, и буфер с DEK можно затереть следом.
                        if (Looper.myLooper() == Looper.getMainLooper()) {
                            result.success(value)
                        } else {
                            mainHandler.post { result.success(value) }
                        }
                    }
                }
                try {
                    when (call.method) {
                        "isBiometricAvailable" -> reply(isBiometricAvailable())
                        "hasBiometricData" -> reply(hasBiometricData())
                        "clearBiometric" -> {
                            clearBiometric()
                            reply(null)
                        }
                        "setSecureFlag" -> {
                            val on = call.argument<Boolean>("on") ?: false
                            setSecureFlag(on)
                            reply(null)
                        }
                        "wipeLegacySecureStorage" -> {
                            wipeLegacySecureStorage()
                            reply(null)
                        }
                        "enrollBiometric" -> {
                            val dek = call.argument<ByteArray>("dek")
                            if (dek == null || dek.isEmpty()) {
                                reply("error")
                            } else {
                                enrollBiometric(dek, reply)
                            }
                        }
                        "unlockBiometric" -> unlockBiometric(reply)
                        else -> mainHandler.post { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    // Никогда не роняем приложение из-за keystore/крипто.
                    reply(if (call.method == "enrollBiometric") "error"
                          else mapOf("result" to "error"))
                }
            }
    }

    // --- состояние ---

    private fun prefs(): SharedPreferences =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun isBiometricAvailable(): Boolean = try {
        BiometricManager.from(this)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS
    } catch (e: Exception) {
        false
    }

    private fun hasBiometricData(): Boolean {
        val p = prefs()
        return p.contains(PREF_IV) && p.contains(PREF_CT)
    }

    private fun clearBiometric() {
        try {
            val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
            ks.load(null)
            if (ks.containsAlias(KEY_ALIAS)) ks.deleteEntry(KEY_ALIAS)
        } catch (_: Exception) {
        }
        prefs().edit().clear().commit()
    }

    private fun setSecureFlag(on: Boolean) {
        mainHandler.post {
            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun wipeLegacySecureStorage() {
        try {
            // flutter_secure_storage 9: данные в "FlutterSecureStorage",
            // обёрнутый ключ шифрования — в "FlutterSecureKeyStorage".
            for (name in listOf(LEGACY_PREFS, LEGACY_KEY_PREFS)) {
                getSharedPreferences(name, Context.MODE_PRIVATE)
                    .edit().clear().commit()
                deleteSharedPreferences(name)
            }
        } catch (_: Exception) {
        }
    }

    // --- ключ ---

    private fun loadKey(): SecretKey? {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        return ks.getKey(KEY_ALIAS, null) as? SecretKey
    }

    private fun generateKey(): SecretKey {
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true) // API 24+
        if (Build.VERSION.SDK_INT >= 30) {
            builder.setUserAuthenticationParameters(
                0, KeyProperties.AUTH_BIOMETRIC_STRONG
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        val kg = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        kg.init(builder.build())
        return kg.generateKey()
    }

    // --- enroll ---

    private fun enrollBiometric(dek: ByteArray, reply: (Any?) -> Unit) {
        try {
            clearBiometric() // старый ключ и данные долой
            val key = generateKey()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val prompt = buildPrompt(object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    try {
                        val c = result.cryptoObject!!.cipher!!
                        val ct = c.doFinal(dek)
                        val ok = prefs().edit()
                            .putString(PREF_IV, b64(c.iv))
                            .putString(PREF_CT, b64(ct))
                            .commit()
                        reply(if (ok) "success" else "error")
                    } catch (e: Exception) {
                        reply("error")
                    } finally {
                        Arrays.fill(dek, 0.toByte())
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    Arrays.fill(dek, 0.toByte())
                    reply(mapError(errorCode))
                }
                // onAuthenticationFailed: одиночный плохой палец — промпт продолжается, не отвечаем.
            })
            prompt.authenticate(
                promptInfo("Подтвердите включение входа по биометрии"),
                BiometricPrompt.CryptoObject(cipher)
            )
        } catch (e: Exception) {
            Arrays.fill(dek, 0.toByte())
            reply("error")
        }
    }

    // --- unlock ---

    private fun unlockBiometric(reply: (Any?) -> Unit) {
        val p = prefs()
        val ivStr = p.getString(PREF_IV, null)
        val ctStr = p.getString(PREF_CT, null)
        if (ivStr == null || ctStr == null) {
            reply(mapOf("result" to "noData"))
            return
        }
        val cipher: Cipher
        val ct: ByteArray
        try {
            val key = loadKey()
            if (key == null) {
                clearBiometric()
                reply(mapOf("result" to "invalidated"))
                return
            }
            ct = Base64.decode(ctStr, Base64.NO_WRAP)
            val iv = Base64.decode(ivStr, Base64.NO_WRAP)
            cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        } catch (e: Exception) {
            when (e) {
                is KeyPermanentlyInvalidatedException,
                is UnrecoverableKeyException -> {
                    clearBiometric()
                    reply(mapOf("result" to "invalidated"))
                }
                else -> reply(mapOf("result" to "error"))
            }
            return
        }
        try {
            val prompt = buildPrompt(object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    try {
                        val dek = result.cryptoObject!!.cipher!!.doFinal(ct)
                        reply(mapOf("result" to "success", "dek" to dek))
                        Arrays.fill(dek, 0.toByte())
                    } catch (e: Exception) {
                        reply(mapOf("result" to "error"))
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    reply(mapOf("result" to mapError(errorCode)))
                }
            })
            prompt.authenticate(
                promptInfo("Разблокируйте хранилище токенов"),
                BiometricPrompt.CryptoObject(cipher)
            )
        } catch (e: Exception) {
            reply(mapOf("result" to "error"))
        }
    }

    // --- общее ---

    private fun buildPrompt(
        callback: BiometricPrompt.AuthenticationCallback
    ): BiometricPrompt =
        BiometricPrompt(this, { command -> runOnUiThread(command) }, callback)

    private fun promptInfo(subtitle: String): BiometricPrompt.PromptInfo =
        BiometricPrompt.PromptInfo.Builder()
            .setTitle("Token Keeper")
            .setSubtitle(subtitle)
            .setNegativeButtonText("Отмена")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()

    private fun mapError(code: Int): String = when (code) {
        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
        BiometricPrompt.ERROR_USER_CANCELED,
        BiometricPrompt.ERROR_CANCELED -> "cancelled"
        BiometricPrompt.ERROR_NO_BIOMETRICS,
        BiometricPrompt.ERROR_HW_NOT_PRESENT,
        BiometricPrompt.ERROR_HW_UNAVAILABLE -> "unavailable"
        else -> "error"
    }

    private fun b64(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)
}
