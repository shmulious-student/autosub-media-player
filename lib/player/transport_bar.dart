// TransportBar (docs/design/COMPONENTS.md §TransportBar, RTL.md §2/§8).
//
// Player controls, ENTIRELY pinned LTR — time flows left→right; play/skip never
// mirror, and ←/→ are always seek-back/forward regardless of locale. Hover-reveal
// with a 2.5s auto-hide; gradient scrim behind the chrome.
//
// The bar also carries the two things a viewer needs mid-scene and should never
// leave fullscreen for:
//   - the precision sync stepper (±50ms), because noticing a drift and fixing it
//     are the same moment, and
//   - the runway band on the scrubber, which shades how far into the film
//     subtitles actually exist, so a title still being prepared reads as "ready to
//     here" instead of "broken after this point".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../ui/bidi.dart';
import '../ui/tokens.dart';

const List<double> _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

String _fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

class TransportBar extends StatefulWidget {
  const TransportBar({
    super.key,
    required this.player,
    required this.subtitlesAvailable,
    required this.subtitlesOn,
    required this.onToggleSubtitles,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.subtitleDelayMs = 0,
    this.onNudgeSubtitleDelay,
    this.onResetSubtitleDelay,
    this.readyThrough,
    this.dualSubtitlesAvailable = false,
    this.dualSubtitlesOn = false,
    this.onToggleDualSubtitles,
  });

  final Player player;
  final bool subtitlesAvailable;
  final bool subtitlesOn;
  final VoidCallback onToggleSubtitles;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;

  /// Current subtitle offset in milliseconds (positive = subtitles come later).
  final int subtitleDelayMs;

  /// Nudge the offset by a signed delta, or null to hide the stepper entirely
  /// (previews and tests that pass no player state).
  final void Function(int deltaMs)? onNudgeSubtitleDelay;
  final VoidCallback? onResetSubtitleDelay;

  /// How far into the media subtitles are prepared, or null when the whole track
  /// is already there (or there is none at all) — nothing to shade either way.
  final Duration? readyThrough;

  final bool dualSubtitlesAvailable;
  final bool dualSubtitlesOn;
  final VoidCallback? onToggleDualSubtitles;

  @override
  State<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends State<TransportBar> {
  bool _visible = true;
  Timer? _hideTimer;
  double? _scrubValue; // non-null while dragging the seek bar

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _reveal() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && widget.player.state.playing) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _reveal(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Click-through play/pause on the video surface.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              widget.player.playOrPause();
              _reveal();
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: AppMotion.resolve(context, AppMotion.base),
              child: IgnorePointer(
                ignoring: !_visible,
                child: _bar(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context) {
    // The whole transport is an LTR island (RTL.md §2 — never mirrors).
    return LtrIsland(
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.x5, AppSpacing.x8, AppSpacing.x5, AppSpacing.x4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xD9000000)],
          ),
        ),
        child: StreamBuilder<Duration>(
          stream: widget.player.stream.position,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? widget.player.state.position;
            final dur = widget.player.state.duration;
            final maxMs =
                dur.inMilliseconds == 0 ? 1.0 : dur.inMilliseconds.toDouble();
            final sliderValue = _scrubValue ??
                pos.inMilliseconds.toDouble().clamp(0, maxMs);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _TimeLabel(_fmt(Duration(
                        milliseconds:
                            (_scrubValue ?? pos.inMilliseconds.toDouble())
                                .round()))),
                    const SizedBox(width: AppSpacing.x3),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 4,
                          activeTrackColor: AppColors.amber,
                          inactiveTrackColor: AppColors.neutral700,
                          thumbColor: AppColors.amber,
                          overlayColor: AppColors.amber.withValues(alpha: 0.2),
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          trackShape: _RunwayTrackShape(
                            _readyFraction(dur),
                          ),
                        ),
                        child: Slider(
                          min: 0,
                          max: maxMs,
                          value: sliderValue.toDouble().clamp(0, maxMs),
                          onChangeStart: (v) =>
                              setState(() => _scrubValue = v),
                          onChanged: (v) => setState(() => _scrubValue = v),
                          onChangeEnd: (v) {
                            widget.player
                                .seek(Duration(milliseconds: v.round()));
                            setState(() => _scrubValue = null);
                            _reveal();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    _TimeLabel(_fmt(dur)),
                  ],
                ),
                const SizedBox(height: AppSpacing.x1),
                Row(
                  children: [
                    StreamBuilder<bool>(
                      stream: widget.player.stream.playing,
                      builder: (context, snap) {
                        final playing =
                            snap.data ?? widget.player.state.playing;
                        return _Btn(
                          icon: playing ? Icons.pause : Icons.play_arrow,
                          size: 32,
                          tooltip: 'Play / pause (Space)',
                          onTap: () {
                            widget.player.playOrPause();
                            _reveal();
                          },
                        );
                      },
                    ),
                    _Btn(
                      icon: Icons.replay_10,
                      tooltip: 'Back 10s (←)',
                      onTap: () => _seekBy(const Duration(seconds: -10)),
                    ),
                    _Btn(
                      icon: Icons.forward_10,
                      tooltip: 'Forward 10s (→)',
                      onTap: () => _seekBy(const Duration(seconds: 10)),
                    ),
                    const Spacer(),
                    if (widget.onNudgeSubtitleDelay != null &&
                        widget.subtitlesAvailable)
                      _SyncStepper(
                        delayMs: widget.subtitleDelayMs,
                        onNudge: (delta) {
                          widget.onNudgeSubtitleDelay!(delta);
                          _reveal();
                        },
                        onReset: widget.onResetSubtitleDelay == null
                            ? null
                            : () {
                                widget.onResetSubtitleDelay!();
                                _reveal();
                              },
                      ),
                    _SpeedButton(player: widget.player, onChanged: _reveal),
                    if (widget.dualSubtitlesAvailable)
                      _Btn(
                        icon: Icons.subtitles,
                        tooltip: 'Dual-language subtitles (D)',
                        color: widget.dualSubtitlesOn
                            ? AppColors.amber
                            : AppColors.neutral0,
                        onTap: widget.onToggleDualSubtitles == null
                            ? null
                            : () {
                                widget.onToggleDualSubtitles!();
                                _reveal();
                              },
                      ),
                    _Btn(
                      icon: widget.subtitlesOn
                          ? Icons.closed_caption
                          : Icons.closed_caption_off,
                      tooltip: widget.subtitlesAvailable
                          ? 'Subtitles (S)'
                          : 'No subtitles for this title',
                      color: widget.subtitlesOn
                          ? AppColors.amber
                          : AppColors.neutral0,
                      onTap: widget.subtitlesAvailable
                          ? () {
                              widget.onToggleSubtitles();
                              _reveal();
                            }
                          : null,
                    ),
                    _Btn(
                      icon: widget.isFullscreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                      tooltip: 'Fullscreen (F)',
                      onTap: () {
                        widget.onToggleFullscreen();
                        _reveal();
                      },
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// How much of the film has prepared subtitles, 0..1. Zero (draw nothing) when
  /// the duration is unknown or the track is complete.
  double _readyFraction(Duration duration) {
    final ready = widget.readyThrough;
    if (ready == null || duration <= Duration.zero) return 0;
    return (ready.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  void _seekBy(Duration delta) {
    final target = widget.player.state.position + delta;
    final dur = widget.player.state.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > dur ? dur : target);
    widget.player.seek(clamped);
    _reveal();
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: AppType.monoTime.copyWith(color: AppColors.neutral0),
      );
}

class _Btn extends StatelessWidget {
  const _Btn({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 24,
    this.color = AppColors.neutral0,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final btn = IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: size),
      color: color,
      disabledColor: AppColors.neutral500,
      splashRadius: 22,
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.player, required this.onChanged});
  final Player player;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.rate,
      builder: (context, snap) {
        final rate = snap.data ?? player.state.rate;
        return Tooltip(
          message: 'Playback speed',
          child: TextButton(
            onPressed: () {
              final idx = _speeds.indexWhere((s) => (s - rate).abs() < 0.01);
              final next = _speeds[(idx + 1) % _speeds.length];
              player.setRate(next);
              onChanged();
            },
            child: Text(
              '${rate.toStringAsFixed(rate == rate.roundToDouble() ? 1 : 2)}×',
              style: AppType.monoTime.copyWith(color: AppColors.neutral0),
            ),
          ),
        );
      },
    );
  }
}

/// Slider track that shades the "subtitles exist up to here" runway over the
/// not-yet-played part of the film.
///
/// This is deliberately a track shape rather than a widget stacked behind the
/// slider: only the shape knows the real track rect, and a runway band that is a
/// few pixels off the scrubber it describes is worse than no band at all.
class _RunwayTrackShape extends RoundedRectSliderTrackShape {
  const _RunwayTrackShape(this.readyFraction);

