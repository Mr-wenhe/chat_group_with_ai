typedef NativePathLoader = Future<String> Function();

Future<String> resolveAiProcessingDirectoryLabel({
  required bool isWeb,
  required NativePathLoader nativePathLoader,
}) {
  if (isWeb) {
    return Future.value('Web 端使用浏览器存储，不提供本地工作目录');
  }
  return nativePathLoader();
}
