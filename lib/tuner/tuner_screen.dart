import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/note_detector_service.dart';

class TunerScreen extends StatefulWidget {
  const TunerScreen({super.key});

  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

class _TunerScreenState extends State<TunerScreen> with WidgetsBindingObserver {
  // Violin range and stability thresholds.
  static const double _violinMinHz = 150.0;
  static const double _violinMaxHz = 1800.0;
  // Broader range for manual / non auto-detect mode:
  // covers 5‑string bass low B (~31 Hz) up to very high violin / whistle notes.
  static const double _manualMinHz = 30.0;
  static const double _manualMaxHz = 4000.0;

  NoteDetectorSession? _session;
  StreamSubscription<NoteDetectionEvent>? _eventSub;
  bool _listening = false;
  bool _starting = false;
  String? _error;

  double? _freqHz;
  double? _cents;
  String? _noteLabel;
  double _confidence = 0;

  String? _targetNote;
  /// When true, auto-detect which violin string is being tuned (closest of G3/D4/A4/E5).
  bool _autoDetect = true;
  /// When set, we're judging against this target (auto-detected or user-selected); null = free mode.
  String? _effectiveTarget;

  /// String locking — prevents rapid switching between strings on harmonics/transitions.
  String? _lockedString;
  String? _candidateString;
  int _candidateCount = 0;

  /// When true-ish, we keep the needle centered after a string switch but
  /// suppress the "green / in tune" state so users don't get misled by the
  /// first few frames of pitch settling.
  int _greenSuppressedUntilMs = 0;
  int _greenStableNearCount = 0;

