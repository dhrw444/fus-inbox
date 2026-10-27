package com.yg.fusinbox

import android.app.Activity
import android.webkit.WebView
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import java.util.concurrent.Executor

/**
 * 把 WebView 的流量改走代理。
 *
 * ## 为什么必须原生
 *
 * `webview_flutter_android` 4.14.1 **没有暴露** ProxyController。
 * 翻过它的 `lib/src/`，只有 `platform_views_service_proxy.dart`
 * （那是 Pigeon 的实例代理，不是网络代理）。
 * 所以只能自己走 MethodChannel 调 `androidx.webkit.ProxyController`。
 *
 * ## 只支持 HTTP/HTTPS
 *
 * `ProxyController.setProxyOverride` 的 `ProxyConfig.Builder` 只认
 * `addProxyRule("host:port")` 这种 HTTP 代理形态。传 SOCKS5 进去
 * 系统不会报错，但**流量根本不会走代理** —— 静默失效，比报错更难查。
 *
 * 所以 SOCKS5 由 Dart 侧的本地 HTTP 桥处理（见 local_http_bridge.dart）：
 * 本机起一个 HTTP 代理，CONNECT 进来后自己跟远端做 SOCKS5 握手。
 * WebView 只需要指向 `127.0.0.1:<桥端口>`。
 *
 * ## 依赖版本
 *
 * `androidx.webkit.ProxyController` 需要 `WebViewFeature.PROXY_OVERRIDE`。
 * 老内核上不支持，这时返回 false 让上层降级为直连 ——
 * 硬设会抛异常，不如显式告诉用户「这台机子不支持」。
 */
class ProxyControllerBridge(private val activity: Activity) {

    /**
     * 让 WebView 走 `host:port` 的 HTTP 代理。
     *
     * `bypass` 是直连名单，一般给本机回环。
     *
     * 返回 true 表示真的设上了。false 表示内核不支持或设置失败，
     * 上层据此决定要不要降级。
     */
    fun applyHttpProxy(host: String, port: Int, bypass: List<String>): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            return false
        }
        if (host.isEmpty() || port <= 0) return false
        return try {
            // 只加这一条代理规则，**绝不能加 .addDirect()**。
            //
            // addDirect() 不是「本机回环绕过」，它往规则表里塞一条 DIRECT
            // 回退（androidx 源码：addDirect → addDirect(MATCH_ALL_SCHEMES)
            // → mProxyRules.add(new ProxyRule(MATCH_ALL_SCHEMES, DIRECT))）。
            // 官方文档原话：多条 proxyRule 是「前一条不响应时的后备」，
            // 所以上游代理一死，WebView 会自动改走直连把请求发出去 ——
            // 页面照常打开、没有任何报错，而真实 IP 已经暴露给站点。
            // 那正是这个模块唯一要防的事。
            //
            // 回环绕过是下面 addBypassRule 的活：bypass 按目标主机匹配，
            // 本来就不会把 127.0.0.1 的流量引回代理。
            val builder = ProxyConfig.Builder()
                .addProxyRule("$host:$port")
            for (item in bypass) {
                val trimmed = item.trim()
                if (trimmed.isNotEmpty()) builder.addBypassRule(trimmed)
            }
            val config = builder.build()
            // setProxyOverride 的 executor 用来回调结果。这里不需要
            // 结果，给一个空实现 —— 但必须给，传 null 会 NPE。
            val executor = Executor { runnable -> activity.runOnUiThread(runnable) }
            ProxyController.getInstance().setProxyOverride(config, executor) {}
            true
        } catch (error: Exception) {
            false
        }
    }

    /** 清掉代理，恢复直连。 */
    fun clearProxy(): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            return false
        }
        return try {
            val executor = Executor { runnable -> activity.runOnUiThread(runnable) }
            ProxyController.getInstance().clearProxyOverride(executor) {}
            true
        } catch (error: Exception) {
            false
        }
    }

    /** 这台设备的内核支持不支持代理覆盖。 */
    fun supportsProxy(): Boolean =
        WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)

    /**
     * 系统 WebView 的版本号，给用户排查用。
     *
     * 代理覆盖在很老的内核上没有，用户看到 false 时得知道
     * 自己机器上到底是什么版本。
     */
    fun webViewVersion(): String {
        return try {
            val info = WebView.getCurrentWebViewPackage()
            info?.versionName ?: "unknown"
        } catch (error: Exception) {
            "unknown"
        }
    }
}
