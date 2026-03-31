import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:record/record.dart';

/// Configuration for a note detection session.
class NoteDetectorOptions {
  const NoteDetectorOptions({
    this.sampleRate = 44100,
    this.bufferSize = 2048,
    this.minRms = 550.0,
    this.minProbability = 0.62,
    this.minHz = 150.0,
    this.maxHz = 1800.0,
    this.stabilityWindow = 4,
    this.minStableProbability = 0.82,
    this.maxJitterCents = 22.0,
    this.holdLastGoodMs = 1450,
    this.minEventIntervalMs = 50,
    this.emitUnpitchedEvents = true,
    this.continuousMode = false,
    this.fastMode = false,
  });

  final int sampleRate;
  final int bufferSize;
  final double minRms;
  final double minProbability;
  final double minHz;
  final double maxHz;
  final int stabilityWindow;
  final double minStableProbability;
  final double maxJitterCents;
  final int holdLastGoodMs;
  final int minEventIntervalMs;
  final bool emitUnpitchedEvents;
  /// When true, emit events continuously even for the same note (useful for tuning).
  /// When false, deduplicate similar events (useful for note detection/transcription).
  final bool continuousMode;
  /// When true, relax stability thresholds to detect fast attacks quicker.
  /// Intended for gameplay mode, not tuner mode.
  final bool fastMode;

  int get frameBytes => bufferSize * 2;
}

/// Event published by NoteDetectorSession containing pitch detection results.
class NoteDetectionEvent {
  const NoteDetectionEvent({
    required this.timestamp,
    required this.pitched,
    required this.rms,
    required this.probability,
    required this.frequencyHzRaw,
    required this.frequencyHz,
    required this.confidence,
    this.noteLabel,
    this.midi,
    this.centsFromNearest,
    required this.stable,
    required this.isNewNote,
  });

  final DateTime timestamp;
  final bool pitched;
  final double rms;
  final double probability;
  final double frequencyHzRaw;
  final double frequencyHz;
  /// Composite confidence: probability weighted by how close to centre (in tune).
  final double confidence;
  final String? noteLabel;
  final int? midi;
  final double? centsFromNearest;
  final bool stable;
  final bool isNewNote;
}

/// A lease on the note detector. Dispose to release.
class NoteDetectorSession {
  NoteDetectorSession._({
    required this.options,
    required Stream<NoteDetectionEvent> eventStream,
    required this.onDispose,
  }) : _eventStream = eventStream;

  final NoteDetectorOptions options;
  final Stream<NoteDetectionEvent> _eventStream;
  final Future<void> Function() onDispose;

  Stream<NoteDetectionEvent> get events => _eventStream;

  bool _disposed = false;
  _SessionState? _state;

  Future<void> pause() async {
    if (_state != null) _state!.paused = true;
  }

  Future<void> resume() async {
    if (_state != null) _state!.paused = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await onDispose();
  }
}

/// Shared note detection service. Manages mic + isolate and provides sessions.
class NoteDetectorService {
  NoteDetectorService._();
  static final NoteDetectorService _instance = NoteDetectorService._();
  static NoteDetectorService get instance => _instance;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  Isolate? _isolate;
  ReceivePort? _resultPort;
  SendPort? _frameSendPort;

  // Small frame queue — avoids unbounded memory if processing lags.
  final Queue<Uint8List> _frameQueue = Queue<Uint8List>();
  int _outstandingFrames = 0;

  // Epoch lets us ignore messages from a previous (dead) isolate.
  int _receiveEpoch = 0;
  Completer<void>? _killAckCompleter;

  final List<_SessionState> _sessions = [];
  bool _micRunning = false;
  bool _startStopLock = false;
  bool _restartingIsolate = false;

  int _sampleRate = 44100;
  int _bufferSize = 2048;

  int _lastResultAtMs = 0;
  int _lastSentAtMs = 0;