  /// Violin open strings (standard tuning).
  static const _violinStrings = <String>['G3', 'D4', 'A4', 'E5'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_stop());
    }
  }

  Future<void> _start() async {
    if (_listening || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      final minHz = _autoDetect ? _violinMinHz : _manualMinHz;
      final maxHz = _autoDetect ? _violinMaxHz : _manualMaxHz;

      final options = NoteDetectorOptions(
        minRms: 550.0,
        minProbability: 0.62,
        minHz: minHz,
        maxHz: maxHz,
        stabilityWindow: 4,
        minStableProbability: 0.82,
        maxJitterCents: 22.0,
        holdLastGoodMs: 1450,
        minEventIntervalMs: 50,
        emitUnpitchedEvents: true,
        continuousMode: true,
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
    } on TimeoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Tuner timed out. Try a real device.';
        _starting = false;
        _listening = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not start tuner: $e';
        _starting = false;
        _listening = false;
      });
    }
  }

  Future<void> _stop() async {
    if (!_listening && !_starting) return;
    await _eventSub?.cancel();
    _eventSub = null;
    await _session?.dispose();
    _session = null;
    if (!mounted) return;
    setState(() {
      _listening = false;
      _starting = false;
    });
  }

  void _onNoteEvent(NoteDetectionEvent event) {
    if (!mounted) return;

    if (!event.pitched) {
      _confidence = event.probability;
      _freqHz = null;
      _cents = null;
      _noteLabel = null;
      _effectiveTarget = null;
      _lockedString = null;
      _candidateString = null;
      _candidateCount = 0;
      _greenSuppressedUntilMs = 0;
      setState(() {});
      return;
    }

    final rawHz = event.frequencyHzRaw > 0 ? event.frequencyHzRaw : event.frequencyHz;
    final smoothedHz = event.frequencyHz > 0 ? event.frequencyHz : rawHz;
    // Use raw pitch for lock decisions so we react immediately to the actual
    // detected note. The smoothed value lags during attacks and causes the
    // "searching" / slow lock that makes users think the instrument needs tuning.
    final lockHz = rawHz;
    // Use smoothed for display to avoid needle jitter.
    final displayHz = smoothedHz;

    _freqHz = displayHz;
    _noteLabel = event.noteLabel;
    _confidence = event.probability;

    // Choose effective target and display cents by mode.
    String? effectiveTarget;
    double displayCents;
    if (_autoDetect) {
      // Lock decisions use raw pitch so we react immediately (like manual mode).
      // Only use vote counting for adjacent-string transitions to prevent bounce.
      const initialCaptureCents = 55.0;
      const holdLockCents = 50.0;
      const instantSwitchWrongCents = 120.0;  // clearly wrong string
      const instantSwitchCandidateCents = 45.0;
      const adjacentSwitchVotes = 2;  // G↔D, D↔A, A↔E need 2 frames

      final detected = _closestViolinString(lockHz);
      final detectedAbsCents = detected == null
          ? double.infinity
          : _centsFromTarget(lockHz, detected).abs();

      if (_lockedString == null) {
        if (detected != null && detectedAbsCents <= initialCaptureCents) {
          _lockedString = detected;
        }
        _candidateString = null;
        _candidateCount = 0;
      } else if (detected == null) {
        _candidateString = null;
        _candidateCount = 0;
      } else {
        final lockedAbsCents = _centsFromTarget(lockHz, _lockedString!).abs();

        if (detected == _lockedString || lockedAbsCents <= holdLockCents) {
          _candidateString = null;
          _candidateCount = 0;
        } else {
          // Instant switch when we're clearly on the wrong string and the new
          // one is well-centered (e.g. playing E5 while locked on A4).
          final instantSwitch = lockedAbsCents > instantSwitchWrongCents &&
              detectedAbsCents < instantSwitchCandidateCents;

          if (instantSwitch) {
            _lockedString = detected;
            _candidateString = null;
            _candidateCount = 0;
          } else {
            // Adjacent strings: require 2 consecutive frames to reduce bounce.
            if (_candidateString == detected) {
              _candidateCount++;
            } else {
              _candidateString = detected;
              _candidateCount = 1;
            }
            if (_candidateCount >= adjacentSwitchVotes) {
              _lockedString = detected;
              _candidateString = null;
              _candidateCount = 0;
            }
          }
        }
      }

      effectiveTarget = _lockedString;
      displayCents = effectiveTarget != null
          ? _centsFromTarget(displayHz, effectiveTarget)
          : (event.centsFromNearest ?? 0);
      if (effectiveTarget != null && event.stable && displayCents.abs() < 3.0) {
        displayCents = 0;
      }
    } else if (_targetNote != null) {
      effectiveTarget = _targetNote;
      displayCents = _centsFromTarget(displayHz, _targetNote!);
      if (event.stable && displayCents.abs() < 3.0) {
        displayCents = 0;
      }
    } else {
      effectiveTarget = null;
      displayCents = event.centsFromNearest ?? 0;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final previousTarget = _effectiveTarget;
    final previousCents = _cents;

    final targetChanged = previousTarget != effectiveTarget &&
        effectiveTarget != null; // only care when we have a target

    _effectiveTarget = effectiveTarget;

    if (targetChanged) {
      // Centre the needle immediately when the string target changes, but
      // suppress green for a short settling period.
      _greenSuppressedUntilMs = nowMs + 1200;
      _greenStableNearCount = 0;
    }

    bool greenSuppressed = _greenSuppressedUntilMs > nowMs;
    if (greenSuppressed) {
      // Adaptive release: don't end suppression just because the timer
      // elapsed; wait until the *smoothed* pitch has actually converged.
      //
      // This specifically prevents the "jump away then crawl back" that
      // you saw in the console logs.
      if (event.stable && displayCents.abs() < 12.0) {
        _greenStableNearCount++;
        if (_greenStableNearCount >= 3) {
          _greenSuppressedUntilMs = nowMs;
          greenSuppressed = false;
        }
      } else {
        _greenStableNearCount = 0;
      }
    }

    final shouldHoldZero = !greenSuppressed &&
        effectiveTarget != null &&
        event.stable &&
        previousTarget == effectiveTarget &&
        previousCents != null &&
        previousCents.abs() <= 0.5 &&
        displayCents.abs() < 6.0;

    if (greenSuppressed) {
      _cents = 0.0;
    } else if (shouldHoldZero) {
      _cents = 0.0;
    } else if (effectiveTarget != null && event.stable && displayCents.abs() < 3.0) {
      _cents = 0.0;
    } else {
      _cents = displayCents;
    }

    setState(() {});
  }

  /// Frequency in Hz for a note label (e.g. A4 = 440). Only supports violin strings for now.
  static double? _noteLabelToFreqHz(String label) {
    const midiByLabel = <String, int>{
      'G3': 55,
      'D4': 62,
      'A4': 69,
      'E5': 76,
    };
    final midi = midiByLabel[label];
    if (midi == null) return null;
    return 440.0 * math.pow(2.0, (midi - 69) / 12.0);
  }

  /// Cents from target: positive = sharp, negative = flat.
  static double _centsFromTarget(double pitchHz, String targetLabel) {
    final targetFreq = _noteLabelToFreqHz(targetLabel);
    if (targetFreq == null || targetFreq <= 0) return 0;
    return 1200.0 * (math.log(pitchHz / targetFreq) / math.ln2);
  }

  /// Closest violin string to the given pitch (by minimum absolute cents).
  String? _closestViolinString(double pitchHz) {
    String? best;
    double bestAbsCents = double.infinity;
    for (final s in _violinStrings) {
      final c = _centsFromTarget(pitchHz, s);
      final absCents = c.abs();
      if (absCents < bestAbsCents) {
        bestAbsCents = absCents;
        best = s;
      }
    }
    return best;
  }

  /// Light text that stays visible on the gradient background.
  static const Color _onGradient = Color(0xFFE8ECF4);
  static const Color _onGradientMuted = Color(0xFFB8C4D4);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final cents = _cents;
    final absCents = cents?.abs();
    final greenSuppressed = _greenSuppressedUntilMs >
        DateTime.now().millisecondsSinceEpoch;
    final settling = greenSuppressed && absCents != null && absCents < 5;
    final inTune = absCents != null && absCents < 5 && !greenSuppressed;
    // In free mode (no target) show "Good" when in tune, not "In tune".
    final hasTarget = _effectiveTarget != null;
    final status = cents == null
        ? 'Listen'
        : (inTune
            ? (hasTarget ? 'In tune' : 'Good')
            : (greenSuppressed && absCents != null && absCents < 5
                ? 'Settling'
                : cents < 0
                    ? 'Flat'
                    : 'Sharp'));
    final displayNote = _effectiveTarget ?? _noteLabel ?? '—';

    final bg = settling
        ? const Color(0xFF0D1222)
        : (inTune
            ? const Color(0xFF0E3B2B)
            : (cents == null
                ? const Color(0xFF0D1222)
                : (cents < 0
                    ? const Color(0xFF2A1020)
                    : const Color(0xFF101B35))));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            bg,
            cs.surface.withOpacity(0.08),
          ],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      "Play a note. I'll tell you what it is and whether it's flat or sharp.",
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _onGradientMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _GlowPill(
                    label: _listening ? 'LIVE' : 'OFF',
                    color: _listening
                        ? const Color(0xFF3EE6A8)
                        : const Color(0xFF8892A6),
                    textColor: _onGradient,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Auto-detect string',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: _onGradient,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: _autoDetect,
                    onChanged: (value) {
                      setState(() {
                        _autoDetect = value;

                        if (value) {
                          // Switching to auto mode → clear manual target
                          _targetNote = null;
                        } else {
                          // Switching to manual mode → clear auto-detected target
                          _effectiveTarget = null;
                          _cents = null;
                        }
                        // Reset string lock on any mode switch.
                        _lockedString = null;
                        _candidateString = null;
                        _candidateCount = 0;
                        _greenSuppressedUntilMs = 0;
                      });
                    },
                    activeColor: const Color(0xFF3EE6A8),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _ViolinTargetsRow(
                targetNote: _targetNote,
                autoDetectedNote: _autoDetect ? _effectiveTarget : null,
                onTap: (label) {
                  setState(() {
                    _targetNote = _targetNote == label ? null : label;
                  });
                },
                onTuner: _onGradient,
                onTunerMuted: _onGradientMuted,
              ),
              const SizedBox(height: 14),

              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _FunBackground(
                          intensity: (_confidence).clamp(0, 1),
                          tint: inTune
                              ? const Color(0xFF3EE6A8)
                              : (cents == null
                                  ? const Color(0xFF7C8BFF)
                                  : (cents < 0
                                      ? const Color(0xFFFF5AA5)
                                      : const Color(0xFF7C8BFF))),
                        ),
                      ),
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _NoteBadge(
                                        note: displayNote,
                                        subtitle: status,
                                        inTune: inTune,
                                        confidence: _confidence,
                                        targetNote: _effectiveTarget,
                                      ),
                                      const SizedBox(height: 18),
                                      _TunerGauge(
                                        cents: cents,
                                        inTune: inTune,
                                      ),
                                      const SizedBox(height: 14),
                                      if (cents != null)
                                        Text(
                                          '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)} cents',
                                          style: theme.textTheme.titleLarge
                                              ?.copyWith(
                                            color: Colors.white
                                                .withOpacity(0.92),
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.2,
                                          ),
                                        ),
                                      if (cents != null)
                                        const SizedBox(height: 6),
                                      Text(
                                        _freqHz == null
                                            ? ''
                                            : '${_freqHz!.toStringAsFixed(1)} Hz',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          color: Colors.white
                                              .withOpacity(0.85),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (_error != null) ...[
                                        const SizedBox(height: 10),
                                        Text(
                                          _error!,
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                            color: Colors.amber.shade200,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _starting
                          ? null
                          : _listening
                              ? _stop
                              : _start,
                      icon: Icon(
                          _listening ? Icons.stop_rounded : Icons.mic_rounded),
                      label: Text(_listening ? 'Stop' : 'Start'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: _listening
                            ? const Color(0xFF2A3548)
                            : cs.primary,
                        foregroundColor: _listening
                            ? _onGradient
                            : cs.onPrimary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _freqHz = null;
                          _cents = null;
                          _noteLabel = null;
                          _confidence = 0;
                          _error = null;
                          _targetNote = null;
                          _effectiveTarget = null;
                        });
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Reset'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: _onGradient,
                        side: BorderSide(
                            color: _onGradient.withOpacity(0.5)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlowPill extends StatelessWidget {
  const _GlowPill({
    required this.label,
    required this.color,
    Color? textColor,
  }) : textColor = textColor ?? Colors.white;
  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.55), width: 1),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
      ),
    );
  }
}

