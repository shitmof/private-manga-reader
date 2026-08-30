package com.shitmof.private_manga_reader

import android.content.Intent
import android.os.StatFs
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterFragmentActivity() {
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null
    private var documentsChannel: MethodChannel? = null
    private var flutterReadyForArchives = false
    private val pendingArchives = mutableListOf<Map<String, String>>()

    private val createBackupDocument =
        registerForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
            val result = pendingSaveResult
            val sourcePath = pendingSourcePath
            pendingSaveResult = null
            pendingSourcePath = null
            if (result == null) return@registerForActivityResult
            if (uri == null || sourcePath == null) {
                result.success(null)
                return@registerForActivityResult
            }
            Thread {
                try {
                    contentResolver.openOutputStream(uri, "w")!!.use { output ->
                        File(sourcePath).inputStream().buffered().use { input ->
                            input.copyTo(output, bufferSize = 1024 * 1024)
                        }
                    }
                    runOnUiThread { result.success(uri.toString()) }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error("SAVE_FAILED", error.message ?: "无法保存备份", null)
                    }
                }
            }.start()
        }

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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "private_manga_reader/privacy",
        ).setMethodCallHandler { call, result ->
            if (call.method != "setScreenSecure") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val secure = call.arguments as? Boolean ?: false
            if (secure) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            result.success(null)
        }

        documentsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "private_manga_reader/documents",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveFile" -> startSaveFile(call.arguments as? Map<*, *>, result)
                    "getPendingArchives" -> {
                        flutterReadyForArchives = true
                        val archives = pendingArchives.toList()
                        pendingArchives.clear()
                        result.success(archives)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        consumeArchiveIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeArchiveIntent(intent)
    }

    private fun startSaveFile(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("SAVE_IN_PROGRESS", "已有一个备份正在保存", null)
            return
        }
        val sourcePath = arguments?.get("sourcePath") as? String
        val fileName = arguments?.get("fileName") as? String
        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank() || !File(sourcePath).isFile) {
            result.error("INVALID_SOURCE", "备份源文件不存在", null)
            return
        }
        pendingSaveResult = result
        pendingSourcePath = sourcePath
        createBackupDocument.launch(fileName)
    }

    private fun consumeArchiveIntent(sourceIntent: Intent?) {
        if (sourceIntent?.action != Intent.ACTION_VIEW) return
        val uri = sourceIntent.data ?: return
        sourceIntent.data = null
        Thread {
            try {
                val displayName = queryDisplayName(uri) ?: "import-${UUID.randomUUID()}.cbz"
                val safeName = File(displayName).name
                val extension = safeName.substringAfterLast('.', "cbz")
                val target = File(cacheDir, "incoming/${UUID.randomUUID()}.$extension")
                target.parentFile?.mkdirs()
                contentResolver.openInputStream(uri)!!.use { input ->
                    target.outputStream().buffered().use { output ->
                        input.copyTo(output, bufferSize = 1024 * 1024)
                    }
                }
                val payload = mapOf("path" to target.absolutePath, "name" to safeName)
                runOnUiThread {
                    if (flutterReadyForArchives) {
                        documentsChannel?.invokeMethod("archiveOpened", payload)
                    } else {
                        pendingArchives.add(payload)
                    }
                }
            } catch (_: Exception) {
                // Flutter 端仍可通过应用内的文件选择器导入。
            }
        }.start()
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment
    }
}
