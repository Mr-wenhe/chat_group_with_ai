import 'package:chat_group/features/ai_character/widgets/ip_portrait_draft_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IpPortraitDraftTracker 回收决策', () {
    test('新建角色生成后放弃：回收本次新文件', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: '');
      tracker.adopt('a/ip.png');

      expect(tracker.currentRelPath, 'a/ip.png');
      expect(tracker.discard(), ['a/ip.png']);
    });

    test('新建角色生成后保存：保留当前文件，不回收任何路径', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: '');
      tracker.adopt('a/ip.png');

      expect(tracker.markCommitted(), isEmpty);
    });

    test('编辑角色且未改动：放弃与保存都不回收', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');

      expect(tracker.discard(), isEmpty);
      expect(tracker.markCommitted(), isEmpty);
    });

    test('编辑角色重新生成后放弃：只迷新文件，既有文件原样保留', () {
      // 底线 1：否则「编辑 → 重新生成 → 直接返回」会把用户原本的头像图删掉，
      // 而 Hive 里的 ipImageRelPath 还指着它。
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker.adopt('new/ip.png');

      expect(tracker.discard(), ['new/ip.png']);
    });

    test('编辑角色重新生成后保存：换下的既有文件与当前文件交接', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker.adopt('new/ip.png');

      expect(tracker.markCommitted(), ['old/ip.png']);
    });

    test('连续重新生成后保存：只保留最后一张，其余会话内新文件全回收', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: '');
      tracker
        ..adopt('first/ip.png')
        ..adopt('second/ip.png')
        ..adopt('third/ip.png');

      expect(tracker.markCommitted(), ['first/ip.png', 'second/ip.png']);
    });

    test('连续重新生成后放弃：全部会话内新文件回收', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker
        ..adopt('first/ip.png')
        ..adopt('second/ip.png');

      expect(tracker.discard(), ['first/ip.png', 'second/ip.png']);
    });

    test('清除既有形象后保存：既有文件回收，当前引用为空', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker.clear();

      expect(tracker.hasImage, isFalse);
      expect(tracker.markCommitted(), ['old/ip.png']);
    });

    test('清除既有形象后放弃：既有文件保留（用户没保存就不该丢图）', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker.clear();

      expect(tracker.discard(), isEmpty);
    });

    test('生成后清除再保存：新旧文件一并回收', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker
        ..adopt('new/ip.png')
        ..clear();

      expect(tracker.markCommitted(), unorderedEquals(['old/ip.png', 'new/ip.png']));
    });

    test('生成后清除再放弃：只回收会话内新文件', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: 'old/ip.png');
      tracker
        ..adopt('new/ip.png')
        ..clear();

      expect(tracker.discard(), ['new/ip.png']);
    });

    test('回收决策可重复调用：第二次不再给出路径', () {
      final tracker = IpPortraitDraftTracker(initialRelPath: '');
      tracker.adopt('a/ip.png');

      expect(tracker.discard(), ['a/ip.png']);
      expect(tracker.discard(), isEmpty);
      expect(tracker.markCommitted(), isEmpty);
    });
  });
}
