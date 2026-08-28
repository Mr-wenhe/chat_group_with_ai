/// Chat-room-only state for the work-mode switch.
///
/// Task cancellation and approval state belong to [WorkTaskCoordinator], not
/// to a page-bound session. This object deliberately stays small so disposing
/// a chat room cannot affect an app-level task.
class WorkModeSession {
  bool enabled = false;

  void setEnabled(bool value) {
    enabled = value;
  }
}
