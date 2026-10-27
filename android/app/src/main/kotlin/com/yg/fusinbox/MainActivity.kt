package com.yg.fusinbox

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.webkit.WebView
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var backupResult: MethodChannel.Result? = null
    private val backupRequestCode = 4102

    /// 代理控制。WebView 的 ProxyController 只能原生调。
    private val proxyBridge by lazy { ProxyControllerBridge(this) }

    /// 把浏览器能力垫片装进 WebView。
    ///
    /// ## 为什么必须走原生，不能在 Dart 侧 runJavaScript
    ///
    /// `addDocumentStartJavaScript` 的注入时机是「文档创建后、
    /// **页面任何脚本执行前**」。站点自己的 reader.js / live.js /
    /// Turnstile 都在这个时间点之后才会读 navigator，所以它们看到的
    /// 已经是补齐后的能力。
    ///
    /// 用 Dart 的 `runJavaScript` 做不到这一点：那时候站点脚本早就
    /// 跑完了，Turnstile 已经拿着「这是 WebView」的结论做完判定。
    ///
    /// ## 补的是什么
    ///
    /// Android System WebView 内核不提供三样真 Chrome 必有的东西：
    /// `navigator.userAgentData`、`window.chrome`、非空的
    /// `navigator.plugins`。缺任何一样，UA 写得多像都没用 ——
    /// 这正是「只换 UA 反而更容易被风控」的原因。
    ///
    /// 所有值都由调用方从 **同一份身份** 传进来，保证 UA、
    /// client hints、垫片三者版本号一致。一旦对不上，垫片自己
    /// 就成了新的矛盾点。
    private fun installBrowserShim(args: Map<*, *>?): Boolean {
        return try {
            val webView = findWebView() ?: return false
            val major = args?.get("chromeMajor") as? String ?: ""
            val full = args["appVersion"] as? String ?: ""
            // 这几个值现在只是**兜底**，缺了不该拒绝安装。
            //
            // 垫片已经从 navigator.userAgent 自己推身份了（见
            // BrowserShim.kt 里的推导段），参数只在 UA 完全解不出来时
            // 才会被用上。所以「缺参数 = 不装垫片」是过度反应：
            // 装不上垫片意味着 window.chrome / navigator.plugins 也一起没了，
            // 那两个比 client hints 更要紧，代价比兜底值不全大得多。
            val platformVersion = args["platformVersion"] as? String ?: ""
            val platform = args["platform"] as? String ?: "Android"
            val model = args["model"] as? String ?: ""
            val isMobile = args["isMobile"] as? Boolean ?: true

            val script = buildBrowserShim(
                major,
                full,
                platformVersion,
                platform,
                model,
                isMobile,
            )

            // FEATURE_DOCUMENT_START_SCRIPT 在 WebView 内核 89+ 才有。
            // 老内核返回 false，页面照常打开，只是没有垫片。
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                return false
            }
            WebViewCompat.addDocumentStartJavaScript(webView, script, setOf("*"))
            true
        } catch (error: Exception) {
            false
        }
    }

    /// 把 client hints 也改成我们声称的身份。
    ///
    /// **为什么必须做**：WebView 发出的 `Sec-CH-UA*` 请求头由引擎按
    /// **真实内核版本**生成，而 UA 字符串是我们自己设的。身份在真实内核
    /// 附近浮动 ±2 之后（见 browser_identity.dart 的 `_kernelMajor`），
    /// 「UA 说 Chrome/143、Sec-CH-UA 头说 141」就成立 —— 撕裂面从
    /// 「版本号乱编」变成「UA 与请求头不一致」，而 Cloudflare 恰好能同时
    /// 看到这两处。本文件上面 `deviceProfile()` 那段注释担心的正是这件事，
    /// 当年是靠「身份钉死在内核版本上」绕开的，现在有了真正的解法。
    ///
    /// 垫片（BrowserShim）只改了页面里 JS 读到的 `navigator.userAgentData`，
    /// **改不了 HTTP 头**。这里是唯一能改头的地方。
    ///
    /// 三份数据必须同源：设进去的 UA、这里的 metadata、垫片里的
    /// BRANDS / FULL_LIST —— 全部由 Dart 侧同一组参数生成。
    ///
    /// @return 是否真的设上了。false 不是错误：老内核不支持这个特性时
    ///         只能靠「身份不偏离内核」兜底。
    private fun applyUserAgentMetadata(args: Map<*, *>?): Boolean {
        if (args == null) return false
        val major = args["chromeMajor"] as? String ?: return false
        val full = args["appVersion"] as? String ?: return false
        val platformVersion = args["platformVersion"] as? String ?: return false
        val platform = args["platform"] as? String ?: "Android"
        val model = args["model"] as? String ?: ""
        val isMobile = args["isMobile"] as? Boolean ?: true
        if (major.isBlank() || full.isBlank()) return false
        // BrandVersion.Builder.build() 对空串会抛 IllegalArgumentException，
        // 这里先挡一道，别让一个空机型串把整条通道打挂。
        val pv = if (platformVersion.contains('.')) platformVersion else
            "$platformVersion.0.0"

        val webView = findWebView() ?: return false
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
            return false
        }
        return try {
            // GREASE 占位品牌。真 Chrome 的 sec-ch-ua 里必有这么一项，
            // 缺了反而是特征。必须与 BrowserShim.kt 里的 BRANDS / FULL_LIST
            // 逐字同值 —— 一处改了另一处没改，就又造出一个不一致。
            val brands = listOf(
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand("Chromium")
                    .setMajorVersion(major)
                    .setFullVersion(full)
                    .build(),
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand("Google Chrome")
                    .setMajorVersion(major)
                    .setFullVersion(full)
                    .build(),
                UserAgentMetadata.BrandVersion.Builder()
                    .setBrand("Not?A_Brand")
                    .setMajorVersion("99")
                    .setFullVersion("99.0.0.0")
                    .build(),
            )
            val metadata = UserAgentMetadata.Builder()
                .setBrandVersionList(brands)
                .setFullVersion(full)
                .setPlatform(platform)
                .setPlatformVersion(pv)
                .setArchitecture("arm")
                // 传字面量 64：这个类里**没有** BITNESS_64 常量
                // （javap 过 1.14.0 的 aar，只有 BITNESS_DEFAULT = 0），
                // 官方文档里那行示例是错的。
                .setBitness(64)
                .setModel(model)
                .setMobile(isMobile)
                .setWow64(false)
                .build()
            WebSettingsCompat.setUserAgentMetadata(webView.settings, metadata)
            true
        } catch (error: Exception) {
            // 内核版本够新但具体实现不认某个字段时会走到这里。
            // 设不上也不该崩 —— 页面照常能用，只是回到「不偏离内核」的兜底。
            false
        }
    }

    /// 找到当前 Activity 里的 WebView 实例。
    ///
    /// flutter 的 webview_flutter 把 WebView 挂在自己的 platform view
    /// 树里，没有公开的引用。这里遍历 content view 找第一个 WebView。
    private fun findWebView(): WebView? {
        return try {
            val root = findViewById<android.view.View>(android.R.id.content)
            val found = mutableListOf<WebView>()
            fun walk(view: android.view.View?) {
                if (view == null || found.isNotEmpty()) return
                if (view is WebView) { found.add(view); return }
                if (view is android.view.ViewGroup) {
                    for (i in 0 until view.childCount) walk(view.getChildAt(i))
                }
            }
            walk(root)
            found.firstOrNull()
        } catch (error: Exception) {
            null
        }
    }

    /// 清空 WebView 的全部站点数据。
    ///
    /// ## 为什么必须清，不能只换 UA
    ///
    /// 站点把访客身份绑在一对 ECDSA 密钥上，密钥存在 IndexedDB
    /// （`fus-reader-v1`）。每次请求的 `X-FUS-Proof` 都用这把私钥签名，
    /// 服务端据此认出「还是那个访客」。
    ///
    /// 只改 User-Agent 的话：UA 变了，密钥没变，服务端看到的仍然是
    /// 同一个身份 —— 换了个马甲而已，配额、限流、信誉全都跟着走。
    ///
    /// 真正的「换一个浏览器」= cookie + localStorage + IndexedDB
    /// 全部清空，让站点在下次加载时重新生成密钥对。
    ///
    /// 注意清的只有 **WebView 的站点数据**。App 自己的 SharedPreferences
    /// （号码目录缓存、收录时间、译文缓存）完全不受影响。
    ///
    /// IndexedDB 没有公开的清除 API，由 Dart 侧在页面里用
    /// `indexedDB.deleteDatabase()` 处理，这里负责剩下三样。
    private fun clearBrowsingDataAsync(result: MethodChannel.Result) {
        // 回给 Dart 的判定，沿用原来的语义：**有没有抛异常**。
        // 不用回调里那个 Boolean —— 「本来就没 cookie」也可能回 false，
        // 那会把一次正常清理误报成「没清干净」。
        val ok = java.util.concurrent.atomic.AtomicBoolean(true)
        try {
            // localStorage / sessionStorage 全站点清空。
            android.webkit.WebStorage.getInstance().deleteAllData()
            // HTTP 认证凭据，顺手一起。
            android.webkit.WebViewDatabase.getInstance(this)
                .clearHttpAuthUsernamePassword()
        } catch (error: Exception) {
            // 原先这里会冒泡到外层 catch 返回 false —— 语义保持一致：
            // Dart 侧会据此弹「站点数据没清干净」的警告。
            ok.set(false)
        }

        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        // 只回复一次 —— MethodChannel.Result 二次调用会抛异常。
        val finish = { success: Boolean ->
            if (done.compareAndSet(false, true)) {
                handler.post { result.success(success) }
            }
        }
        try {
            // removeAllCookies 要 ValueCallback<Boolean>。这是 Java 接口，
            // Kotlin 里不能写 lambda 直接转换，必须显式实现对象。
            //
            // **不要在回调里只 countDown 然后 await** —— 这个函数跑在
            // MethodChannel 的处理线程上，也就是**平台主线程**：
            // await 等于把 UI 冻住（这里原先等 2 秒），而换身份一定会
            // 走到这里，所以每次换号都必然卡一下，极端情况还有 ANR 风险。
            //
            // 正确做法是**异步回复**：MethodChannel.Result 可以从任意
            // 线程调用，把 result 交出去、回调来了再 success。
            // 顺序保证不变 —— Dart 侧 await 到的那一刻 cookie 确实已经
            // 清完了（原来靠 latch 保证的正是这一点）。
            val callback = object : android.webkit.ValueCallback<Boolean> {
                override fun onReceiveValue(value: Boolean?) {
                    finish(ok.get())
                }
            }
            android.webkit.CookieManager.getInstance().removeAllCookies(callback)
            // 兜底：WebView 偶尔不回调（进程刚起、内核还在初始化）。
            // 2 秒后自己收尾，时长与原实现一致，但**不冻 UI**；
            // 且照原样算成功（原实现的 latch 超时也是继续往下返回 true）。
            handler.postDelayed({ finish(ok.get()) }, 2000)
        } catch (error: Exception) {
            finish(false)
        }
    }

    /// 读某个 URL 下的全部 cookie，包括 HttpOnly。
    ///
    /// 为什么必须走原生：`cf_clearance` 是 **HttpOnly**，JS 的
    /// `document.cookie` 永远读不到它。webview_flutter 也没有暴露读
    /// cookie 的 API。而 `cf_clearance` 恰恰是「Cloudflare 验证真过了」
    /// 的唯一可靠证据——只看 DOM 猜（挑战容器消失、有消息节点）
    /// 会把导航栏和广告当成通过，之前那版就是这么误判的。
    ///
    /// 交给系统浏览器打开一个链接。
    ///
    /// 用 ACTION_VIEW 而不是 WebView —— 用户点仓库链接是想在真浏览器
    /// 里看，不是想在 App 内嵌的 WebView 里再开一个页面。
    ///
    /// 返回 false 表示设备上没有能处理这个 URL 的应用，调用方据此
    /// 提示用户，而不是静默失败。
    private fun openExternalUrl(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                // 从非 Activity 上下文启动时要带，这里是 Activity，
                // 但显式声明能避免某些 ROM 的歧义。
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (error: Exception) {
            false
        }
    }

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
                    "installBrowserShim" -> {
                        val args = call.arguments as? Map<*, *>
                        result.success(installBrowserShim(args))
                    }
                    "applyUserAgentMetadata" -> {
                        val args = call.arguments as? Map<*, *>
                        result.success(applyUserAgentMetadata(args))
                    }
                    // 注意这里**不**同步回复：cookie 是异步 API，
                    // 回复要等到真的清完（见 clearBrowsingDataAsync）。
                    "clearBrowsingData" -> clearBrowsingDataAsync(result)
                    "getCookies" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            result.success(readCookies(url))
                        }
                    }
                    // 代理相关。ProxyController 没有 Dart 侧封装，
                    // 只能从这里出去。注意不能另开一个 MethodChannel
                    // 挂同名通道 —— setMethodCallHandler 是覆盖式的，
                    // 后设的那个会把这里的整个 handler 顶掉。
                    "applyProxy" -> {
                        val host = call.argument<String>("host") ?: ""
                        val port = call.argument<Int>("port") ?: 0
                        val bypass =
                            (call.argument<List<String>>("bypass") ?: emptyList())
                        result.success(proxyBridge.applyHttpProxy(host, port, bypass))
                    }
                    "clearProxy" -> result.success(proxyBridge.clearProxy())
                    "supportsProxy" -> result.success(proxyBridge.supportsProxy())
                    "webViewVersion" -> result.success(proxyBridge.webViewVersion())
                    // 用系统浏览器打开外部链接。不用 url_launcher 是
                    // 为了不动 pubspec.lock —— CI 跑 --enforce-lockfile，
                    // 加依赖就得同步改锁文件，不值当。
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url is required", null)
                        } else {
                            result.success(openExternalUrl(url))
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
