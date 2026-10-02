part of 'work_discussion_runner.dart';

extension _WorkDiscussionProjectDossier on WorkDiscussionRunner {
  /// A user-mentioned path is navigation, not authorization or code evidence.
  /// V2 obtains inventory and source through the existing controlled tools.
  Future<Map<String, dynamic>> _projectDossier(String request) async => {
        'available': false,
        'hasRequestedPath':
            const WorkModeDirectoryService().requestedLocalPath(request) !=
                null,
        'instruction':
            '项目路径仅用于导航。代码判断必须通过受控 workspace.list/read/search 取得真实来源，不从文件名推断实现或自动关闭问题。',
      };

  Future<Map<String, List<String>>> _reconcileProjectFactQuestions(
          AgentTask task, Iterable<String> questions) async =>
      const {};

  bool _isDecisionQuestion(String normalized) =>
      RegExp(r'[?？]|是否|有没有|要不要|需不需要|能否|可否|请确认|待确认').hasMatch(normalized);
}
