/// 自动换出口/换身份的**判定**：给定站点信号，这次该不该动、动哪一半。
///
/// ## 为什么抽出来
///
/// 原来这段判断长在 `IdentityRotator._maybeAutoRotateBody` 里，被
/// `ref.read(proxyProvider)` / `store.note(...)` 包着 —— 想验证「`challenge`
/// 会不会触发换身份」只能靠读代码，或者搭一整套 Riverpod 容器。
/// 抽成纯函数之后，输入是站点信号、输出是决定，没有状态没有 IO。
///
/// ## 判据从哪来
///
/// 三种拒绝来自站点自己的响应头（见 `assets/js/fus_inbox.js` 的
/// `holdFromResponse`）：
///
///   `429 + pause`       → [SiteHoldKind.quota]      配额，记在出口 IP 上
///   `403 + challenge`   → [SiteHoldKind.challenge]  要过人机验证
///   `503 + unavailable` → [SiteHoldKind.temporary]  服务端临时繁忙
///
/// ## 为什么 `challenge` 一律不动
///
/// 站点认人靠 reader 身份那对 P-256 密钥（私钥在 IndexedDB
/// `fus-reader-v1`），每次请求都用它签 `X-FUS-Proof`。**没有通行证的
/// 密钥第一次调 `POST /sms-api/v1/session` 必然拿到
/// `403 reader_verification_required`** —— 人机验证是「这个身份还没拿到
/// 通行证」的正常流程，不是「被拒绝」。
///
/// 而换身份 = 清 IndexedDB = 换一对新密钥 = 新身份一样没有通行证 →
/// 站点再要一次验证。于是「遇到 challenge 就换身份」就是
/// 验证 → 换身份 → 再验证 → 再换身份，永远转不完。
///
/// 真机表现：过完验证退出收件页，重进又等一大会、又自动换身份。
library;

import 'package:fus_inbox/features/inbox/domain/inbox_message.dart';

/// 这次该怎么补救。
enum RotationAction() {
  /// 站点信号干净，什么都不做（顺带把连续计数归零）。
  nothing,

  /// 换下一条出口 + 重置浏览器身份。只给配额那一档。
  rotateEgress,

  /// 只提示用户，不动任何东西 —— 站点要人机验证、或者临时繁忙。
  waitOnly,
}

/// 判定结果。
class const RotationDecision({
  required this.action,
  this.note = '',
}) {
  final RotationAction action;

  /// 要写进状态栏的话。空串表示不用说话。
  final String note;
}

/// 站点信号 → 该做什么。纯函数，不碰状态。
///
/// [hold] 是站点贴的那一档（没有就是 null），[status] 是抓取层写进状态栏的
/// 文本 —— 它偶尔会早于 `holdup` 帧带上 `reader_verification`，那条时序
/// 空隙也要按「要验证」处理，同样不许换身份。
///
/// [autoRotate] 是用户的开关：关着时配额那一档也不许动。
/// [egressAvailable] 是代理池里还有没有别的出口可换 —— 没有时不许
/// `discard`，那会把说明得清状况的卡片换成一张空白骨架。
/// [consecutiveRotations] 已经连换几次；到 [maxConsecutiveRotations] 就停手。
RotationDecision decideRotation({
  required SiteHold? hold,
  required String status,
  required bool autoRotate,
  required bool egressAvailable,
  required int consecutiveRotations,
  required int maxConsecutiveRotations,
}) {
  final wantsVerification = status.contains('reader_verification');

  // 没有任何拒绝信号就不动。
  if (hold == null && !wantsVerification) {
    return const RotationDecision(action: RotationAction.nothing);
  }

  // 连换到上限还是被拒 —— 站点要么在维护、要么按别的东西在拒
  // （不是 IP 也不是身份）。继续换只会把池子烧穿、让界面一直转圈。
  if (consecutiveRotations >= maxConsecutiveRotations) {
    return RotationDecision(
      action: RotationAction.waitOnly,
      note:
          '已经连换 $maxConsecutiveRotations 次还是被拒，先停下。'
          '换个网络、或过一会儿再试。',
    );
  }

  // 验证属于正常流程，换身份只会把「没有通行证」这件事重新做一遍。
  if (hold?.kind == SiteHoldKind.challenge) {
    return const RotationDecision(
      action: RotationAction.waitOnly,
      note: '这个出口要过人机验证。验证属于正常流程，过完会自动继续。',
    );
  }

  // 只有 status 文本、还没有 holdup 帧那条时序空隙，同理。
  if (hold == null && wantsVerification) {
    return const RotationDecision(
      action: RotationAction.waitOnly,
      note: '站点要过人机验证。验证属于正常流程，过完会自动继续。',
    );
  }

  // 配额：记在出口 IP 上，换身份解决不了，必须换出口。
  if (hold?.kind == SiteHoldKind.quota) {
    if (!autoRotate) {
      return const RotationDecision(action: RotationAction.waitOnly);
    }
    if (!egressAvailable) {
      return const RotationDecision(
        action: RotationAction.waitOnly,
        note: '代理池里没有别的出口可换，需要你换个网络再点重置。',
      );
    }
    return const RotationDecision(action: RotationAction.rotateEgress);
  }

  // 503 临时繁忙：跟 IP、跟身份都无关，等它自己好。
  return const RotationDecision(
    action: RotationAction.waitOnly,
    note: '站点暂时不给消息，等它自己恢复。',
  );
}