  /// 0..1 of the media duration; 0 means "nothing to shade".
  final double readyFraction;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    if (readyFraction <= 0 || readyFraction >= 1) return;

    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    // Only the stretch that is both prepared and not yet played needs shading —
    // the played part is already the active amber.
    final readyRight = rect.left + rect.width * readyFraction;
    final left = thumbCenter.dx.clamp(rect.left, rect.right);
    if (readyRight <= left) return;

    final band = Rect.fromLTRB(left, rect.top, readyRight, rect.bottom);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(band, Radius.circular(rect.height / 2)),
      Paint()..color = AppColors.amber.withValues(alpha: 0.38),
    );
  }
}

/// The ±50ms precision stepper: "Sync − 0ms +", with a click on the readout
/// resetting to zero.
class _SyncStepper extends StatelessWidget {
  const _SyncStepper({
    required this.delayMs,
    required this.onNudge,
    this.onReset,
  });

  /// One press. Small enough to be safe to hold down, large enough to hear.
  static const int stepMs = 50;

  final int delayMs;
  final void Function(int deltaMs) onNudge;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final nudged = delayMs != 0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: const BorderRadius.all(AppRadius.full),
        border: Border.all(
          color: nudged
              ? AppColors.amber.withValues(alpha: 0.55)
              : AppColors.neutral700,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepBtn(
            icon: Icons.remove,
            tooltip: 'Subtitles earlier 50ms (Z)',
            onTap: () => onNudge(-stepMs),
          ),
          Tooltip(
            message: nudged ? 'Reset subtitle sync (/)' : 'Subtitle sync',
            child: GestureDetector(
              onTap: nudged ? onReset : null,
              child: SizedBox(
                width: 64,
                child: Text(
                  nudged
                      ? '${delayMs > 0 ? '+' : ''}${delayMs}ms'
                      : '0ms',
                  textAlign: TextAlign.center,
                  style: AppType.monoTime.copyWith(
                    color: nudged ? AppColors.amber : AppColors.neutral0,
                  ),
                ),
              ),
            ),
          ),
          _StepBtn(
            icon: Icons.add,
            tooltip: 'Subtitles later 50ms (X)',
            onTap: () => onNudge(stepMs),
          ),
        ],
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 16),
          color: AppColors.neutral0,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          splashRadius: 14,
        ),
      );
}
