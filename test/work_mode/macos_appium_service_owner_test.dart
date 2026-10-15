import 'dart:io';

import 'package:chat_group/features/work_mode/macos_native_app_automation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('原生验收只从结果描述提取期望状态，不把操作对象当结果', () {
    expect(
      nativeExpectedOutcomeTexts('点击“保存”后显示“保存成功”并持久化', ''),
      {'保存成功'},
    );
    expect(
      nativeExpectedOutcomeTexts('点击“保存”并持久化', ''),
      isEmpty,
    );
  });

  test(
      'native assertion compares a stable result with the successful action baseline',
      () {
    expect(
      nativeExpectedOutcomeChanged(
        actionBeforeText: '',
        currentBeforeText: '保存成功',
        observedText: '保存成功',
        expectedText: '保存成功',
      ),
      isTrue,
    );
  });

  test(
      'native assertion does not accept outcome text already present without an action',
      () {
    expect(
      nativeExpectedOutcomeChanged(
        actionBeforeText: null,
        currentBeforeText: '保存成功',
        observedText: '保存成功',
        expectedText: '保存成功',
      ),
      isFalse,
    );
  });

  test('保存成功 → 调整窗口 → 滚动 → 重开 → 断言的基线仍停在产生结果之前', () {
    // 按会话里的记账顺序回放：基线写的是动作**前**的状态，"保存成功"由 click 写出，
    // 调整窗口与滚动只改变几何与可见范围，不写元素文本。
    const steps = ['input', 'click', 'resize', 'scroll', 'reopen'];
    var elementText = '';
    var baselineText = '';
    var legacyBaselineText = '';
    for (final step in steps) {
      final before = elementText;
      if (step == 'click') elementText = '保存成功';
      if (nativeActionMovesOutcomeBaseline(step)) {
        baselineText = before;
      }
      legacyBaselineText = before; // 修复前：每个成功动作都无条件前移基线
    }

    expect(baselineText, isEmpty, reason: '基线必须停在写出"保存成功"那个动作之前');
    expect(
      nativeExpectedOutcomeChanged(
        actionBeforeText: baselineText,
        currentBeforeText: elementText,
        observedText: elementText,
        expectedText: '保存成功',
      ),
      isTrue,
      reason: '调整窗口与滚动不写元素文本，不该顶掉"这个值是新出现的"这条证据',
    );
    expect(
      nativeExpectedOutcomeChanged(
        actionBeforeText: legacyBaselineText,
        currentBeforeText: elementText,
        observedText: elementText,
        expectedText: '保存成功',
      ),
      isFalse,
      reason: '这就是修复前的行为：基线被顶成关闭前状态，正常结果反被判失败',
    );
  });

  test('重开后仍显示原值：基线留在产生该值的动作之前，不能换成关闭前状态', () {
    expect(
      nativeExpectedOutcomeChanged(
        actionBeforeText: '',
        currentBeforeText: '保存成功',
        observedText: '保存成功',
        expectedText: '保存成功',
      ),
      isTrue,
      reason: '重开只是重新载入同一份状态，不该移动基线',
    );
    expect(
      nativeExpectedOutcomeChanged(
        actionBeforeText: '保存成功',
        currentBeforeText: '保存成功',
        observedText: '保存成功',
        expectedText: '保存成功',
      ),
      isFalse,
      reason: '关闭前状态本来就含预期文本，拿它当基线会让正常的持久化验收永远失败',
    );
  });

  final enabled = Platform.isMacOS &&
      Platform.environment['CHAT_GROUP_RUN_MACOS_APPIUM_TEST'] == '1';

  test('automation-mode status parser rejects unknown status', () {
    expect(
        MacAppiumServiceOwner.automationModeEnabledFromStatus(
            'Automation Mode is disabled. This device requires user authentication.'),
        isFalse);
    expect(
        MacAppiumServiceOwner.automationModeEnabledFromStatus(
            'Automation Mode is enabled.'),
        isTrue);
    expect(
        MacAppiumServiceOwner.automationModeEnabledFromStatus(
            'Automation Mode status is not available.'),
        isNull);
  });

  test('pauses only for a failed session with a known disabled mode', () {
    expect(
        MacAppiumServiceOwner.shouldPauseForAutomationAuthorization(
            sessionCreationAttempted: true,
            httpStatus: 500,
            automationModeEnabled: false),
        isTrue);
    expect(
        MacAppiumServiceOwner.shouldPauseForAutomationAuthorization(
            sessionCreationAttempted: false,
            httpStatus: 500,
            automationModeEnabled: false),
        isFalse);
    expect(
        MacAppiumServiceOwner.shouldPauseForAutomationAuthorization(
            sessionCreationAttempted: true,
            httpStatus: 400,
            automationModeEnabled: false),
        isFalse);
    expect(
        MacAppiumServiceOwner.shouldPauseForAutomationAuthorization(
            sessionCreationAttempted: true,
            httpStatus: 500,
            automationModeEnabled: null),
        isFalse);
  });

  test(
    'leaves an externally owned fixed-port listener untouched',
    () async {
      final listener = await ServerSocket.bind('127.0.0.1', 4725);
      try {
        final owner = MacAppiumServiceOwner();
        await expectLater(
            owner.start(), throwsA(isA<MacAppiumServiceConflict>()));
        expect(owner.isStarted, isFalse);
        final socket = await Socket.connect('127.0.0.1', 4725);
        socket.destroy();
      } finally {
        await listener.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: enabled ? null : 'set CHAT_GROUP_RUN_MACOS_APPIUM_TEST=1 on macOS',
  );

  test(
    'starts and stops only the pinned Appium child process',
    () async {
      final owner = MacAppiumServiceOwner();
      await owner.start();
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:4725'));
      try {
        await owner.assertOwned();
        final status = await dio.get<Map<String, dynamic>>('/status');
        expect(status.data?['value']?['build']?['version'], '3.8.0');
        final sessions =
            await dio.get<Map<String, dynamic>>('/appium/sessions');
        expect(sessions.data?['value'], isEmpty);
      } finally {
        dio.close(force: true);
        await owner.stop();
      }
      expect(owner.isStarted, isFalse);
      final listeners = await Process.run(
        '/usr/sbin/lsof',
        ['-nP', '-t', '-iTCP:4725', '-sTCP:LISTEN'],
        runInShell: false,
      );
      expect(listeners.stdout.toString().trim(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: enabled ? null : 'set CHAT_GROUP_RUN_MACOS_APPIUM_TEST=1 on macOS',
  );
}
