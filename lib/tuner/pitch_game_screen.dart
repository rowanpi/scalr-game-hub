// 100% COMPLETE + FUN & LIVELY UPGRADE VERSION
// Everything from your original file + new features
// NO missing classes or methods — copy-paste this entire file

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Velocity;
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_confetti/flutter_confetti.dart';
import 'package:newton_particles/newton_particles.dart';

import '../practice_log/recording_session_service.dart';
import '../services/note_detector_service.dart';

// Base neon palette (aligns with base image: green, pink, blue, purple) — used in-game only
const Color _gameDarkBg = Color(0xFF0D1F0D);
const Color _baseNeonGreen = Color(0xFF00E676);
// ignore: unused_element - kept for in-game/base image palette
const Color _baseNeonPink = Color(0xFFFF6EC7);
const Color _baseNeonBlue = Color(0xFF00E5FF);
// ignore: unused_element - kept for in-game/base image palette
const Color _baseNeonPurple = Color(0xFFB388FF);

// Game UI palette for start/score screens (no neon)
const Color _gamePanelBg = Color(0xFF1a2520);
const Color _gamePanelBorder = Color(0xFF3d4f45);
const Color _gameText = Color(0xFFe8e4e0);
const Color _gameTextSecondary = Color(0xFFb0a89e);


/// Root note names: naturals, then sharps, then flats (C, C#, D, Eb, E, F, F#/Gb, G, Ab, A, Bb, B)
const List<String> _rootNoteNames = [
  'C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B',
];

int _startMidiForRoot(String root) {
  const map = {
    'C': 60, 'C#': 61, 'Db': 61, 'D': 62, 'D#': 63, 'Eb': 63, 'E': 64,
    'F': 65, 'F#': 66, 'Gb': 66, 'G': 67, 'G#': 68, 'Ab': 68, 'A': 69,
    'A#': 70, 'Bb': 70, 'B': 71,
  };
  return map[root] ?? 60;
}

/// Midi number (0-127) for a note label (e.g. C#4, Db4) for pitch comparison.
int _noteLabelToMidi(String label) {
  final match = RegExp(r'^([A-G])(#|b)?(\d+)$').firstMatch(label);
  if (match == null) return 60;
  const pitchClass = {
    'C': 0, 'C#': 1, 'Db': 1, 'D': 2, 'D#': 3, 'Eb': 3, 'E': 4, 'F': 5,
    'F#': 6, 'Gb': 6, 'G': 7, 'G#': 8, 'Ab': 8, 'A': 9, 'A#': 10, 'Bb': 10, 'B': 11,
  };
  final name = match[2] != null ? '${match[1]}${match[2]}' : match[1]!;
  final pc = pitchClass[name] ?? 0;
  final octave = int.tryParse(match[3] ?? '4') ?? 4;
  return (octave + 1) * 12 + pc;
}

List<int> _intervalsFor(bool isArpeggio, bool isMinor) {
  if (isArpeggio) return isMinor ? [0, 3, 7] : [0, 4, 7];
  return isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11];
}

const List<String> _sharpNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const List<String> _flatNames = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'];

String _midiToNoteLabel(int midi, {bool useFlats = false}) {
  final names = useFlats ? _flatNames : _sharpNames;
  final pc = midi % 12;
  final octave = (midi ~/ 12) - 1;
  return '${names[pc]}$octave';
}

bool _rootUsesFlats(String root) =>
    root == 'Db' || root == 'Eb' || root == 'Gb' || root == 'Ab' || root == 'Bb';

String _noteLabelForDisplay(String label) =>
    label.replaceFirst('#', '♯').replaceFirst('b', '♭');

List<String> buildScaleNotes({
  required bool isArpeggio,
  required String root,
  required bool isMinor,
  required int octaves,
}) {
  final startMidi = _startMidiForRoot(root);
  final intervals = _intervalsFor(isArpeggio, isMinor);
  final useFlats = _rootUsesFlats(root);
  final notes = <String>[];
  for (var oct = 0; oct < octaves; oct++) {
    for (final semitones in intervals) {
      notes.add(_midiToNoteLabel(startMidi + oct * 12 + semitones, useFlats: useFlats));
    }
  }
  // Include the top note only (e.g. D6 for 2 octaves in D)
  notes.add(_midiToNoteLabel(startMidi + octaves * 12, useFlats: useFlats));
  return notes;
}

double _noteToFreqHz(String label) {
  final match = RegExp(r'^([A-G])(#|b)?(\d+)$').firstMatch(label);
  if (match == null) return 440.0;
  const pitchClass = {
    'C': 0, 'C#': 1, 'Db': 1, 'D': 2, 'D#': 3, 'Eb': 3, 'E': 4, 'F': 5,
    'F#': 6, 'Gb': 6, 'G': 7, 'G#': 8, 'Ab': 8, 'A': 9, 'A#': 10, 'Bb': 10, 'B': 11,
  };
  final name = match[2] != null ? '${match[1]}${match[2]}' : match[1]!;
  final pc = pitchClass[name] ?? 0;
  final octave = int.tryParse(match[3] ?? '4') ?? 4;
  final midi = (octave + 1) * 12 + pc;
  return 440.0 * math.pow(2.0, (midi - 69) / 12.0);
}

double _centsFromTarget(double pitchHz, String targetLabel) {
  final targetFreq = _noteToFreqHz(targetLabel);
  if (targetFreq <= 0) return 0;
  return 1200.0 * (math.log(pitchHz / targetFreq) / math.ln2);
}

String _freqToNoteLabel(double freqHz) {
  if (freqHz <= 0) return '—';
  final midi = 69 + 12 * (math.log(freqHz / 440.0) / math.ln2);
  if (!midi.isFinite) return '—';
  final nearest = midi.round().clamp(0, 127);
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  final pc = nearest % 12;
  final octave = (nearest ~/ 12) - 1;
  return '${names[pc]}$octave';
}

String _scoreGrade(int score) {
  if (score >= 95) return 'S';
  if (score >= 85) return 'A';
  if (score >= 70) return 'B';
  if (score >= 50) return 'C';
  return 'D';
}

class PitchGameScreen extends StatefulWidget {
  const PitchGameScreen({super.key});

  @override
  State<PitchGameScreen> createState() => _PitchGameScreenState();
}

class _FallingNote {
  _FallingNote({
    required this.id,
    required this.note,
    required this.x,
    required this.y,
    required this.characterIndex,
    this.isPowerNote = false,
  });
  final int id;
  final String note;
  double x;
  double y;
  final int characterIndex;
  bool isExploding = false;
  double? signedCents;
  final bool isPowerNote;
}

class _GameNoteResult {
  _GameNoteResult({required this.note, required this.hit, this.signedCents});
  final String note;
  final bool hit;
  final double? signedCents;
}

class _PendingMiss {
  const _PendingMiss({required this.id, required this.note, required this.x, required this.y});
  final int id;
  final String note;
  final double x;
  final double y;
}

