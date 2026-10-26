/// 收件箱合并顺序回归测试。
///
/// 站点返回的 `items` 是「新→旧」。曾经的 bug 是逐条 `order.insert(0, id)`，
/// 把整批翻成「旧→新」，最新的短信沉到列表最底 —— 接码场景下正好看错方向。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fus_inbox/features/inbox/application/inbox_provider.dart';

InboxStore storeWith(void Function(InboxStore) onIngest) {
  final store = InboxStore();
  onIngest(store);
  return store;
}

Map<String, dynamic> payload(List<Map<String, dynamic>> items) => {
  'type': 'messages',
  'items': items,
  'hits': 1,
  'src': 'api',
};

Map<String, dynamic> msg(String id, String time, {String text = '正文'}) => {
  'id': id,
  'text': text,
  'time': time,
};

void main() {
  group('ingest 顺序', () {
    test('首屏按站点原序保留：最新在最前', () {
      final store = storeWith((s) {
        s.ingest(
          payload([
            msg('n1', '2026-10-25T21:37:53Z'),
            msg('m2', '2026-10-25T20:10:00Z'),
            msg('o3', '2026-10-25T19:00:00Z'),
          ]),
        );
      });
      expect(store.state.messages.map((m) => m.id).toList(), [
        'n1',
        'm2',
        'o3',
      ]);
    });

    test('增量批次的新消息排在最前，且批次内保持原序', () {
      final store = storeWith((s) {
        s.ingest(
          payload([
            msg('e1', '2026-10-25T10:00:00Z'),
            msg('e2', '2026-10-25T09:00:00Z'),
          ]),
        );
        s.ingest(
          payload([
            msg('n1', '2026-10-25T12:00:00Z'),
            msg('n2', '2026-10-25T11:00:00Z'),
          ]),
        );
      });
      expect(store.state.messages.map((m) => m.id).toList(), [
        'n1',
        'n2',
        'e1',
        'e2',
      ]);
    });

    test('同 id 后到（正文分批抵达）不改变位置，且补齐正文', () {
      final store = storeWith((s) {
        s.ingest(
          payload([
            msg('a', '2026-10-25T12:00:00Z', text: ''),
            msg('b', '2026-10-25T11:00:00Z'),
          ]),
        );
        s.ingest(payload([msg('a', '2026-10-25T12:00:00Z', text: '完整正文')]));
      });
      expect(store.state.messages.map((m) => m.id).toList(), ['a', 'b']);
      expect(store.state.messages.first.text, '完整正文');
    });

    test('无时区的目录式时间戳也能正确排序', () {
      final store = storeWith((s) {
        s.ingest(
          payload([
            msg('new', '2026-10-25T21:31:46'),
            msg('old', '2026-10-25T20:31:46'),
          ]),
        );
      });
      expect(store.state.messages.map((m) => m.id).toList(), ['new', 'old']);
    });
  });

  group('ingestRaw', () {
    test('非法帧被忽略且不抛异常', () {
      final store = InboxStore();
      expect(() => store.ingestRaw('not json'), returnsNormally);
      expect(() => store.ingestRaw('{"type":"catalog"}'), returnsNormally);
      expect(store.state.messages, isEmpty);
    });

    test('合法帧经 raw 通道同样进入状态', () {
      final store = InboxStore();
      store.ingestRaw(
        jsonEncode({
          'type': 'messages',
          'items': [msg('x', '2026-10-25T12:00:00Z')],
          'hits': 3,
        }),
      );
      expect(store.state.messages.single.id, 'x');
      expect(store.state.hits, 3);
    });
  });
}
