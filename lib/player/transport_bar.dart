// TransportBar (docs/design/COMPONENTS.md §TransportBar, RTL.md §2/§8).
//
// Player controls, ENTIRELY pinned LTR — time flows left→right; play/skip never
// mirror, and ←/→ are always seek-back/forward regardless of locale. Hover-reveal
// with a 2.5s auto-hide; gradient scrim behind the chrome.

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
  });

  final Player player;
  final bool subtitlesAvailable;
  final bool subtitlesOn;
  final VoidCallback onToggleSubtitles;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;

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
                    _SpeedButton(player: widget.player, onChanged: _reveal),
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