class _Bullet {
  _Bullet({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.targetNoteId,
    required this.note,
    required this.signedCents,
  });
  double x;
  double y;
  final double vx;
  final double vy;
  final int targetNoteId;
  final String note;
  final double signedCents;
}

class _FloatingFeedback {
  _FloatingFeedback({
    required this.text,
    required this.color,
    required this.x,
    required this.y,
    this.points = 0,
  });
  final String text;
  final Color color;
  final double x;
  double y;
  final int points;
  double life = 1.3;
  double vy = -38;
}

class _PitchGameScreenState extends State<PitchGameScreen>
    with WidgetsBindingObserver {
  NoteDetectorSession? _session;
  StreamSubscription<NoteDetectionEvent>? _eventSub;
  bool _listening = false;
  bool _starting = false;
  String? _error;

  bool _gameOver = false;
  final List<_FallingNote> _fallingNotes = [];
  final List<_GameNoteResult> _results = [];
  int _nextNoteId = 0;
  double _nextSpawnAt = 0;
  double _gameTime = 0;
  static const double _baseFallSpeed = 42.0;
  double _currentFallSpeed = _baseFallSpeed;
  static const int _totalNotesToSpawn = 20;
  int _spawnedCount = 0;
  final math.Random _random = math.Random();

  String _lastDetectedLabel = '—';
  static const double _hitZoneHeight = 120;
  /// Base image aspect 1094×541; height computed from width so it fits properly.
  double get _baseHeight => _gameAreaWidth > 0 ? _gameAreaWidth * (541 / 1094) : 56;
  double _gameAreaHeight = 600;
  double _gameAreaWidth = 320;
  Timer? _gameTickTimer;
  final GlobalKey<NewtonState> _newtonKey = GlobalKey<NewtonState>();

  static const _audioShoot = 'assets/audio/shoot.mp3';
  static const _audioExplode = 'assets/audio/explode.mp3';
  static const _audioEnemy = 'assets/audio/enemy.mp3';
  AudioPlayer? _shootPlayer;
  AudioPlayer? _explodePlayer;
  AudioPlayer? _enemyPlayer;

  static const _characterSpriteSheetAsset = 'assets/images/characterSpriteSheet.png';
  ui.Image? _characterSpriteSheet;

  bool _scaleIsArpeggio = false;
  String _rootNote = 'D';
  bool _scaleIsMinor = false;
  int _scaleOctaves = 2;
  bool _sfxEnabled = false;

  List<String> _currentScaleNotes = buildScaleNotes(
      isArpeggio: true, root: 'D', isMinor: false, octaves: 2);
  Set<String> _selectedScaleNotes = {
    ...buildScaleNotes(isArpeggio: true, root: 'D', isMinor: false, octaves: 2),
  };

  final Map<int, _PendingMiss> _pendingMisses = {};
  final Map<int, Timer> _pendingMissTimers = {};

  final List<_Bullet> _bullets = [];
  final Set<int> _noteIdsWithBulletInFlight = {};
  double _gunAngle = -math.pi / 2;

  /// New fun features
  int _combo = 0;
  int _maxCombo = 0;
  final List<_FloatingFeedback> _floatingFeedbacks = [];
  double _gunRecoil = 0.0;
  double _screenFlash = 0.0;
  static const double _bulletSpeed = 380.0;
  static const double _bulletHitRadius = 36.0;
  static const int _maxLives = 3;
  int _lives = _maxLives;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _loadCharacterSpriteSheet();
  }

  Future<void> _loadCharacterSpriteSheet() async {
    try {
      final bytes = await rootBundle.load(_characterSpriteSheetAsset);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (mounted) {
        setState(() => _characterSpriteSheet = frame.image);
      }
    } catch (_) {
      // Asset missing or decode failed; fallback to drawn note shape
    }
  }

  void _ensureSfxPlayers() {
    if (_shootPlayer != null) return;
    _shootPlayer = AudioPlayer();
    _explodePlayer = AudioPlayer();
    _enemyPlayer = AudioPlayer();
  }

  Future<void> _disposeSfxPlayers() async {
    await _shootPlayer?.dispose();
    await _explodePlayer?.dispose();
    await _enemyPlayer?.dispose();
    _shootPlayer = null;
    _explodePlayer = null;
    _enemyPlayer = null;
  }

  Future<void> _runSfxWithMicPause(AudioPlayer player, String assetPath) async {
    if (!_listening || _session == null) return;
    await _session!.pause();
    try {
      if (!mounted || !_listening) return;
      await player.setAsset(assetPath);
      await player.play();
      await player.processingStateStream
          .where((s) => s == ProcessingState.completed)
          .first
          .timeout(const Duration(seconds: 2), onTimeout: () => ProcessingState.completed);
    } catch (_) {}
    finally {
      if (mounted && _listening && _session != null) {
        await _session!.resume();
      }
    }
  }

  void _playShoot() {
    if (!_sfxEnabled || _shootPlayer == null) return;
    unawaited(_runSfxWithMicPause(_shootPlayer!, _audioShoot));
  }

  void _playExplode() {
    if (!_sfxEnabled || _explodePlayer == null) return;
    unawaited(_runSfxWithMicPause(_explodePlayer!, _audioExplode));
  }

  void _playEnemy() {
    if (!_sfxEnabled || _enemyPlayer == null) return;
    unawaited(_runSfxWithMicPause(_enemyPlayer!, _audioEnemy));
  }

  void _startGameLoop() {
    _gameTickTimer?.cancel();
    _gameTime = 0;
    _nextSpawnAt = 1.2;
    _combo = 0;
    _maxCombo = 0;
    _lives = _maxLives;
    _currentFallSpeed = _baseFallSpeed;
    _floatingFeedbacks.clear();
    _gunRecoil = 0;
    _screenFlash = 0;
    _gameTickTimer = Timer.periodic(const Duration(milliseconds: 16), (_) => _onGameTick());
  }

  (double, double)? _computeTrajectory(double gx, double gy, double nx, double ny) {
    const fallSpeed = _baseFallSpeed;
    const v = _bulletSpeed;
    final dx = nx - gx;
    final dy = ny - gy;
    if (dy >= 0) return null;
    if (dx.abs() < 1e-6) return (0, -v);
    final a = 1 + (dy * dy) / (dx * dx);
    final b = 2 * (dy / dx) * fallSpeed;
    final c = fallSpeed * fallSpeed - v * v;
    final disc = b * b - 4 * a * c;
    if (disc < 0) return null;
    final sqrtDisc = math.sqrt(disc);
    for (final sign in [1.0, -1.0]) {
      final vx = (-b + sign * sqrtDisc) / (2 * a);
      final vy = vx * dy / dx + fallSpeed;
      if (vy > 0) continue;
      if ((vx > 0) != (dx > 0)) continue;
      return (vx, vy);
    }
    return null;
  }

  void _onGameTick() {
    if (!mounted || _gameOver) return;
    const dt = 1 / 60.0;
    _gameTime += dt;

    _currentFallSpeed = _baseFallSpeed + (_gameTime * 4.2).clamp(0, 48);
    _gunRecoil *= 0.78;
    _screenFlash *= 0.86;

    for (int i = _floatingFeedbacks.length - 1; i >= 0; i--) {
      final f = _floatingFeedbacks[i];
      f.life -= dt * 1.1;
      f.vy *= 0.94;
      f.y += f.vy * dt;
      if (f.life <= 0) _floatingFeedbacks.removeAt(i);
    }

    final screenH = _gameAreaHeight;
    final baseY = screenH - _baseHeight;
    const _explodeOffsetAboveBottom = 35.0;
    final explodeY = baseY + _baseHeight - _explodeOffsetAboveBottom;

    final toRemove = <int>[];
    for (final n in _fallingNotes) {
      if (n.isExploding) continue;
      n.y += _currentFallSpeed * dt;
      if (n.y >= explodeY) {
        toRemove.add(n.id);
        final id = n.id;
        final note = n.note;
        final x = n.x;
        final y = n.y;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final cs = Theme.of(context).colorScheme;
          final base = ExplosionPreset(
            origin: Offset(x / _gameAreaWidth, y / _gameAreaHeight),
            particleCount: 45,
            particlesPerEmit: 45,
            colors: [cs.error, Colors.orange, Colors.red],
          ).toConfiguration();
          final config = base.copyWith(
            physicsProperties: PhysicsProperties(
              gravity: base.gravity,
              angle: const NumRange.between(0, 360),
              velocity: NumRange.between(Velocity.custom(1.8), Velocity.custom(6)),
              solidEdges: SolidEdges.none,
            ),
            emissionProperties: base.emissionProperties.copyWith(
              particleLifespan: DurationRange.between(
                const Duration(milliseconds: 600),
                const Duration(milliseconds: 1200),
              ),
            ),
          );
          _newtonKey.currentState?.addEffect(config);
        });
        _pendingMisses[id] = _PendingMiss(id: id, note: note, x: x, y: y);
        _pendingMissTimers[id] = Timer(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          if (_pendingMisses.remove(id) != null) {
            _pendingMissTimers.remove(id);
            _playEnemy();
            setState(() {
              _results.add(_GameNoteResult(note: note, hit: false));
              _combo = 0;
              _screenFlash = 0.9;
              _lives = (_lives - 1).clamp(0, _maxLives);
            });
            if (_lives <= 0) {
              _gameOver = true;
              _gameTickTimer?.cancel();
              _recordGameToSession();
              if (mounted) setState(() {});
            }
          }
        });
      }
    }
    for (final id in toRemove) {
      _fallingNotes.removeWhere((n) => n.id == id);
    }

    final bulletsToRemove = <_Bullet>[];
    for (final b in _bullets) {
      b.x += b.vx * dt;
      b.y += b.vy * dt;
      if (b.y < -30 || b.x < -30 || b.x > _gameAreaWidth + 30) {
        bulletsToRemove.add(b);
        _noteIdsWithBulletInFlight.remove(b.targetNoteId);
        continue;
      }
      _FallingNote? note;
      for (final n in _fallingNotes) {
        if (n.id == b.targetNoteId) {
          note = n;
          break;
        }
      }
      if (note != null) {
        final dist = math.sqrt((b.x - note.x) * (b.x - note.x) + (b.y - note.y) * (b.y - note.y));
        if (dist <= _bulletHitRadius) {
          bulletsToRemove.add(b);
          _noteIdsWithBulletInFlight.remove(b.targetNoteId);
          _playExplode();
          final hitNote = note;
          final signedCents = b.signedCents;
          final absCents = signedCents.abs();

          String fbText = 'NICE!';
          Color fbColor = Colors.white;
          int bonusPoints = 100;
          int particleCount = 40;

          if (absCents < 7) {
            fbText = 'PERFECT!';
            fbColor = Colors.amberAccent;
            bonusPoints = 180;
            particleCount = 75;
          } else if (absCents < 16) {
            fbText = 'GREAT!';
            fbColor = Colors.lightGreen;
            bonusPoints = 140;
            particleCount = 55;
          }

          _combo++;
          if (_combo > _maxCombo) _maxCombo = _combo;

          _floatingFeedbacks.add(_FloatingFeedback(
            text: '$fbText\n+$bonusPoints',
            color: fbColor,
            x: hitNote.x,
            y: hitNote.y - 50,
            points: bonusPoints,
          ));

          setState(() {
            _results.add(_GameNoteResult(note: hitNote.note, hit: true, signedCents: signedCents));
            hitNote.isExploding = true;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final cs = Theme.of(context).colorScheme;
            final base = ExplosionPreset(
              origin: Offset(hitNote.x / _gameAreaWidth, hitNote.y / _gameAreaHeight),
              particleCount: particleCount,
              particlesPerEmit: particleCount,
              colors: hitNote.isPowerNote
                  ? [Colors.amber, Colors.yellow, cs.primary]
                  : [cs.primary, cs.tertiary, cs.error],
            ).toConfiguration();
            final config = base.copyWith(
              physicsProperties: PhysicsProperties(
                gravity: base.gravity,
                angle: const NumRange.between(0, 360),
                velocity: NumRange.between(Velocity.custom(1.8), Velocity.custom(6)),
                solidEdges: SolidEdges.none,
              ),
              emissionProperties: base.emissionProperties.copyWith(
                particleLifespan: DurationRange.between(
                  const Duration(milliseconds: 700),
                  const Duration(milliseconds: 1400),
                ),
              ),
            );
            _newtonKey.currentState?.addEffect(config);
          });

          if (hitNote.isPowerNote) {
            _combo += 3;
            if (_combo > _maxCombo) _maxCombo = _combo;
          }

          Future.delayed(const Duration(milliseconds: 220), () {
            if (!mounted) return;
            setState(() {
              _fallingNotes.removeWhere((n) => n.id == hitNote.id);
              if (_spawnedCount >= _totalNotesToSpawn && _fallingNotes.isEmpty) {
                _gameOver = true;
                _gameTickTimer?.cancel();
                _recordGameToSession();
              }
            });
          });
        }
      }
    }
    for (final b in bulletsToRemove) {
      _bullets.remove(b);
    }

    if (_spawnedCount < _totalNotesToSpawn && _gameTime >= _nextSpawnAt) {
      _spawnedCount++;
      _nextSpawnAt = _gameTime + 2.0 + _random.nextDouble() * 1.1;
      final note = _currentScaleNotes[_random.nextInt(_currentScaleNotes.length)];
      final w = _gameAreaWidth > 60 ? _gameAreaWidth - 56 : 200.0;
      final x = 28.0 + _random.nextDouble() * w;
      final isPowerNote = _random.nextInt(100) < 11;
      _fallingNotes.add(_FallingNote(
        id: _nextNoteId++,
        note: note,
        x: x,
        y: -40,
        characterIndex: _random.nextInt(8),
        isPowerNote: isPowerNote,
      ));
    }

    final allSpawned = _spawnedCount >= _totalNotesToSpawn;
    final allResolved = _fallingNotes.isEmpty;
    if (allSpawned && allResolved && !_gameOver) {
      _gameOver = true;
      _gameTickTimer?.cancel();
      _recordGameToSession();
    }
    if (mounted) setState(() {});
  }

  void _recordGameToSession() {
    if (!RecordingSessionService.instance.isRecording) return;
    final secs = _gameTime.round();
    if (secs <= 0) return;
    RecordingSessionService.instance.addItem('Pitch Defender', durationSeconds: secs);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _gameTickTimer?.cancel();
    for (final t in _pendingMissTimers.values) t.cancel();
    _pendingMissTimers.clear();
    _pendingMisses.clear();
    unawaited(_disposeSfxPlayers());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _shutdown() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _session?.dispose();
    _session = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_stop());
    }
  }

  Future<void> _start() async {
    if (_listening || _starting) return;
    final allNotes = buildScaleNotes(
      isArpeggio: _scaleIsArpeggio,
      root: _rootNote,
      isMinor: _scaleIsMinor,
      octaves: _scaleOctaves,
    );
    final selectedList = allNotes.where((n) => _selectedScaleNotes.contains(n)).toList();
    if (selectedList.isEmpty) {
      setState(() => _error = 'Select at least one note to play.');
      return;
    }

    setState(() {
      _currentScaleNotes = selectedList;
      _starting = true;
      _error = null;
    });

    try {
      final options = NoteDetectorOptions(
        minRms: 450.0,
        minProbability: 0.45,
        minHz: 180.0,
        maxHz: 2200.0,
        stabilityWindow: 4,
        minStableProbability: 0.82,
        maxJitterCents: 22.0,
        holdLastGoodMs: 1450,
        minEventIntervalMs: 50,
        emitUnpitchedEvents: false,
      );

      _session = await NoteDetectorService.instance.acquire(options);
      _eventSub = _session!.events.listen(_onNoteEvent, onError: (e) {
        if (!mounted) return;
        setState(() => _error = 'Mic error: $e');
      });

      if (!mounted) return;
      setState(() {
        _listening = true;
        _starting = false;
      });
      _startGameLoop();
      if (_sfxEnabled) _ensureSfxPlayers();
    } on TimeoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Timed out. Try a real device.';
        _starting = false;
        _listening = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not start: $e';
        _starting = false;
        _listening = false;
      });
    }
  }

  Future<void> _stop() async {
    if (!_listening && !_starting) return;
    _gameTickTimer?.cancel();
    for (final t in _pendingMissTimers.values) t.cancel();
    _pendingMissTimers.clear();
    _pendingMisses.clear();
    _bullets.clear();
    _noteIdsWithBulletInFlight.clear();
    _fallingNotes.clear();
    _results.clear();
    await _disposeSfxPlayers();
    await _eventSub?.cancel();
    _eventSub = null;
    await _session?.dispose();
    _session = null;
    if (!mounted) return;
    setState(() {
      _listening = false;
      _starting = false;
      _gameOver = false;
      _spawnedCount = 0;
    });
  }


  void _onNoteEvent(NoteDetectionEvent event) {
    if (!mounted) return;

    if (!event.pitched || event.noteLabel == null) {
      setState(() {
        _lastDetectedLabel = '—';
      });
      return;
    }

    // High violin notes often report lower detector confidence.
    // Keep stricter threshold for low/mid notes, relax for upper register (>= ~A5).
    final minProbability = event.frequencyHz >= 880 ? 0.30 : 0.45;
    if (event.probability < minProbability) {
      setState(() {
        _lastDetectedLabel = '—';
      });
      return;
    }

    final label = event.noteLabel!;
    final pitch = event.frequencyHz;

    setState(() {
      _lastDetectedLabel = label;
    });

    final labelMidi = _noteLabelToMidi(label);
    final scaleMidis = _currentScaleNotes.map(_noteLabelToMidi).toSet();
    if (_gameOver || !scaleMidis.contains(labelMidi)) {
      return;
    }

    // Only shoot on new notes to avoid repeated hits from sustained notes
    if (!event.isNewNote) {
      return;
    }

    final baseY = _gameAreaHeight - _baseHeight;
    final hasMatchingNote = _fallingNotes.any((n) =>
        !n.isExploding && _noteLabelToMidi(n.note) == labelMidi);
    final hasMatchInPending = _pendingMisses.values
        .any((p) => _noteLabelToMidi(p.note) == labelMidi);

    if (!hasMatchingNote && !hasMatchInPending) {
      return;
    }

    _PendingMiss? pendingMatch;
    for (final entry in _pendingMisses.entries) {
      if (_noteLabelToMidi(entry.value.note) == labelMidi) {
        pendingMatch = entry.value;
        break;
      }
    }
    if (pendingMatch != null) {
      _pendingMissTimers.remove(pendingMatch.id)?.cancel();
      _pendingMisses.remove(pendingMatch.id);
      final signedCents = _centsFromTarget(pitch, pendingMatch.note);
      setState(() {
        _results.add(_GameNoteResult(note: pendingMatch!.note, hit: true, signedCents: signedCents));
        _combo++;
        if (_combo > _maxCombo) _maxCombo = _combo;
        _floatingFeedbacks.add(_FloatingFeedback(
          text: 'LATE HIT!',
          color: Colors.white,
          x: pendingMatch.x,
          y: pendingMatch.y - 60,
        ));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final base = ExplosionPreset(
          origin: Offset(pendingMatch!.x / _gameAreaWidth, pendingMatch.y / _gameAreaHeight),
          particleCount: 35,
        ).toConfiguration();
        _newtonKey.currentState?.addEffect(base);
      });
      return;
    }

    _FallingNote? nextNote;
    double bestY = -double.infinity;
    for (final n in _fallingNotes) {
      if (n.isExploding || _noteLabelToMidi(n.note) != labelMidi) continue;
      if (n.y > bestY) {
        bestY = n.y;
        nextNote = n;
      }
    }
    final target = nextNote != null && !_noteIdsWithBulletInFlight.contains(nextNote.id) ? nextNote : null;

    if (target != null) {
      final t = target;
      final signedCents = _centsFromTarget(pitch, t.note);
      final gunX = _gameAreaWidth / 2;
      final gunY = baseY + _baseHeight / 2;
      var traj = _computeTrajectory(gunX, gunY, t.x, t.y);

      if (traj == null) {
        final dx = t.x - gunX;
        final dy = t.y - gunY;
        if (dy < 0) {
          final dist = (dx * dx + dy * dy);
          if (dist > 1) {
            final v = _bulletSpeed;
            traj = (v * dx / dist, v * dy / dist);
          }
        }
      }

      if (traj != null) {
        final (vx, vy) = traj;
        _playShoot();
        setState(() {
          _gunAngle = math.atan2(-vy, vx);
          _gunRecoil = 14;
          _noteIdsWithBulletInFlight.add(t.id);
          _bullets.add(_Bullet(
            x: gunX,
            y: gunY,
            vx: vx,
            vy: vy,
            targetNoteId: t.id,
            note: t.note,
            signedCents: signedCents,
          ));
        });
      }
    }
  }

  void _resetGame() {
    _gameTickTimer?.cancel();
    for (final t in _pendingMissTimers.values) t.cancel();
    _pendingMissTimers.clear();
    _pendingMisses.clear();
    _bullets.clear();
    _noteIdsWithBulletInFlight.clear();
    _gunAngle = -math.pi / 2;
    _nextNoteId = 0;
    setState(() {
      _gameOver = false;
      _fallingNotes.clear();
      _results.clear();
      _spawnedCount = 0;
      _combo = 0;
      _maxCombo = 0;
      _lives = _maxLives;
      _nextSpawnAt = 0;
      _gameTime = 0;
      _lastDetectedLabel = '—';
    });
    _startGameLoop();
  }

  void _goToScaleScreen() async {
    _gameTickTimer?.cancel();
    for (final t in _pendingMissTimers.values) t.cancel();
    _pendingMissTimers.clear();
    _pendingMisses.clear();
    _bullets.clear();
    _noteIdsWithBulletInFlight.clear();
    _fallingNotes.clear();
    _results.clear();
    if (mounted) setState(() {
      _gameOver = false;
      _spawnedCount = 0;
      _combo = 0;
      _maxCombo = 0;
    });
    await _stop();
  }

  /// Life bonus: 20 per life left (max 60). Intonation: up to 40 from how in-tune correct hits were. Combo: up to 10 extra.
  int get _finalScore {
    final lifeBonus = _lives * 20; // 0, 20, 40, or 60
    double intonationRaw = 0;
    for (final r in _results) {
      if (!r.hit || r.signedCents == null) continue;
      final absCents = r.signedCents!.abs();
      // 0 cents = 2 pts, 50 cents = 0; max 2 pts per note, so max 40 for 20 notes
      intonationRaw += (2 - (absCents / 25).clamp(0.0, 2.0));
    }
    final intonationScore = intonationRaw.round().clamp(0, 40);
    final comboBonus = _totalNotesToSpawn > 0
        ? (10.0 * _maxCombo / _totalNotesToSpawn).round().clamp(0, 10)
        : 0;
    final total = lifeBonus + intonationScore + comboBonus;
    return total.clamp(0, 100);
  }

  /// Breakdown for display: [lifeBonus, intonationScore, comboBonus].
  List<int> get _scoreBreakdown {
    final lifeBonus = _lives * 20;
    double intonationRaw = 0;
    for (final r in _results) {
      if (!r.hit || r.signedCents == null) continue;
      final absCents = r.signedCents!.abs();
      intonationRaw += (2 - (absCents / 25).clamp(0.0, 2.0));
    }
    final intonationScore = intonationRaw.round().clamp(0, 40);
    final comboBonus = _totalNotesToSpawn > 0
        ? (10.0 * _maxCombo / _totalNotesToSpawn).round().clamp(0, 10)
        : 0;
    return [lifeBonus, intonationScore, comboBonus];
  }

  double get _accuracyPercent {
    final misses = _results.where((r) => !r.hit).length;
    final hits = _totalNotesToSpawn - misses;
    return _totalNotesToSpawn > 0 ? (hits / _totalNotesToSpawn) * 100 : 0;
  }

  static const _positiveMessages = [
    'You crushed it!',
    'Legendary ear!',
    'Violin hero!',
    'Unstoppable!',
    'Masterful!',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final headingColor = Color.lerp(cs.primary, Colors.white, 0.22)!;
    final mediaH = MediaQuery.of(context).size.height;
    _gameAreaHeight = mediaH - 220;

    final content = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_starting && !_listening)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Starting…',
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (!_listening) ...[
              Expanded(
                child: SingleChildScrollView(
                  child: _GameTheme(
                    spriteSheet: _characterSpriteSheet,
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Choose a scale from which the notes would be selected. Then defend the base! Play each note before it reaches the bottom.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _gameText,
                        height: 1.35,
                      ),
                    ),
                    if (!_starting && !_gameOver) ...[
                      const SizedBox(height: 20),
                      _GameLabel('Type', color: headingColor),
                      const SizedBox(height: 4),
                      _SectionAccentBar(color: headingColor),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Scale'), icon: Icon(Icons.music_note_rounded, size: 18)),
                          ButtonSegment(value: true, label: Text('Arpeggio'), icon: Icon(Icons.arrow_upward_rounded, size: 18)),
                        ],
                        selected: {_scaleIsArpeggio},
                        onSelectionChanged: (s) => setState(() {
                        _scaleIsArpeggio = s.first;
                        _selectedScaleNotes = Set.from(buildScaleNotes(
                          isArpeggio: _scaleIsArpeggio,
                          root: _rootNote,
                          isMinor: _scaleIsMinor,
                          octaves: _scaleOctaves,
                        ));
                      }),
                      ),
                      const SizedBox(height: 14),
                      _GameLabel('Root', color: headingColor),
                      const SizedBox(height: 4),
                      _SectionAccentBar(color: headingColor),
                      const SizedBox(height: 8),
                      Material(
                        type: MaterialType.transparency,
                        child: DropdownButton<String>(
                          value: _rootNote,
                          dropdownColor: _gamePanelBg,
                          iconEnabledColor: headingColor,
                          underline: Container(height: 1, color: _gamePanelBorder),
                          style: TextStyle(color: _gameText, fontWeight: FontWeight.w600, fontSize: 16),
                          items: _rootNoteNames.map((n) => DropdownMenuItem(
                            value: n,
                            child: Text(n, style: TextStyle(color: _gameText)),
                          )).toList(),
                          onChanged: (v) => setState(() {
                          _rootNote = v ?? _rootNote;
                          _selectedScaleNotes = Set.from(buildScaleNotes(
                            isArpeggio: _scaleIsArpeggio,
                            root: _rootNote,
                            isMinor: _scaleIsMinor,
                            octaves: _scaleOctaves,
                          ));
                        }),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _GameLabel('Quality', color: headingColor),
                      const SizedBox(height: 4),
                      _SectionAccentBar(color: headingColor),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Major')),
                          ButtonSegment(value: true, label: Text('Minor')),
                        ],
                        selected: {_scaleIsMinor},
                        onSelectionChanged: (s) => setState(() {
                        _scaleIsMinor = s.first;
                        _selectedScaleNotes = Set.from(buildScaleNotes(
                          isArpeggio: _scaleIsArpeggio,
                          root: _rootNote,
                          isMinor: _scaleIsMinor,
                          octaves: _scaleOctaves,
                        ));
                      }),
                      ),
                      const SizedBox(height: 14),
                      _GameLabel('Octaves', color: headingColor),
                      const SizedBox(height: 4),
                      _SectionAccentBar(color: headingColor),
                      const SizedBox(height: 8),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1')),
                          ButtonSegment(value: 2, label: Text('2')),
                          ButtonSegment(value: 3, label: Text('3')),
                        ],
                        selected: {_scaleOctaves},
                        onSelectionChanged: (s) => setState(() {
                        _scaleOctaves = s.first;
                        _selectedScaleNotes = Set.from(buildScaleNotes(
                          isArpeggio: _scaleIsArpeggio,
                          root: _rootNote,
                          isMinor: _scaleIsMinor,
                          octaves: _scaleOctaves,
                        ));
                      }),
                      ),
                      const SizedBox(height: 14),
                      _GameLabel('Notes in game', color: headingColor),
                      const SizedBox(height: 4),
                      _SectionAccentBar(color: headingColor),
                      const SizedBox(height: 8),
                      Text(
                        'Tap a note to include or exclude it. All selected by default.',
                        style: theme.textTheme.bodySmall?.copyWith(color: _gameTextSecondary),
                      ),
                      const SizedBox(height: 10),
                      _ScaleNoteGrid(
                        notes: buildScaleNotes(
                          isArpeggio: _scaleIsArpeggio,
                          root: _rootNote,
                          isMinor: _scaleIsMinor,
                          octaves: _scaleOctaves,
                        ),
                        selected: _selectedScaleNotes,
                        onToggle: (note) => setState(() {
                          final next = Set<String>.from(_selectedScaleNotes);
                          if (next.contains(note)) {
                            if (next.length > 1) next.remove(note);
                          } else {
                            next.add(note);
                          }
                          _selectedScaleNotes = next;
                        }),
                      ),
                      const SizedBox(height: 14),
                      SwitchListTile(
                        title: Text(
                          'Sound effects',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _gameText,
                          ),
                        ),
                        subtitle: Text(
                          'Mic briefly pauses while each sound plays, then resumes. This often impacts the game playing experience, and so it is best to keep it off',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _gameTextSecondary,
                          ),
                        ),
                        value: _sfxEnabled,
                        onChanged: (v) => setState(() => _sfxEnabled = v),
                        contentPadding: EdgeInsets.zero,
                        activeColor: cs.primary,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _starting ? null : _start,
                        icon: _starting
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                              )
                            : const Icon(Icons.mic_rounded),
                        label: Text(_starting ? 'Starting…' : 'Start game'),
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            ),
            const SizedBox(height: 16),
            ],

            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: cs.error, fontWeight: FontWeight.w600)),
            ],

            const SizedBox(height: 12),

            if (_gameOver) ...[
              Expanded(
                child: _AnimatedScoreReport(
                  score: _finalScore,
                  accuracy: _accuracyPercent,
                  maxCombo: _maxCombo,
                  results: _results,
                  message: _positiveMessages[_finalScore.clamp(0, 99) % _positiveMessages.length],
                  grade: _scoreGrade(_finalScore),
                  scoreBreakdown: _scoreBreakdown,
                  spriteSheet: _characterSpriteSheet,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _resetGame,
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Play again'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _goToScaleScreen,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('New game'),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
              ),
            ] else if (_listening) ...[
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final h = constraints.maxHeight;
                    final w = constraints.maxWidth;
                    if (h > 0) _gameAreaHeight = h;
                    if (w > 0) _gameAreaWidth = w;
                    return Newton(
                      key: _newtonKey,
                      effectConfigurations: const [],
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(child: Container(color: Colors.black)),
                          if (_screenFlash > 0.05)
                            Positioned.fill(child: Container(color: Colors.red.withOpacity(_screenFlash * 0.35))),

                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: _hitZoneHeight,
                            child: Align(
                              alignment: Alignment.center,
                              child: Text(
                                'Play note here',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: cs.onSurface.withOpacity(0.8),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),

                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: _baseHeight,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.center,
                              children: [
                                Positioned.fill(
                                  child: Image.asset(
                                    'assets/images/base.png',
                                    fit: BoxFit.fitWidth,
                                    alignment: Alignment.bottomCenter,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: _baseHeight + 20,
                            height: 28,
                            child: Container(color: Colors.black),
                          ),

                          for (final b in _bullets)
                            Positioned(
                              left: b.x - 6,
                              top: b.y - 6,
                              width: 12,
                              height: 12,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: cs.primary,
                                  boxShadow: [BoxShadow(color: cs.primary.withOpacity(0.8), blurRadius: 8, spreadRadius: 2)],
                                ),
                              ),
                            ),

                          for (final n in _fallingNotes)
                            _FallingNoteWidget(
                              note: n.note,
                              x: n.x,
                              y: n.y,
                              areaHeight: h,
                              isExploding: n.isExploding,
                              isPowerNote: n.isPowerNote,
                              characterIndex: n.characterIndex,
                              gameTime: _gameTime,
                              spriteSheet: _characterSpriteSheet,
                            ),

                          for (final f in _floatingFeedbacks)
                            Positioned(
                              left: f.x - 70,
                              top: f.y,
                              child: Opacity(
                                opacity: (f.life * 1.4).clamp(0, 1),
                                child: Text(
                                  f.text,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    color: f.color,
                                    shadows: const [Shadow(blurRadius: 10, color: Colors.black54)],
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),

                          Positioned(
                            top: 8,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _LedNoteDisplay(label: _lastDetectedLabel),
                                  if (_combo >= 3) ...[
                                    const SizedBox(height: 6),
                                    AnimatedScale(
                                      scale: 1.0 + (_combo % 3 == 0 ? 0.12 : 0.0),
                                      duration: const Duration(milliseconds: 180),
                                      child: Text(
                                        '${_combo}x',
                                        style: theme.textTheme.headlineMedium?.copyWith(
                                          fontWeight: FontWeight.w900,
                                          color: _baseNeonBlue,
                                          shadows: [
                                            Shadow(color: _baseNeonBlue, blurRadius: 12),
                                            Shadow(color: _baseNeonBlue, blurRadius: 24),
                                            Shadow(color: _baseNeonBlue.withOpacity(0.85), blurRadius: 8),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            top: 10,
                            right: 4,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(_maxLives, (i) => Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Image.asset(
                                    'assets/images/life.png',
                                    fit: BoxFit.contain,
                                    opacity: AlwaysStoppedAnimation(i < _lives ? 1.0 : 0.3),
                                  ),
                                ),
                              )),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final body = Container(color: Colors.black, child: content);
    return PopScope(
      canPop: !_listening,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop && _listening) _goToScaleScreen();
      },
      child: body,
    );
  }
}

/// Row of enemy sprites for start/score screen decoration.
class _EnemySpriteStrip extends StatefulWidget {
  const _EnemySpriteStrip({required this.spriteSheet, this.height = 56});
  final ui.Image spriteSheet;
  final double height;

  @override
  State<_EnemySpriteStrip> createState() => _EnemySpriteStripState();
}

class _EnemySpriteStripState extends State<_EnemySpriteStrip> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 6));
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.height;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [0, 1, 2, 3].map((index) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                width: w,
                height: w,
                child: CustomPaint(
                  painter: _CharacterSpritePainter(
                    sheet: widget.spriteSheet,
                    characterIndex: index,
                    gameTime: _controller.value * 6,
                  ),
                  size: Size(w, w),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _GameTheme extends StatelessWidget {
  const _GameTheme({required this.child, this.spriteSheet});
  final Widget child;
  final ui.Image? spriteSheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final darkScheme = ColorScheme.dark(
      primary: primary,
      onPrimary: theme.colorScheme.onPrimary,
      surface: _gamePanelBg,
      onSurface: _gameText,
      surfaceContainerHighest: const Color(0xFF2a352e),
      outline: _gamePanelBorder,
    );
    return Material(
      type: MaterialType.transparency,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _gamePanelBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _gamePanelBorder, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          if (spriteSheet != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _EnemySpriteStrip(spriteSheet: spriteSheet!, height: 48),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Theme(
              data: theme.copyWith(
                colorScheme: darkScheme,
                dividerColor: _gamePanelBorder,
                segmentedButtonTheme: SegmentedButtonThemeData(
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: primary,
                    selectedForegroundColor: theme.colorScheme.onPrimary,
                    foregroundColor: _gameText,
                    side: BorderSide(color: _gamePanelBorder),
                  ),
                ),
              ),
              child: child,
            ),
          ),
          ],
        ),
      ),
    );
  }
}

class _GameLabel extends StatelessWidget {
  const _GameLabel(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        color: color ?? Theme.of(context).colorScheme.primary,
        letterSpacing: 1,
      ),
    );
  }
}

