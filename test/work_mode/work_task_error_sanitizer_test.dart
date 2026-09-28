import 'dart:async';

import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies a timeout from its type, not only from its message', () {
    // `TimeoutException` 的默认文案（Future.timeout 未带 duration 时）里并没有
    // 「超时」二字，信号只在类型名上；剥掉 Dart 前缀再分类会把它判成普通失败。
    expect(
      sanitizeWorkTaskError(TimeoutException('Future not completed')),
      '任务执行超时',
    );
    expect(
      sanitizeWorkTaskError(TimeoutException('工作模式模型请求超时。')),
      '任务执行超时',
    );
    expect(sanitizeWorkTaskError('连接超时'), '任务执行超时');
  });

  test('keeps the permission and connection classifications', () {
    expect(sanitizeWorkTaskError(StateError('没有权限写入该目录')), '任务权限不足');
    expect(
      sanitizeWorkTaskError(StateError('connection refused by peer')),
      '任务网络连接失败',
    );
  });

  test('strips the Dart exception prefix from the displayed reason', () {
    expect(
      sanitizeWorkTaskError(StateError('该目录授权提醒已失效，请打开任务面板查看最新状态。')),
      '该目录授权提醒已失效，请打开任务面板查看最新状态。',
    );
    expect(
      sanitizeWorkTaskError(const FormatException('不是伴伴备份文件')),
      '不是伴伴备份文件',
    );
    expect(
      sanitizeWorkTaskError(Exception('所选目录只读')),
      '所选目录只读',
    );
  });

  test('reports the HTTP status code instead of the raw body', () {
    expect(
      sanitizeWorkTaskError(StateError('HTTP 503 Service Unavailable')),
      '任务请求失败（HTTP 503）',
    );
  });

  test('redacts local paths and external addresses', () {
    final message = sanitizeWorkTaskError(
      StateError(
        '无法写入 /Users/someone/project/secret.txt 详见 https://example.com/log',
      ),
    );
    expect(message, isNot(contains('/Users/someone')));
    expect(message, isNot(contains('example.com')));
    expect(message, contains('[本地路径]'));
    expect(message, contains('[外部地址]'));
  });

  test('falls back to a stable message for empty input', () {
    expect(sanitizeWorkTaskError(null), '任务执行失败');
    expect(sanitizeWorkTaskError('   '), '任务执行失败');
    expect(sanitizeWorkTaskError(StateError('   ')), '任务执行失败');
  });
}