// FIX #6: added targetNote param so the badge can display it
class _NoteBadge extends StatelessWidget {
  const _NoteBadge({
    required this.note,
    required this.subtitle,
    required this.inTune,
    required this.confidence,
    required this.targetNote,
  });

  final String note;
  final String subtitle;
  final bool inTune;
  final double confidence;
  final String? targetNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ring = inTune ? const Color(0xFF3EE6A8) : Colors.white.withOpacity(0.25);
    final fill = Colors.black.withOpacity(0.25);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: ring, width: 2),
        boxShadow: [
          BoxShadow(
            color: ring.withOpacity(0.35),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            note,
            style: theme.textTheme.displayMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: Colors.white.withOpacity(0.85),
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          // FIX #6: show the active target string beneath the status
          if (targetNote != null) ...[
            const SizedBox(height: 4),
            Text(
              'Target: $targetNote',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withOpacity(0.60),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ],
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: confidence.clamp(0, 1),
              minHeight: 6,
              backgroundColor: Colors.white.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation<Color>(
                inTune ? const Color(0xFF3EE6A8) : const Color(0xFF7C8BFF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TunerGauge extends StatelessWidget {
  const _TunerGauge({required this.cents, required this.inTune});
  final double? cents;
  final bool inTune;

  @override
  Widget build(BuildContext context) {
    final clamped = (cents ?? 0).clamp(-50.0, 50.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = w * 0.58;
        return SizedBox(
          width: w,
          height: h,
          child: CustomPaint(
            painter: _GaugePainter(
              cents: cents == null ? null : clamped,
              inTune: inTune,
            ),
          ),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.cents, required this.inTune});
  final double? cents;
  final bool inTune;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.88);
    final radius = size.width * 0.48;
    const start = math.pi + math.pi * 0.12;
    const sweep = math.pi - math.pi * 0.24;
    final scale = radius / 93.0;

    // Curved scale arc
    final arcPaint = Paint()
      ..color = Colors.white.withOpacity(0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (10 * scale).clamp(4.0, 16.0)
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, start, sweep, false, arcPaint);

    // Tick marks and scale numbers (-50, -20, 0, 20, 50)
    final tickPaint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..strokeWidth = (2 * scale).clamp(1.0, 4.0)
      ..strokeCap = StrokeCap.round;
    final tickInset = 18 * scale;
    final tickOut = 2 * scale;

    const scaleValues = [-50, -20, 0, 20, 50];
    for (int i = -50; i <= 50; i += 10) {
      final t = (i + 50) / 100.0;
      final ang = start + sweep * t;
      final inner = Offset(
        center.dx + math.cos(ang) * (radius - tickInset),
        center.dy + math.sin(ang) * (radius - tickInset),
      );
      final outer = Offset(
        center.dx + math.cos(ang) * (radius - tickOut),
        center.dy + math.sin(ang) * (radius - tickOut),
      );
      canvas.drawLine(inner, outer, tickPaint);
    }

    // Scale labels
    final fontSize = (12 * scale).clamp(10.0, 24.0);
    void textPainter(String text, double x, double y) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.white.withOpacity(0.9),
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y));
    }
    final labelRadius = radius + 14 * scale;
    for (final i in scaleValues) {
      final t = (i + 50) / 100.0;
      final ang = start + sweep * t;
      final x = center.dx + math.cos(ang) * labelRadius;
      final y = center.dy + math.sin(ang) * labelRadius;
      textPainter('$i', x, y);
    }

    // In-tune marker: small inverted triangle at center (0)
    const zeroAng = start + sweep * 0.5;
    final triOff = 4 * scale;
    final triW = 8 * scale;
    final triH = 6 * scale;
    final triTip = Offset(
      center.dx + math.cos(zeroAng) * (radius - triOff),
      center.dy + math.sin(zeroAng) * (radius - triOff),
    );
    final triPath = Path()
      ..moveTo(triTip.dx - triW, triTip.dy + triH)
      ..lineTo(triTip.dx, triTip.dy - triH)
      ..lineTo(triTip.dx + triW, triTip.dy + triH)
      ..close();
    canvas.drawPath(
      triPath,
      Paint()
        ..color = const Color(0xFF7C8BFF).withOpacity(0.9)
        ..style = PaintingStyle.fill,
    );

    // Needle: single line from pivot to tip, no circle, no extra line
    final pivotR = 6 * scale;
    if (cents != null) {
      final t = ((cents! + 50) / 100.0).clamp(0.0, 1.0);
      final ang = start + sweep * t;
      final needleColor =
          inTune ? const Color(0xFF3EE6A8) : const Color(0xFFE53935); // red when off, green in tune
      final needlePaint = Paint()
        ..color = needleColor
        ..strokeWidth = (5 * scale).clamp(3.0, 10.0)
        ..strokeCap = StrokeCap.round;

      final tipInset = 24 * scale;
      final tip = Offset(
        center.dx + math.cos(ang) * (radius - tipInset),
        center.dy + math.sin(ang) * (radius - tipInset),
      );
      canvas.drawLine(center, tip, needlePaint);
      canvas.drawCircle(center, pivotR, Paint()..color = needleColor);
    } else {
      canvas.drawCircle(
        center,
        pivotR,
        Paint()..color = Colors.white.withOpacity(0.35),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return cents != oldDelegate.cents || inTune != oldDelegate.inTune;
  }
}

class _FunBackground extends StatefulWidget {
  const _FunBackground({required this.intensity, required this.tint});
  final double intensity;
  final Color tint;

  @override
  State<_FunBackground> createState() => _FunBackgroundState();
}

class _FunBackgroundState extends State<_FunBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final a = widget.tint.withOpacity(0.20 + 0.25 * widget.intensity);
        final b = widget.tint.withOpacity(0.06 + 0.14 * widget.intensity);
        return CustomPaint(
          painter: _BlobPainter(t: t, a: a, b: b),
        );
      },
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter({required this.t, required this.a, required this.b});
  final double t;
  final Color a;
  final Color b;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withOpacity(0.15),
    );

    void blob(double x, double y, double r, Color c) {
      canvas.drawCircle(Offset(x, y), r, Paint()..color = c);
    }

    final w = size.width;
    final h = size.height;
    blob(w * (0.25 + 0.08 * math.sin(t * 2 * math.pi)), h * 0.25, w * 0.45, a);
    blob(w * (0.85 - 0.06 * math.cos(t * 2 * math.pi)), h * 0.60, w * 0.35, b);
    blob(w * 0.15, h * (0.75 + 0.05 * math.sin(t * 2 * math.pi)), w * 0.28, b);
  }

  @override
  bool shouldRepaint(covariant _BlobPainter oldDelegate) {
    return t != oldDelegate.t || a != oldDelegate.a || b != oldDelegate.b;
  }
}