class _SectionAccentBar extends StatelessWidget {
  const _SectionAccentBar({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        height: 2,
        width: 36,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _ScaleNoteGrid extends StatelessWidget {
  const _ScaleNoteGrid({
    required this.notes,
    required this.selected,
    required this.onToggle,
  });
  final List<String> notes;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        const minSide = 44.0;
        final count = notes.length;
        final crossCount = count <= 6 ? count : (constraints.maxWidth / (minSide + spacing)).floor().clamp(3, 8);
        final side = ((constraints.maxWidth - spacing * (crossCount - 1)) / crossCount).clamp(minSide, 56.0);
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: notes.map((note) {
            final isSelected = selected.contains(note);
            return SizedBox(
              width: side,
              height: side,
              child: Material(
                color: isSelected ? Theme.of(context).colorScheme.primary : _gamePanelBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: isSelected ? Theme.of(context).colorScheme.primary : _gamePanelBorder,
                    width: isSelected ? 0 : 1,
                  ),
                ),
                child: InkWell(
                  onTap: () => onToggle(note),
                  borderRadius: BorderRadius.circular(10),
                  child: Center(
                    child: Text(
                      _noteLabelForDisplay(note),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: isSelected ? Colors.black : _gameTextSecondary,
                        fontSize: side * 0.35,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _LedNoteDisplay extends StatelessWidget {
  const _LedNoteDisplay({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const ledOff = Color(0xFF1B5E20);

    return SizedBox(
      width: 130,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _gameDarkBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ledOff, width: 2),
          boxShadow: [BoxShadow(color: _baseNeonGreen.withOpacity(0.15), blurRadius: 12)],
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            _noteLabelForDisplay(label),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: label == '—' ? ledOff : _baseNeonGreen,
              shadows: label == '—' ? null : [Shadow(color: _baseNeonGreen.withOpacity(0.8), blurRadius: 8)],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteShapePainter extends CustomPainter {
  _NoteShapePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final stroke = Paint()..color = color.withOpacity(0.4)..style = PaintingStyle.stroke..strokeWidth = 1.5;

    const headWidth = 14.0;
    const headHeight = 10.0;
    const stemHeight = 22.0;
    const stemWidth = 2.5;

    final headLeft = 2.0;
    final headTop = 2.0;
    final headRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(headLeft, headTop, headWidth, headHeight),
      const Radius.circular(6),
    );
    canvas.drawRRect(headRect, paint);
    canvas.drawRRect(headRect, stroke);

    final stemX = headLeft + headWidth - stemWidth / 2;
    final stemY = headTop + headHeight * 0.4;
    canvas.drawRect(Rect.fromLTWH(stemX, stemY, stemWidth, stemHeight), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints one character from the sprite sheet. Sheet is 18 columns × 12 rows.
/// Odd rows: Yellow at cols 0,3,6,9,12,15 (notes in between). Even rows: Orange,
/// Blue, Red at cols 0,1,2 then 3,4,5 etc. 1px inset to reduce bleed.
class _CharacterSpritePainter extends CustomPainter {
  _CharacterSpritePainter({
    required this.sheet,
    required this.characterIndex,
    required this.gameTime,
  });
  final ui.Image sheet;
  final int characterIndex;
  final double gameTime;

  static const _cols = 18;
  static const _rows = 12;
  static const _framesPerSecond = 10.0;
  static const _inset = 1.0;

  /// Yellow: odd rows (0,2,4,6,8,10), only yellow at cols 0,3,6,9,12,15 (never note cols 1,2,4,5,7,8...). 36 frames.
  static List<(int row, int col)> _buildYellowFrames() {
    final out = <(int, int)>[];
    for (final row in [0, 2, 4, 6, 8, 10]) {
      for (final col in [0, 3, 6, 9, 12, 15]) {
        out.add((row, col));
      }
    }
    return out;
  }

  /// Orange: even rows, cols 0,3,6,9,12,15. 36 frames.
  static List<(int row, int col)> _buildOrangeFrames() {
    final out = <(int, int)>[];
    for (final row in [1, 3, 5, 7, 9, 11]) {
      for (final col in [0, 3, 6, 9, 12, 15]) {
        out.add((row, col));
      }
    }
    return out;
  }

  /// Blue: even rows, cols 1,4,7,10,13,16. 36 frames.
  static List<(int row, int col)> _buildBlueFrames() {
    final out = <(int, int)>[];
    for (final row in [1, 3, 5, 7, 9, 11]) {
      for (final col in [1, 4, 7, 10, 13, 16]) {
        out.add((row, col));
      }
    }
    return out;
  }

  /// Red: even rows, cols 2,5,8,11,14,17. 36 frames.
  static List<(int row, int col)> _buildRedFrames() {
    final out = <(int, int)>[];
    for (final row in [1, 3, 5, 7, 9, 11]) {
      for (final col in [2, 5, 8, 11, 14, 17]) {
        out.add((row, col));
      }
    }
    return out;
  }

  static final _frameLists = [
    _buildYellowFrames(),
    _buildOrangeFrames(),
    _buildBlueFrames(),
    _buildRedFrames(),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final listIndex = characterIndex.clamp(0, 7) % 4;
    final frames = _frameLists[listIndex];
    final frameIndex = ((gameTime * _framesPerSecond).floor() % frames.length);
    final cell = frames[frameIndex];
    final frameW = sheet.width / _cols;
    final frameH = sheet.height / _rows;
    // Pixel-aligned source rect with 1px inset from right/bottom to avoid bleed
    // into adjacent cells or variable gaps between groups of 3.
    final srcRect = Rect.fromLTRB(
      cell.$2 * frameW,
      cell.$1 * frameH,
      (cell.$2 + 1) * frameW - _inset,
      (cell.$1 + 1) * frameH - _inset,
    );
    final dstRect = Offset.zero & size;
    canvas.drawImageRect(
      sheet,
      srcRect,
      dstRect,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _CharacterSpritePainter old) =>
      old.sheet != sheet ||
      old.characterIndex != characterIndex ||
      old.gameTime != gameTime;
}

class _FallingNoteWidget extends StatelessWidget {
  const _FallingNoteWidget({
    required this.note,
    required this.x,
    required this.y,
    required this.areaHeight,
    required this.isExploding,
    required this.isPowerNote,
    required this.characterIndex,
    required this.gameTime,
    this.spriteSheet,
  });

  final String note;
  final double x;
  final double y;
  final double areaHeight;
  final bool isExploding;
  final bool isPowerNote;
  final int characterIndex;
  final double gameTime;
  final ui.Image? spriteSheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const w = 80.0;
    const h = 982.0;

    final noteLabel = Text(
      _noteLabelForDisplay(note),
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: isPowerNote ? const Color(0xFFFFD54F) : Colors.red,
        shadows: [
          Shadow(
            color: isPowerNote ? Colors.amber.withOpacity(0.8) : Colors.black,
            blurRadius: 1,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );

    final body = spriteSheet != null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              noteLabel,
              const SizedBox(height: 2),
              SizedBox(
                width: 80,
                height: 80,
                child: CustomPaint(
                  painter: _CharacterSpritePainter(
                    sheet: spriteSheet!,
                    characterIndex: characterIndex,
                    gameTime: gameTime,
                  ),
                  size: const Size(80, 80),
                ),
              ),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(20, 26),
                painter: _NoteShapePainter(color: isPowerNote ? Colors.amber : cs.error),
              ),
              const SizedBox(width: 6),
              noteLabel,
            ],
          );

    return Positioned(
      left: x - w / 2,
      top: y - h / 2,
      child: AnimatedScale(
        scale: isExploding ? 2.2 : 1.0,
        duration: const Duration(milliseconds: 180),
        child: AnimatedOpacity(
          opacity: isExploding ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: w,
            height: h,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedScoreReport extends StatefulWidget {
  const _AnimatedScoreReport({
    required this.score,
    required this.accuracy,
    required this.maxCombo,
    required this.results,
    required this.message,
    required this.grade,
    required this.scoreBreakdown,
    this.spriteSheet,
  });

  final int score;
  final double accuracy;
  final int maxCombo;
  final List<_GameNoteResult> results;
  final String message;
  final String grade;
  /// [lifeBonus, intonationScore, comboBonus]
  final List<int> scoreBreakdown;
  final ui.Image? spriteSheet;

  @override
  State<_AnimatedScoreReport> createState() => _AnimatedScoreReportState();
}

class _AnimatedScoreReportState extends State<_AnimatedScoreReport> with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _barAnimation;
  bool _confettiLaunched = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 3400));
    _barAnimation = Tween<double>(begin: 0, end: widget.score.toDouble()).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.forward();
    _maybeLaunchConfetti();
  }

  void _maybeLaunchConfetti() {
    if (_confettiLaunched || widget.score < 80) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _confettiLaunched) return;
      // Small delay helps ensure overlay/context are fully ready.
      await Future<void>.delayed(const Duration(milliseconds: 140));
      if (!mounted || _confettiLaunched) return;
      _confettiLaunched = true;
      _launchBigConfetti();
    });
  }

  @override
  void didUpdateWidget(covariant _AnimatedScoreReport oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeLaunchConfetti();
  }

  void _launchBigConfetti() {
    Confetti.launch(
      context,
      options: ConfettiOptions(
        particleCount: 120,
        spread: 90,
        startVelocity: 65,
        gravity: -0.06,
        colors: [Colors.amber, Colors.pink, Colors.cyan],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingColor = Color.lerp(theme.colorScheme.primary, Colors.white, 0.22)!;

    return Container(
      decoration: BoxDecoration(
        color: _gamePanelBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gamePanelBorder, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            if (widget.spriteSheet != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _EnemySpriteStrip(spriteSheet: widget.spriteSheet!, height: 44),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      AnimatedBuilder(
                        animation: _controller,
                        builder: (_, __) => Column(
                          children: [
                            Text(
                              'FINAL SCORE',
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: headingColor,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: (_barAnimation.value / 100).clamp(0, 1),
                                minHeight: 24,
                                backgroundColor: _gamePanelBorder,
                                valueColor: AlwaysStoppedAnimation(
                                  widget.score >= 85 ? theme.colorScheme.primary : theme.colorScheme.primary.withOpacity(0.7),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${_barAnimation.value.round()} / 100  •  ${widget.grade}',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: _gameText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        widget.message,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: _gameText,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Lives ${widget.scoreBreakdown[0]} + Intonation ${widget.scoreBreakdown[1]} + Combo ${widget.scoreBreakdown[2]}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _gameTextSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          'Score = 20 per life left + how in-tune your hits were (max 40) + combo bonus (max 10)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _gameTextSecondary,
                            fontSize: 11,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _StatPill(label: 'ACCURACY', value: '${widget.accuracy.round()}%', accentColor: headingColor),
                          _StatPill(label: 'BEST COMBO', value: '${widget.maxCombo}x', accentColor: headingColor.withOpacity(0.85)),
                        ],
                      ),
                      const SizedBox(height: 24),
                      ...widget.results.map((r) => _ResultRow(result: r)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.label, required this.value, this.accentColor});
  final String label;
  final String value;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color.withOpacity(0.95),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: _gameText,
          ),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  final _GameNoteResult result;
  const _ResultRow({required this.result});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _noteLabelForDisplay(result.note),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Colors.white,
            ),
          ),
          result.hit
              ? Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.primary, size: 22)
              : const Text(
                  'MISSED',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600),
                ),
        ],
      ),
    );
  }
}