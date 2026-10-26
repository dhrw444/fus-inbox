# Changelog

本项目的所有重要变更记录在这里。

## [Unreleased]

### Changed

- 从底层项目剥离文章阅读器、书签、历史、镜像切换、分享接管等与接码无关的功能，
  只保留号码目录、收件箱与收藏三条主线。
- 应用身份统一：`applicationId` / `namespace` / Dart 包名均为 `fusinbox` 系列，
  启动图标、应用名、README 一并替换。
- 收件箱的 WebView 改为复用 `core/webview` 的通用工厂，不再依赖阅读器模块。

### Fixed

- 收件箱 WebView 增加主机白名单：`FusInbox` 通道只对 `freeussms.com` 的页面开放。
- 页面销毁时释放 WebView 引擎并断开状态回调。
- 验证码兜底提取增加语义门，避免把订单号、金额当成验证码。
- 注入脚本改为单个 Future 缓存，首屏不再重复读取资源。
- 号码目录解析失败时显式报错，不再显示成「没有号码」。
