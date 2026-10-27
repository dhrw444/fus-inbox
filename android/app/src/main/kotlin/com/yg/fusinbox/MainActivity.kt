package com.yg.fusinbox

import android.app.Activity
import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var backupResult: MethodChannel.Result? = null
    private val backupRequestCode = 4102

    /// 读某个 URL 下的全部 cookie，包括 HttpOnly。
    ///
    /// 为什么必须走原生：`cf_clearance` 是 **HttpOnly**，JS 的
    /// `document.cookie` 永远读不到它。webview_flutter 也没有暴露读
    /// cookie 的 API。而 `cf_clearance` 恰恰是「Cloudflare 验证真过了」
    /// 的唯一可靠证据——只看 DOM 猜（挑战容器消失、有消息节点）
    /// 会把导航栏和广告当成通过，之前那版就是这么误判的。
    ///
    /// `CookieManager.getCookie(url)` 返回的是 `a=1; b=2` 这种串，
    /// 这里解析成 map 交给 Dart，方便按名字查。
    private fun readCookies(url: String): Map<String, String> {
        val out = mutableMapOf<String, String>()
        try {
            val raw = android.webkit.CookieManager.getInstance().getCookie(url)
            raw?.split(';')?.forEach { part ->
                val idx = part.indexOf('=')
                if (idx <= 0) return@forEach
                val name = part.substring(0, idx).trim()
                val value = part.substring(idx + 1).trim()
                if (name.isNotEmpty()) out[name] = value
            }
        } catch (error: Exception) {
            // 读失败返回空 map：调用方据此判断「没拿到」，
            // 而不是误以为「验证没通过」。
        }
        return out
    }

    /// 设备的真实浏览器身份。
    ///
    /// 为什么要走原生拿：Cloudflare 判断「是不是真浏览器」靠的是
    /// **UA 与 client hints 是否自洽**。WebView 的 Sec-CH-UA 由引擎按
    /// 真实内核版本发出，改不掉。所以 Dart 侧如果自己编一个 Chrome
    /// 版本塞进 UA，就会出现「UA 说 120、Sec-CH-UA 说 141」的撕裂，
    /// 这比不伪装更容易被判机器人。
    ///
    /// 唯一自洽的做法：UA 用 WebView 自己报的那串
    /// （WebSettings.getDefaultUserAgent，含真实机型串与真实版本），
    /// client hints 用同一份版本号。
    private fun deviceProfile(): Map<String, Any?> {
        val ua: String? = try {
            android.webkit.WebSettings.getDefaultUserAgent(this)
        } catch (error: Exception) {
            null
        }
        // WebView 的默认 UA 长这样：
        //   Mozilla/5.0 (Linux; Android 14; SM-S918B Build/UP1A...; wv)
        //   AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0
        //   Chrome/141.0.7390.122 Mobile Safari/537.36
        // 注意中间那段 "Version/4.0" 和 "; wv" 标记 —— 那是 WebView
        // 的招牌。真 Chrome 没有。所以这里不能直接拿去当 UA，
        // 必须先把 WebView 特征剥掉，保留机型串和 Chrome 版本。
        val chrome = Regex("Chrome/([\\d.]+)").find(ua ?: "")?.groupValues?.get(1)
        return mapOf(
            "userAgent" to ua,
            "chromeVersion" to chrome,
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "release" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fusinbox/theme")
            .setMethodCallHandler { call, result ->
                if (call.method != "getColorSchemes") {
                    result.notImplemented()
                } else {
                    try {
                        result.success(systemColorSchemes(this))
                    } catch (error: Exception) {
                        result.error("colors_unavailable", "Could not read Android color roles", null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fusinbox/webview")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidSdkVersion" -> result.success(Build.VERSION.SDK_INT)
                    "getDeviceProfile" -> result.success(deviceProfile())
                    "getCookies" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            result.success(readCookies(url))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fusinbox/bookmark_backup")
            .setMethodCallHandler { call, result ->
                if (call.method != "openBackup") {
                    result.notImplemented()
                } else if (backupResult != null) {
                    result.error("busy", "A backup picker is already open", null)
                } else {
                    backupResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES,
                                arrayOf("application/json", "text/plain", "application/octet-stream"))
                        }
                        startActivityForResult(intent, backupRequestCode)
                    } catch (error: Exception) {
                        backupResult = null
                        result.error("picker_failed", "Could not open the backup picker", null)
                    }
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != backupRequestCode) return
        val result = backupResult ?: return
        backupResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        thread(name = "bookmark-backup") {
            try {
                // ponytail: 1 MiB backups; raise with the library capacity if needed.
                val maxBytes = 1024 * 1024
                val bytes = ByteArray(maxBytes + 1)
                var size = 0
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("Backup could not be opened")
                input.use {
                    while (size < bytes.size) {
                        val count = it.read(bytes, size, bytes.size - size)
                        if (count < 0) break
                        size += count
                    }
                }
                require(size <= maxBytes) { "Backup is too large" }
                val backup = Charsets.UTF_8.newDecoder()
                    .decode(ByteBuffer.wrap(bytes, 0, size)).toString()
                runOnUiThread { result.success(backup) }
            } catch (error: Exception) {
                runOnUiThread { result.error("read_failed", "Could not read this backup file", null) }
            }
        }
    }
}
