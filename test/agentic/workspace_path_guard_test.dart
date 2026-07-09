import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证 [WorkspacePathGuard.normalizeToRelative]：将模型可能输出的绝对路径
/// 归一化为相对工作区的 basename，而相对路径（含子目录）原样返回。
///
/// 这是「Agentic 写文件因绝对路径报错」Bug 的客户端修复点：模型复制了
/// 对话上下文里的绝对路径（如 `/Users/.../star_scene.html`）时，不应抛错
/// 中断写文件，而只落到工作区根目录下的 `star_scene.html`。
void main() {
  group('WorkspacePathGuard.normalizeToRelative', () {
    test('相对子目录路径原样返回', () {
      expect(
        WorkspacePathGuard.normalizeToRelative('docs/report.md'),
        'docs/report.md',
      );
    });

    test('相对文件名原样返回', () {
      expect(
        WorkspacePathGuard.normalizeToRelative('star_scene.html'),
        'star_scene.html',
      );
    });

    test('Unix 绝对路径取 basename', () {
      expect(
        WorkspacePathGuard.normalizeToRelative(
          '/Users/fengye/Library/Application Support/chat_group/star_scene.html',
        ),
        'star_scene.html',
      );
    });

    test('Windows 绝对路径取 basename', () {
      // 注：原始需求示例写的是 star_scene.html，但 C:\Users\x\star.html 的
      // basename 实际为 star.html，此处以真实行为为准（归一化取最后一段）。
      expect(
        WorkspacePathGuard.normalizeToRelative(r'C:\Users\x\star.html'),
        'star.html',
      );
    });

    test('空串返回空串', () {
      expect(WorkspacePathGuard.normalizeToRelative(''), '');
    });

    test('带前后空白的绝对路径归一化后去空白', () {
      expect(
        WorkspacePathGuard.normalizeToRelative('  /a/b.html  '),
        'b.html',
      );
    });

    test('相对路径里的 .. 段由归一化原样返回（安全校验另行拒绝）', () {
      const risky = '../etc/passwd';
      expect(WorkspacePathGuard.normalizeToRelative(risky), risky);
      // 安全校验仍应拒绝该路径，确保归一化不削弱防穿越保护。
      expect(WorkspacePathGuard.isSafeRelativePath(risky), isFalse);
    });
  });
}
