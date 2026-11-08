package com.kaibao.kaibao_sales

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: (() -> Unit)? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "kaibao/image_album").setMethodCallHandler { call, result ->
            if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
            val pages = call.argument<List<ByteArray>>("pages")
            val name = call.argument<String>("name")?.replace(Regex("[^a-zA-Z0-9_-]"), "_")
            if (pages.isNullOrEmpty() || name == null || pending != null) {
                result.error("invalid", "无法保存图片", null); return@setMethodCallHandler
            }
            val indices = call.argument<List<Int>>("indices") ?: pages.indices.toList()
            val work = {
                Thread {
                    val created = mutableListOf<android.net.Uri>()
                    val files = mutableListOf<File>()
                    val saved = mutableListOf<Int>()
                    try {
                        val group = "$name-${System.currentTimeMillis()}-${java.util.UUID.randomUUID().toString().take(8)}"
                        pages.forEachIndexed { index, bytes ->
                            val filename = "$group-${indices[index] + 1}.png"
                            if (Build.VERSION.SDK_INT >= 29) {
                                val values = ContentValues().apply {
                                    put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/凯堡软装")
                                    put(MediaStore.Images.Media.IS_PENDING, 1)
                                }
                                val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                                    ?: error("无法创建图片")
                                created.add(uri)
                                (contentResolver.openOutputStream(uri) ?: error("无法写入图片")).use { it.write(bytes) }
                                if (contentResolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null) != 1) error("相册发布失败")
                                saved.add(indices[index])
                                created.remove(uri)
                            } else {
                                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "凯堡软装")
                                if (!dir.exists() && !dir.mkdirs()) error("无法创建相册")
                                val file = File(dir, filename)
                                if (!file.createNewFile()) error("图片已存在")
                                files.add(file)
                                file.outputStream().use { it.write(bytes) }
                                val latch = java.util.concurrent.CountDownLatch(1)
                                var scanned = false
                                MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("image/png")) { _, uri -> scanned = uri != null; latch.countDown() }
                                if (!latch.await(30, java.util.concurrent.TimeUnit.SECONDS) || !scanned) error("相册索引失败")
                                saved.add(indices[index])
                                files.remove(file)
                            }
                        }
                        runOnUiThread { result.success(mapOf("saved" to saved, "error" to null)) }
                    } catch (_: Exception) {
                        created.forEach { try { contentResolver.delete(it, null, null) } catch (_: Exception) {} }
                        files.forEach { it.delete() }
                        runOnUiThread { result.success(mapOf("saved" to saved, "error" to "图片保存未完成，请检查权限和空间后重试")) }
                    }
                }.start()
            }
            if (Build.VERSION.SDK_INT < 29 && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                pending = work
                requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 701)
                permissionResult = result
            } else work()
        }
    }
    private var permissionResult: MethodChannel.Result? = null
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code == 701) {
            val work = pending
            pending = null
            val result = permissionResult
            permissionResult = null
            if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) work?.invoke()
            else result?.error("permission", "未允许保存图片", null)
        }
    }
}
