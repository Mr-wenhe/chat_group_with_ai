/// A user-facing result for attachment path operations.
///
/// The UI must use this result instead of guessing a replacement path. This
/// keeps missing files, data URIs and unsupported platforms explicit.
class AttachmentPathActionResult {
  final bool success;
  final String message;
  final String? absolutePath;

  const AttachmentPathActionResult({
    required this.success,
    required this.message,
    this.absolutePath,
  });

  const AttachmentPathActionResult.ok(String path)
      : success = true,
        message = '',
        absolutePath = path;

  const AttachmentPathActionResult.failure(this.message)
      : success = false,
        absolutePath = null;
}