/// Purple used for selected string in violin targets row.
const Color _selectedStringPurple = Color(0xFF8B5CF6);

class _ViolinTargetsRow extends StatelessWidget {
  const _ViolinTargetsRow({
    required this.onTap,
    required this.targetNote,
    required this.onTuner,
    required this.onTunerMuted,
    this.autoDetectedNote,
  });
  final void Function(String label) onTap;
  final String? targetNote;
  final Color onTuner;
  final Color onTunerMuted;
  /// When auto-detect is on, the string currently detected (closest).
  final String? autoDetectedNote;

  static const _targets = <String>['G3', 'D4', 'A4', 'E5'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Violin strings',
          style: theme.textTheme.labelLarge?.copyWith(
            color: onTunerMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final t in _targets) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onTap(t),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t == targetNote
                        ? _selectedStringPurple
                        : onTuner,
                    backgroundColor: t == targetNote
                        ? _selectedStringPurple.withOpacity(0.22)
                        : (t == autoDetectedNote
                            ? const Color(0xFF3EE6A8).withOpacity(0.12)
                            : Colors.transparent),
                    side: BorderSide(
                      color: t == targetNote
                          ? _selectedStringPurple
                          : (t == autoDetectedNote
                              ? const Color(0xFF3EE6A8).withOpacity(0.6)
                              : onTuner.withOpacity(0.22)),
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    t,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                      color: t == targetNote
                          ? _selectedStringPurple
                          : onTuner,
                    ),
                  ),
                ),
              ),
              if (t != _targets.last) const SizedBox(width: 10),
            ],
          ],
        ),
      ],
    );
  }
}