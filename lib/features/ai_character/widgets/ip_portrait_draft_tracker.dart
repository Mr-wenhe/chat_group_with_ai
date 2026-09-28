/// IP 形象草稿的文件回收簿记。
///
/// 只做**决策**（该删哪些路径），不做 IO —— 删除动作由调用方执行。这样既能
/// 穷测「保存 / 放弃 × 新建 / 编辑 × 生成 / 重新生成 / 清除」的全部组合，也
/// 避开 `testWidgets` 的 FakeAsync 区里真实文件 IO 的不确定性。
///
/// 回收语义的两条底线：
/// 1. **放弃编辑绝不误删既有形象** —— 被换下的旧文件只在保存成功后回收。
///    否则「编辑已有角色 → 重新生成 → 直接返回」会把用户原本的头像图删掉，
///    而 Hive 里的 `ipImageRelPath` 还指着它，只剩文本回落。
/// 2. **未保存的新文件不留孤儿** —— 本次会话生成但最终没被保存引用的文件，
///    一律在放弃时回收。该目录在 `media/` 之外，`ManagedMediaStore` 的
///    orphan GC 不会替我们收，只能自己收。
class IpPortraitDraftTracker {
  IpPortraitDraftTracker({required String initialRelPath})
      : _initialRelPath = initialRelPath,
        currentRelPath = initialRelPath;

  /// 进入表单时角色已持久化的相对路径（可为空）。只有它被换下时才走
  /// 「提交后回收」，见 [_retireCurrent]。
  final String _initialRelPath;

  /// 当前草稿指向的相对路径；空串表示未生成 / 已清除。
  String currentRelPath;

  /// 本次表单会话内新写出的文件。
  final List<String> _sessionRelPaths = [];

  /// 被换下或清除的**既有**文件，保存成功后才回收。
  final List<String> _retireOnCommit = [];

  bool get hasImage => currentRelPath.isNotEmpty;

  /// 会话内新生成 / 重新生成：记入会话清单，并把被换下的当前文件转入回收簿。
  void adopt(String newRelPath) {
    _retireCurrent();
    if (newRelPath.isNotEmpty) _sessionRelPaths.add(newRelPath);
    currentRelPath = newRelPath;
  }

  /// 清除形象。**不删文件**，只改引用 —— 删除时机见 [markCommitted] / [discard]。
  void clear() {
    _retireCurrent();
    currentRelPath = '';
  }

  void _retireCurrent() {
    final path = currentRelPath;
    if (path.isEmpty) return;
    // 会话内新文件已在 _sessionRelPaths 里，由 markCommitted / discard 统一回收；
    // 只有既有文件需要单独记入「提交后回收」。
    if (path == _initialRelPath) _retireOnCommit.add(path);
  }

  /// 保存成功后调用：返回应立即回收的路径，并清空簿记。
  ///
  /// 保留 [currentRelPath]（它现在被持久化角色引用），回收其余会话内新文件
  /// 与被换下的既有文件。
  List<String> markCommitted() {
    final keep = currentRelPath;
    final doomed = <String>{
      for (final path in _sessionRelPaths)
        if (path != keep) path,
      ..._retireOnCommit,
    }.toList(growable: false);
    _sessionRelPaths.clear();
    _retireOnCommit.clear();
    return doomed;
  }

  /// 放弃编辑后调用：返回应立即回收的路径，并清空簿记。
  ///
  /// 只回收会话内新文件；既有文件原样保留（底线 1）。
  List<String> discard() {
    final doomed = List<String>.of(_sessionRelPaths);
    _sessionRelPaths.clear();
    _retireOnCommit.clear();
    return doomed;
  }
}
