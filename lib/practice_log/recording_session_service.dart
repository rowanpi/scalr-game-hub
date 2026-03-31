/// Lightweight stub for game hub.
///
/// In the main Scalr app this posts practice items to the backend and drives the
/// recording timer UI. For `scalr-game-hub` we keep a minimal API so games can
/// log events without forcing full auth/backend wiring yet.
class RecordingSessionService {
  RecordingSessionService._();
  static final RecordingSessionService _instance = RecordingSessionService._();
  static RecordingSessionService get instance => _instance;

  bool get isRecording => false;

  Future<void> addItem(String label, {int? durationSeconds}) async {
    // Intentionally a no-op for now.
  }
}

