package com.shitmof.private_manga_reader

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.ArrayDeque
import java.util.UUID
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

class MainActivity : FlutterFragmentActivity() {
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null
    private var documentsChannel: MethodChannel? = null
    private var pendingMountResult: MethodChannel.Result? = null
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

    private val openMangaDirectory =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            val result = pendingMountResult
            pendingMountResult = null
            if (result == null) return@registerForActivityResult
            if (uri == null) {
                result.success(null)
                return@registerForActivityResult
            }
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: SecurityException) {
                // 某些文档提供者只授予当前会话读取权限，仍可完成本次挂载。
            }
            try {
                val name = DocumentsContract.getTreeDocumentId(uri)
                    .substringAfterLast('/')
                    .substringAfterLast(':')
                    .ifBlank { "本地漫画目录" }
                result.success(
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to name,
                    ),
                )
            } catch (error: Exception) {
                result.error("MOUNT_FAILED", error.message ?: "无法保存目录授权", null)
            }
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "private_manga_reader/local_mount",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> startPickDirectory(result)
                "scanTree" -> runAsync(result) {
                    scanTree(requireUri(call.argument<String>("uri")))
                }
                "listImages" -> runAsync(result) {
                    listImages(requireUri(call.argument<String>("uri")))
                }
                "listZipEntries" -> runAsync(result) {
                    listZipEntries(requireUri(call.argument<String>("uri")))
                }
                "readPage" -> runAsync(result) {
                    readPage(
                        requireUri(call.argument<String>("uri")),
                        call.argument<String>("archiveEntry"),
                    )
                }
                else -> result.notImplemented()
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

    private fun startPickDirectory(result: MethodChannel.Result) {
        if (pendingMountResult != null) {
            result.error("MOUNT_IN_PROGRESS", "已有一个目录选择器正在打开", null)
            return
        }
        pendingMountResult = result
        openMangaDirectory.launch(null)
    }

    private fun requireUri(value: String?): Uri {
        if (value.isNullOrBlank()) throw IllegalArgumentException("目录或文件地址为空")
        return Uri.parse(value)
    }

    private fun runAsync(result: MethodChannel.Result, action: () -> Any?) {
        Thread {
            try {
                val value = action()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("LOCAL_MOUNT_FAILED", error.message ?: "本地挂载读取失败", null)
                }
            }
        }.start()
    }

    private data class DocumentRow(
        val uri: Uri,
        val name: String,
        val mimeType: String,
        val size: Long,
        val lastModified: Long,
        val isDirectory: Boolean,
    )

    private fun listChildren(treeUri: Uri, directoryUri: Uri): List<DocumentRow> {
        val documentId = DocumentsContract.getDocumentId(directoryUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val rows = mutableListOf<DocumentRow>()
        contentResolver.query(childrenUri, columns, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idIndex)
                val mime = cursor.getString(mimeIndex) ?: "application/octet-stream"
                rows.add(
                    DocumentRow(
                        uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id),
                        name = cursor.getString(nameIndex) ?: id.substringAfterLast('/'),
                        mimeType = mime,
                        size = if (cursor.isNull(sizeIndex)) 0L else cursor.getLong(sizeIndex),
                        lastModified = if (cursor.isNull(modifiedIndex)) 0L else cursor.getLong(modifiedIndex),
                        isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
                    ),
                )
            }
        }
        return rows
    }

    private fun scanTree(treeUri: Uri): List<Map<String, Any>> {
        val rootDocument = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val queue = ArrayDeque<Triple<Uri, String, Int>>()
        queue.add(Triple(rootDocument, "", 0))
        val files = mutableListOf<Map<String, Any>>()
        while (queue.isNotEmpty() && files.size < 20000) {
            val (directory, relativeDir, depth) = queue.removeFirst()
            for (child in listChildren(treeUri, directory)) {
                if (child.isDirectory) {
                    if (depth < 12) {
                        val next = if (relativeDir.isEmpty()) child.name else "$relativeDir/${child.name}"
                        queue.add(Triple(child.uri, next, depth + 1))
                    }
                    continue
                }
                if (!isImage(child.name) && !isDirectArchive(child.name)) continue
                files.add(documentMap(child, directory, relativeDir))
                if (files.size >= 20000) break
            }
        }
        return files
    }

    private fun listImages(directoryUri: Uri): List<Map<String, Any>> =
        listChildren(directoryUri, directoryUri)
            .filter { !it.isDirectory && isImage(it.name) }
            .map { row ->
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                contentResolver.openInputStream(row.uri).use { input ->
                    if (input != null) BitmapFactory.decodeStream(input, null, options)
                }
                documentMap(row, directoryUri, "") + mapOf(
                    "width" to options.outWidth.coerceAtLeast(0),
                    "height" to options.outHeight.coerceAtLeast(0),
                )
            }

    private fun documentMap(
        row: DocumentRow,
        parentUri: Uri,
        relativeDir: String,
    ): Map<String, Any> = mapOf(
        "uri" to row.uri.toString(),
        "name" to row.name,
        "mimeType" to row.mimeType,
        "size" to row.size,
        "lastModified" to row.lastModified,
        "parentUri" to parentUri.toString(),
        "relativeDir" to relativeDir,
    )

    private fun listZipEntries(uri: Uri): List<Map<String, Any>> {
        try {
            contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                ZipFile(File("/proc/self/fd/${descriptor.fd}")).use { zip ->
                    return zip.entries().asSequence()
                        .filter { !it.isDirectory && isImage(it.name) }
                        .take(10000)
                        .map { entry ->
                            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            zip.getInputStream(entry).use { input ->
                                BitmapFactory.decodeStream(input, null, options)
                            }
                            mapOf(
                                "name" to entry.name,
                                "size" to entry.size.coerceAtLeast(0L),
                                "width" to options.outWidth.coerceAtLeast(0),
                                "height" to options.outHeight.coerceAtLeast(0),
                            )
                        }
                        .toList()
                }
            }
        } catch (_: Exception) {
            // 某些云盘文档提供者只暴露流；下方退回顺序扫描。
        }
        val result = mutableListOf<Map<String, Any>>()
        contentResolver.openInputStream(uri)?.buffered(1024 * 1024).use { input ->
            requireNotNull(input) { "无法打开漫画压缩包" }
            ZipInputStream(input).use { zip ->
                var entry = zip.nextEntry
                while (entry != null && result.size < 10000) {
                    if (!entry.isDirectory && isImage(entry.name)) {
                        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeStream(zip, null, options)
                        result.add(
                            mapOf(
                                "name" to entry.name,
                                "size" to entry.size.coerceAtLeast(0L),
                                "width" to options.outWidth.coerceAtLeast(0),
                                "height" to options.outHeight.coerceAtLeast(0),
                            ),
                        )
                    }
                    zip.closeEntry()
                    entry = zip.nextEntry
                }
            }
        }
        return result
    }

    private fun readPage(uri: Uri, archiveEntry: String?): ByteArray {
        if (archiveEntry == null) {
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "无法读取图片" }
                return readLimited(input, 128 * 1024 * 1024)
            }
        }
        try {
            contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                ZipFile(File("/proc/self/fd/${descriptor.fd}")).use { zip ->
                    val entry = zip.getEntry(archiveEntry)
                        ?: throw IllegalArgumentException("漫画页已不存在")
                    zip.getInputStream(entry).use { input ->
                        return readLimited(input, 128 * 1024 * 1024)
                    }
                }
            }
        } catch (error: IllegalArgumentException) {
            throw error
        } catch (_: Exception) {
            // 文档提供者不支持随机读取时，退回 ZipInputStream 顺序查找。
        }
        contentResolver.openInputStream(uri)?.buffered(1024 * 1024).use { input ->
            requireNotNull(input) { "无法打开漫画压缩包" }
            ZipInputStream(input).use { zip ->
                var entry = zip.nextEntry
                while (entry != null) {
                    if (!entry.isDirectory && entry.name == archiveEntry) {
                        return readLimited(zip, 128 * 1024 * 1024)
                    }
                    zip.closeEntry()
                    entry = zip.nextEntry
                }
            }
        }
        throw IllegalArgumentException("漫画页已不存在")
    }

    private fun readLimited(input: java.io.InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(256 * 1024)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) throw IllegalArgumentException("单张图片超过 128MB 限制")
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun isImage(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "avif")

    private fun isDirectArchive(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in setOf("zip", "cbz")

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
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) return cursor.getString(0)
            }
        } catch (_: Exception) {
            // DocumentTree 根 URI 不保证实现 OpenableColumns；调用方会使用稳定回退名。
        }
        return uri.lastPathSegment
    }

}
