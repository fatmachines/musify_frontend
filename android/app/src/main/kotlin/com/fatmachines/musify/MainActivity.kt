package com.fatmachines.musify

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service shares this activity's Flutter engine with its background
// playback service.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Back on Home: off to the background like other apps, not closed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musify/app")
            .setMethodCallHandler { call, result ->
                if (call.method == "toBackground") {
                    moveTaskToBack(true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
