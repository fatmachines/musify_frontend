package com.fatmachines.musify

import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service shares this activity's Flutter engine with its background
// playback service.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musify/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Back on Home: off to the background like other apps,
                    // not closed.
                    "toBackground" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    // The Android version, and the phone's name as the user
                    // set it ("Nothing Phone (3a) Lite"), else its model.
                    "device" -> {
                        val name = Settings.Global.getString(contentResolver, "device_name")
                        result.success(
                            mapOf(
                                "sdk" to Build.VERSION.SDK_INT,
                                "name" to (if (name.isNullOrBlank()) Build.MODEL else name),
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
