package com.shitmof.private_manga_reader

import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "private_manga_reader/storage",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getFreeSpace") {
                val stats = StatFs(filesDir.absolutePath)
                result.success(stats.availableBytes)
            } else {
                result.notImplemented()
            }
        }
    }
}