  static const String _killSignal = 'kill';
  static const int _maxBufferedFrames = 8;
  static const int _maxFrameQueueLength = 3;
  static const int _maxOutstandingFrames = 3;
  static const int _sendThrottleMs = 80;
  static const int _kickAfterResultDelayMs = 15;
  static const int _killAckTimeoutMs = 500;
  static const int _isolateResponseTimeoutMs = 1200;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Acquire a new session. Starts mic if not already running.
  Future<NoteDetectorSession> acquire(NoteDetectorOptions options) async {
    if (_sessions.isEmpty) {
      _sampleRate = options.sampleRate;
      _bufferSize = options.bufferSize;
      await _startMic();
    } else {
      if (options.sampleRate != _sampleRate || options.bufferSize != _bufferSize) {
        // ignore: avoid_print
        print(
          'NoteDetectorService: mismatched sampleRate/bufferSize across sessions. '
          'Existing=$_sampleRate/$_bufferSize, requested=${options.sampleRate}/${options.bufferSize}. '
          'Reusing existing isolate configuration.',
        );
      }
    }

    final controller = StreamController<NoteDetectionEvent>.broadcast();
    final state = _SessionState(options: options, controller: controller);
    _sessions.add(state);

    final session = NoteDetectorSession._(
      options: options,
      eventStream: controller.stream,
      onDispose: () => _releaseSession(state),
    );
    session._state = state;
    return session;
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _releaseSession(_SessionState state) async {
    _sessions.remove(state);
    await state.controller.close();
    if (_sessions.isEmpty) await _stopMic();
  }

  // ---------------------------------------------------------------------------
  // Mic lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _startMic() async {
    if (_micRunning || _startStopLock) return;
    _startStopLock = true;

    try {
      final ok = await _recorder.hasPermission(request: true).timeout(
        const Duration(seconds: 6),
        onTimeout: () => throw TimeoutException('Mic permission timed out'),
      );
      if (!ok) throw Exception('Microphone permission denied');

      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: _sampleRate,
      );

      final stream = await _recorder.startStream(config).timeout(
        const Duration(seconds: 6),
        onTimeout: () => throw TimeoutException('Mic not available'),
      );

      _micSub = stream.listen(
        _onChunk,
        onError: (e) {
          for (final s in List<_SessionState>.from(_sessions)) {
            if (s.controller.isClosed) continue;
            s.controller.addError(e);
          }
        },
      );

      _micRunning = true;
      await _startIsolate();
    } catch (e) {
      await _teardownIsolate();
      try { await _micSub?.cancel(); } catch (_) {}
      _micSub = null;
      try { await _recorder.stop(); } catch (_) {}
      _micRunning = false;
      _buffer.clear();
      _frameQueue.clear();
      _outstandingFrames = 0;
      rethrow;
    } finally {
      _startStopLock = false;
    }
  }

  Future<void> _stopMic() async {
    if (!_micRunning || _startStopLock) return;
    _startStopLock = true;

    try {
      _micRunning = false;
      try { await _micSub?.cancel(); } catch (_) {}
      _micSub = null;

      await _teardownIsolate();

      try { await _recorder.stop(); } catch (_) {}
    } finally {
      _buffer.clear();
      _frameQueue.clear();
      _outstandingFrames = 0;
      _frameSendPort = null;
      _startStopLock = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Isolate lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _startIsolate() async {
    final currentEpoch = ++_receiveEpoch;
    _killAckCompleter = null;
    _frameSendPort = null;
    _outstandingFrames = 0;
    _lastResultAtMs = 0;
    _lastSentAtMs = 0;

    _resultPort = ReceivePort();
    _resultPort!.listen((dynamic msg) {
      if (currentEpoch != _receiveEpoch) return; // stale message

      if (msg is SendPort) {
        _frameSendPort = msg;
        _kickProcess();
        return;
      }

      if (msg is Map) {
        if (msg['type'] == 'killAck') {
          _killAckCompleter?.complete();
          return;
        }
        _onPitchResult(msg);
      }
    });

    _isolate = await Isolate.spawn(
      _isolateEntry,
      [_resultPort!.sendPort, _sampleRate, _bufferSize],
    );
  }

  Future<void> _restartIsolate() async {
    if (!_micRunning || _restartingIsolate) return;
    _restartingIsolate = true;
    try {
      await _teardownIsolate();
      _frameQueue.clear();
      _outstandingFrames = 0;
      await _startIsolate();
      _kickProcess();
    } finally {
      _restartingIsolate = false;
    }
  }

  Future<void> _teardownIsolate() async {
    final isolate = _isolate;
    final sendPort = _frameSendPort;
    final resultPort = _resultPort;

    _frameSendPort = null;
    _outstandingFrames = 0;

    bool acked = false;
    if (sendPort != null) {
      _killAckCompleter = Completer<void>();
      try {
        sendPort.send(_killSignal);
        await _killAckCompleter!.future
            .timeout(Duration(milliseconds: _killAckTimeoutMs));
        acked = true;
      } catch (_) {
        acked = false;
      } finally {
        _killAckCompleter = null;
      }
    }

    // Bump epoch so any in-flight messages are ignored.
    _receiveEpoch++;

    try { resultPort?.close(); } catch (_) {}
    _resultPort = null;
    _isolate = null;

    if (isolate != null && !acked) {
      try { isolate.kill(priority: Isolate.immediate); } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Audio chunk → frame queue
  // ---------------------------------------------------------------------------

  void _onChunk(Uint8List chunk) {
    if (!_micRunning) return;

    final frameBytes = _bufferSize * 2;
    // Drop accumulated audio if processing falls far behind.
    if (_buffer.length + chunk.length > frameBytes * _maxBufferedFrames) {
      _buffer.clear();
    }
    _buffer.add(chunk);

    while (_buffer.length >= frameBytes) {
      final bytes = _buffer.takeBytes();
      _enqueueFrame(Uint8List.sublistView(bytes, 0, frameBytes));
      if (bytes.length > frameBytes) {
        _buffer.add(Uint8List.sublistView(bytes, frameBytes));
      }
    }

    _kickProcess();
  }

  void _enqueueFrame(Uint8List frame) {
    if (_frameQueue.length >= _maxFrameQueueLength) _frameQueue.removeFirst();
    _frameQueue.add(frame);
  }

  void _kickProcess() {
    if (!_micRunning) return;
    final sendPort = _frameSendPort;
    if (sendPort == null) return;
    if (_outstandingFrames >= _maxOutstandingFrames) return;
    if (_frameQueue.isEmpty) return;

    final frame = _frameQueue.removeFirst();
    _outstandingFrames++;
    final sentAt = DateTime.now().millisecondsSinceEpoch;
    _lastSentAtMs = sentAt;

    sendPort.send(frame);

    // Throttle next send.
    Future.delayed(Duration(milliseconds: _sendThrottleMs), () {
      if (_micRunning) _kickProcess();
    });

    // Watchdog: restart isolate if no result within timeout.
    final epoch = _receiveEpoch;
    unawaited(Future.delayed(Duration(milliseconds: _isolateResponseTimeoutMs), () {
      if (!_micRunning) return;
      if (epoch != _receiveEpoch) return;
      if (_outstandingFrames <= 0) return;
      if (_lastSentAtMs != sentAt) return;
      if (_lastResultAtMs >= sentAt) return;
      unawaited(_restartIsolate());
    }));
  }

  // ---------------------------------------------------------------------------
  // Pitch result → session processing
  // ---------------------------------------------------------------------------

  void _onPitchResult(Map<dynamic, dynamic> resultMap) {
    final now = DateTime.now();
    _outstandingFrames = (_outstandingFrames - 1).clamp(0, _maxOutstandingFrames);
    _lastResultAtMs = now.millisecondsSinceEpoch;

    final pitched = resultMap['pitched'] as bool? ?? false;
    final probability = (resultMap['probability'] as num?)?.toDouble() ?? 0.0;
    final pitchRaw = (resultMap['pitch'] as num?)?.toDouble() ?? 0.0;
    final rms = (resultMap['rms'] as num?)?.toDouble() ?? 0.0;

    for (final state in List<_SessionState>.from(_sessions)) {
      if (state.controller.isClosed) continue;
      _processForSession(state, now, pitched, probability, pitchRaw, rms);
    }

    Future.delayed(Duration(milliseconds: _kickAfterResultDelayMs), _kickProcess);
  }

  void _processForSession(
    _SessionState state,
    DateTime now,
    bool pitched,
    double probability,
    double pitchRaw,
    double rms,
  ) {
    if (state.paused) return;

    final opts = state.options;
    final nowMs = now.millisecondsSinceEpoch;

    if (nowMs - state.lastEmitMs < opts.minEventIntervalMs) return;

    // Entry gates
    if (!pitched || probability < opts.minProbability || pitchRaw <= 0) {
      _handleUnpitched(state, now, rms, probability);
      return;
    }
    if (pitchRaw < opts.minHz || pitchRaw > opts.maxHz) {
      _handleUnpitched(state, now, rms, probability);
      return;
    }

    // Onset detection — sudden energy spike + good probability = bow attack.
    final rmsDelta = rms - state.lastRms;
    final isOnset = rmsDelta > (opts.minRms * 0.25) && probability > opts.minProbability;
    if (isOnset) state.lastOnsetMs = nowMs;
    state.lastRms = rms;

    // fastMode relaxes thresholds for quicker detection in gameplay.
    final int stabilityWindow =
        opts.fastMode ? 2 : opts.stabilityWindow;
    final double minStableProb =
        opts.fastMode ? 0.75 : opts.minStableProbability;
    final double maxJitterAllowed =
        opts.fastMode ? opts.maxJitterCents * 1.35 : opts.maxJitterCents;

    // Stability window.
    state.recentPitches.add(pitchRaw);
    if (state.recentPitches.length > stabilityWindow) {
      state.recentPitches.removeAt(0);
    }
    double maxJitter = 0.0;
    if (state.recentPitches.length > 1) {
      final ref =
          state.recentPitches.reduce((a, b) => a + b) / state.recentPitches.length;
      for (final p in state.recentPitches) {
        final cd = (1200.0 * (math.log(p / ref) / math.ln2)).abs();
        if (cd > maxJitter) maxJitter = cd;
      }
    }

    final stable = probability >= minStableProb && maxJitter <= maxJitterAllowed;

    if (!stable) {
      // Allow early detection for 120 ms after a bow attack onset.
      final timeSinceOnset = nowMs - state.lastOnsetMs;
      if (!isOnset && timeSinceOnset >= 120) {
        state.confidence = (state.confidence - 0.02).clamp(0.0, 1.0);
        return;
      }
    }

    final noteInfo = _freqToNote(pitchRaw);
    if (noteInfo == null) return;

    final isNewNote = state.lastNoteLabel != noteInfo.label;

    // Re-attack detection (game mode): new note, came back from silence,
    // onset spike, or energy dropped between notes.
    final isEnergyDrop = rms < (opts.minRms * 0.6);
    final isReattack = isNewNote || state.wasUnpitched || isOnset || isEnergyDrop;

    // Smooth — null start avoids lerping from 0 on the very first frame.
    state.frequencyHz = _lerp(state.frequencyHz, pitchRaw, 0.25);
    state.cents = _lerp(state.cents, noteInfo.cents, 0.35) ?? noteInfo.cents;
    state.confidence = _lerp(state.confidence, probability, 0.35) ?? probability;
    state.lastGoodPitchMs = nowMs;
    state.lastNoteLabel = noteInfo.label;
    state.wasUnpitched = false;

    // Dedupe in discrete mode only, and only when it's not a re-attack.
    if (!opts.continuousMode && !isReattack && state.lastEmittedEvent != null) {
      final last = state.lastEmittedEvent!;
      final freqDiff = ((state.frequencyHz ?? pitchRaw) - last.frequencyHz).abs();
      final centsDiff = state.cents != null && last.centsFromNearest != null
          ? (state.cents! - last.centsFromNearest!).abs()
          : double.infinity;
      if (stable == last.stable && (freqDiff < 0.6 || centsDiff < 2.0)) return;
    }

    final centsForConf = state.cents ?? noteInfo.cents;
    final confidenceScore =
        (probability * (1.0 - (centsForConf.abs() / 50.0))).clamp(0.0, 1.0);

    final event = NoteDetectionEvent(
      timestamp: now,
      pitched: true,
      rms: rms,
      probability: probability,
      frequencyHzRaw: pitchRaw,
      frequencyHz: state.frequencyHz ?? pitchRaw,
      confidence: confidenceScore,
      noteLabel: noteInfo.label,
      midi: noteInfo.midi,
      centsFromNearest: state.cents,
      stable: stable,
      // In game mode, flag as new note whenever it's a re-attack so the game
      // screen scores it correctly.
      isNewNote: opts.continuousMode ? isNewNote : (isReattack ? true : isNewNote),
    );

    state.lastEmittedEvent = event;
    state.lastEmitMs = nowMs;
    if (!state.controller.isClosed) state.controller.add(event);
  }

  void _handleUnpitched(
    _SessionState state,
    DateTime now,
    double rms,
    double probability,
  ) {
    final opts = state.options;
    state.wasUnpitched = true;
    state.lastRms = rms;

    final sinceGood = now.millisecondsSinceEpoch - state.lastGoodPitchMs;

    if (state.lastGoodPitchMs == 0 || sinceGood > opts.holdLastGoodMs) {
      state.confidence = (state.confidence - 0.08).clamp(0.0, 1.0);
      state.frequencyHz = null;
      state.cents = null;
      state.lastNoteLabel = null;
      state.lastOnsetMs = 0;

      if (!opts.emitUnpitchedEvents) return;

      final event = NoteDetectionEvent(
        timestamp: now,
        pitched: false,
        rms: rms,
        probability: probability,
        frequencyHzRaw: 0,
        frequencyHz: 0,
        confidence: 0,
        stable: false,
        isNewNote: false,
      );

      state.lastEmittedEvent = event;
      state.lastEmitMs = now.millisecondsSinceEpoch;
      if (!state.controller.isClosed) state.controller.add(event);
    } else {
      // Hold last good — decay confidence gently.
      state.confidence = (state.confidence - 0.03).clamp(0.0, 1.0);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static double? _lerp(double? a, double b, double t) {
    if (a == null) return b;
    return a + (b - a) * t;
  }

  static _NoteInfo? _freqToNote(double freqHz) {
    if (freqHz <= 0) return null;
    final midi = 69 + 12 * (math.log(freqHz / 440.0) / math.ln2);
    if (!midi.isFinite) return null;
    final nearest = midi.round().clamp(0, 127);
    final cents = (midi - nearest) * 100.0;
    final pc = nearest % 12;
    final octave = (nearest ~/ 12) - 1;
    const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
    return _NoteInfo(label: '${names[pc]}$octave', midi: nearest, cents: cents);
  }

  // ---------------------------------------------------------------------------
  // Isolate entry point
  // ---------------------------------------------------------------------------

  static void _isolateEntry(List<dynamic> args) {
    final resultSendPort = args[0] as SendPort;
    final sampleRate = args[1] as int;
    final bufferSize = args[2] as int;

    final framePort = ReceivePort();
    resultSendPort.send(framePort.sendPort);

    final detector = PitchDetector(
      audioSampleRate: sampleRate.toDouble(),
      bufferSize: bufferSize,
    );

    final Queue<Uint8List> queue = Queue<Uint8List>();
    bool busy = false;
    bool shuttingDown = false;

    // Process frames sequentially — no parallel async pileup.
    Future<void> processNext() async {
      if (busy || shuttingDown) return;
      busy = true;
      try {
        while (queue.isNotEmpty && !shuttingDown) {
          final msg = queue.removeFirst();
          try {
            double rms = 0;
            if (msg.lengthInBytes >= 2) {
              final int16 = msg.buffer.asInt16List(
                msg.offsetInBytes, msg.lengthInBytes ~/ 2,
              );
              var sumSq = 0.0;
              for (var i = 0; i < int16.length; i++) {
                final s = int16[i].toDouble();
                sumSq += s * s;
              }
              if (int16.isNotEmpty) rms = math.sqrt(sumSq / int16.length);
            }
            final result = await detector.getPitchFromIntBuffer(msg);
            resultSendPort.send({
              'pitched': result.pitched,
              'probability': result.probability,
              'pitch': result.pitch,
              'rms': rms,
            });
          } catch (_) {
            resultSendPort.send({
              'pitched': false,
              'probability': 0.0,
              'pitch': 0.0,
              'rms': 0.0,
            });
          }
        }
      } finally {
        busy = false;
      }
    }

    framePort.listen((dynamic msg) {
      if (msg == null) return;
      if (msg == _killSignal) {
        shuttingDown = true;
        resultSendPort.send({'type': 'killAck'});
        framePort.close();
        return;
      }
      if (msg is Uint8List) {
        queue.add(msg);
        unawaited(processNext());
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Internal state per session
// ---------------------------------------------------------------------------

class _SessionState {
  _SessionState({required this.options, required this.controller});

  final NoteDetectorOptions options;
  final StreamController<NoteDetectionEvent> controller;

  final List<double> recentPitches = [];
  double? frequencyHz; // null = no data yet (avoids lerp from 0)
  double? cents;
  double confidence = 0;
  int lastGoodPitchMs = 0;
  int lastEmitMs = 0;
  String? lastNoteLabel;
  NoteDetectionEvent? lastEmittedEvent;
  bool paused = false;

  // Re-attack detection.
  bool wasUnpitched = true;

  // Onset detection.
  double lastRms = 0;
  int lastOnsetMs = 0;
}

class _NoteInfo {
  const _NoteInfo({required this.label, required this.midi, required this.cents});
  final String label;
  final int midi;
  final double cents;
}
