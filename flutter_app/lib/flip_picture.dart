import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'theme.dart';

const flipDuration = 0.42; // seconds for initial/close 180° flip
const flipStepDuration = 0.30; // seconds for < / > arrow step
const peekDelayMs = 70; // skim guard before subtle ~16° 3D edge-lift hint
const peekProgress = 0.19; // ~16° cosine-eased lift (180 * (0.5 - 0.5 * cos(pi * 0.19)))

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Maprisma Theme's `flip_picture.dart` (same timings and steps), without its pin button (the
/// Manager only applies themes): a theme preview that lifts slightly and rotates 180° in 3D when
/// active to reveal the theme's wallpapers, with `<` / `>` cycle buttons (including the original
/// preview `-1`). [instant]: reduced motion, every turn lands at once.
class FlipPicture extends StatefulWidget {
  const FlipPicture({
    super.key,
    required this.slug,
    required this.preview,
    required this.wallpapers,
    required this.borderRadius,
    required this.active,
    this.pageVisible = true,
    required this.delaySeconds,
    required this.fallback,
    this.badges,
    this.instant = false,
    this.onShownChanged,
  });

  final String slug;
  final String preview;
  final List<String> wallpapers;
  final double borderRadius;
  final bool active;
  final bool pageVisible;
  final double delaySeconds;

  /// What a picture that can't be read shows (the theme's colours).
  final Widget fallback;
  final Widget? badges;
  final bool instant;

  /// Called after a frame in which the shown face changed.
  final VoidCallback? onShownChanged;

  @override
  State<FlipPicture> createState() => FlipPictureState();
}

class FlipPictureState extends State<FlipPicture> with SingleTickerProviderStateMixin {
  late List<String> _wallpapers;
  String? _promoteName;
  int _delayMs = 2000;

  bool _selected = false;
  bool _interactive = false; // true once rotation or manual arrow mode is active
  bool _navSteady = false; // true once < / > stay visible across preview + wallpapers
  int _fromFace = -1; // -1 = original preview, 0..N-1 = wallpaper index
  int _toFace = 0;
  double _direction = 1.0;
  double _target = 0.0;
  double _progress = 0.0;
  (int, double)? _queued;

  Timer? _peekTimer;
  Timer? _delayTimer;
  late final Ticker _ticker;
  Duration? _lastElapsed;
  final Set<String> _prefetched = {};
  int? _reportedShown;

  int get visibleFace {
    final eased = 0.5 - 0.5 * math.cos(math.pi * _progress);
    return eased <= 0.5 ? _fromFace : _toFace;
  }

  bool get isShowingWallpaper => visibleFace >= 0;

  String? get currentWallpaperPath {
    final face = visibleFace;
    return face >= 0 && face < _wallpapers.length ? _wallpapers[face] : null;
  }

  double get currentAngleDegrees => _faceAndAngle().$2;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _wallpapers = List<String>.of(widget.wallpapers);
    _delayMs = math.max(0, (widget.delaySeconds * 1000).round());
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) setSelected(true);
      });
    }
  }

  @override
  void didUpdateWidget(FlipPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slug != widget.slug) {
      _cancelTimers();
      _stopTicker();
      _wallpapers = List<String>.of(widget.wallpapers);
      _promoteName = null;
      _selected = false;
      _interactive = false;
      _navSteady = false;
      _fromFace = -1;
      _toFace = 0;
      _direction = 1.0;
      _target = 0.0;
      _progress = 0.0;
      _queued = null;
      _prefetched.clear();
    } else if (!_sameList(oldWidget.wallpapers, widget.wallpapers)) {
      if (_fromFace == -1 && _progress <= 0.0) {
        _wallpapers = List<String>.of(widget.wallpapers);
        _promoteName = null;
      } else if (_sameSet(_wallpapers, widget.wallpapers)) {
        // Same wallpapers re-ordered after pinning: keep indices steady while open
        // and promote to front once the card closes back to preview.
        if (widget.wallpapers.isNotEmpty) {
          _promoteName = _baseName(widget.wallpapers.first);
        }
      } else {
        _wallpapers = List<String>.of(widget.wallpapers);
        if (_wallpapers.isEmpty) {
          resetFlip();
        } else {
          if (_fromFace >= _wallpapers.length) _fromFace = _wallpapers.length - 1;
          if (_toFace >= _wallpapers.length) _toFace = 0;
        }
      }
    }

    final newDelayMs = math.max(0, (widget.delaySeconds * 1000).round());
    final delayChanged = newDelayMs != _delayMs;
    _delayMs = newDelayMs;

    if (!widget.pageVisible) {
      if (_selected || _fromFace != -1 || _progress > 0.0 || _interactive) {
        resetFlip();
      }
      if (!_sameList(_wallpapers, widget.wallpapers)) {
        _wallpapers = List<String>.of(widget.wallpapers);
        _promoteName = null;
      }
      return;
    }

    if (widget.active != _selected) {
      setSelected(widget.active);
    } else if (delayChanged && _selected) {
      if (_delayMs <= 0 && _fromFace == -1) {
        _cancelTimers();
        _queued = null;
        _interactive = true;
        _navSteady = true;
        if (_progress > 0.0) _animateTo(0.0);
      }
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    _ticker.dispose();
    super.dispose();
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  void _promote(String name) {
    final idx = _wallpapers.indexWhere((p) => _baseName(p) == name);
    if (idx > 0) {
      _wallpapers = [..._wallpapers.sublist(idx), ..._wallpapers.sublist(0, idx)];
    }
  }

  void _cancelTimers() {
    _peekTimer?.cancel();
    _peekTimer = null;
    _delayTimer?.cancel();
    _delayTimer = null;
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
    _lastElapsed = null;
  }

  void _prefetchPath(String path) {
    if (!mounted || _prefetched.contains(path)) return;
    _prefetched.add(path);
    precacheImage(ResizeImage(FileImage(File(path)), width: 640), context).catchError((Object _) {});
  }

  void _prefetchAround(int index) {
    final n = _wallpapers.length;
    if (n == 0) return;
    _prefetchPath(widget.preview);
    if (index < 0) {
      _prefetchPath(_wallpapers[0]);
      if (n > 1) _prefetchPath(_wallpapers[n - 1]);
      return;
    }
    _prefetchPath(_wallpapers[index % n]);
    if (n > 1) {
      _prefetchPath(_wallpapers[(index + 1) % n]);
      _prefetchPath(_wallpapers[(index - 1) % n]);
    }
  }

  void setSelected(bool selected) {
    if (selected == _selected) {
      if (selected) _activate();
      return;
    }
    _selected = selected;
    if (selected) {
      _activate();
    } else {
      _closeToPreview();
    }
    if (mounted) setState(() {});
  }

  void _activate() {
    if (_wallpapers.isEmpty) return;
    _prefetchAround(0);
    // Reduced motion: no lift and no turn by itself, the arrows only.
    if (_delayMs <= 0 || widget.instant) {
      _cancelTimers();
      _interactive = true;
      _navSteady = true;
      if (mounted) setState(() {});
      return;
    }
    if (_interactive || _peekTimer != null || _delayTimer != null) return;
    final peekMs = math.min(peekDelayMs, _delayMs);
    final remMs = math.max(40, _delayMs - peekMs);
    if (_fromFace == -1 && _progress <= 0.0) {
      _peekTimer = Timer(Duration(milliseconds: peekMs), _onHoverPeek);
    } else if (_fromFace == -1 && _toFace >= 0) {
      _queued = null;
      if (_progress <= peekProgress + 0.02) {
        _animateTo(peekProgress);
        _delayTimer ??= Timer(Duration(milliseconds: remMs), _onDelayDone);
      } else {
        _interactive = true;
        _animateTo(1.0);
      }
    } else if (_toFace == -1) {
      _interactive = true;
      if (_progress < 0.5) {
        _queued = null;
        _animateTo(0.0);
      } else {
        _queued = (0, 1.0);
        _animateTo(1.0);
      }
    }
  }

  void _onHoverPeek() {
    _peekTimer = null;
    if (!mounted || !_selected || _wallpapers.isEmpty) return;
    _fromFace = -1;
    _toFace = 0;
    _direction = 1.0;
    _animateTo(peekProgress);
    if (_delayTimer == null) {
      final peekMs = math.min(peekDelayMs, _delayMs);
      final remMs = math.max(40, _delayMs - peekMs);
      _delayTimer = Timer(Duration(milliseconds: remMs), _onDelayDone);
    }
  }

  void _onDelayDone() {
    _delayTimer = null;
    if (!mounted || !_selected || _wallpapers.isEmpty) return;
    _interactive = true;
    _fromFace = -1;
    _toFace = 0;
    _direction = 1.0;
    _animateTo(1.0);
  }

  void _closeToPreview() {
    _interactive = false;
    _navSteady = false;
    _cancelTimers();
    _queued = null;
    if (_fromFace == -1 && _progress <= 0.0) {
      _target = 0.0;
      if (_promoteName != null) {
        _promote(_promoteName!);
        _promoteName = null;
      }
      if (mounted) setState(() {});
      return;
    }
    if (_fromFace == -1) {
      _animateTo(0.0);
    } else if (_toFace == -1) {
      _animateTo(1.0);
    } else if (_progress >= 1.0) {
      _fromFace = _toFace;
      _toFace = -1;
      _direction = -1.0;
      _progress = 0.0;
      _animateTo(1.0);
    } else if (_progress <= 0.0) {
      _toFace = -1;
      _direction = -1.0;
      _progress = 0.0;
      _animateTo(1.0);
    } else if (_progress < 0.5 && _target == 1.0) {
      _queued = (-1, -1.0);
      _animateTo(0.0);
    } else {
      _queued = (-1, -1.0);
      _animateTo(_target);
    }
  }

  void resetFlip() {
    _selected = false;
    _interactive = false;
    _navSteady = false;
    _queued = null;
    _cancelTimers();
    _stopTicker();
    _fromFace = -1;
    _toFace = 0;
    _direction = 1.0;
    _target = 0.0;
    _progress = 0.0;
    if (_promoteName != null) {
      _promote(_promoteName!);
      _promoteName = null;
    }
    if (mounted) setState(() {});
  }

  int _nextFaceInCycle(int face, int delta) {
    final n = _wallpapers.length;
    return ((face + 1 + delta) % (n + 1)) - 1;
  }

  void rotateStep(int stepDir) {
    if (_wallpapers.isEmpty || !_interactive) return;
    if (!_navSteady && !isShowingWallpaper) return;
    _navSteady = true;
    final sign = stepDir >= 0 ? 1.0 : -1.0;
    final delta = stepDir >= 0 ? 1 : -1;
    if (_progress >= 1.0) {
      final cur = _toFace;
      final nxt = _nextFaceInCycle(cur, delta);
      _prefetchAround(nxt);
      _fromFace = cur;
      _toFace = nxt;
      _direction = sign;
      _progress = 0.0;
      _animateTo(1.0);
      return;
    }
    if (_progress <= 0.0) {
      final cur = _fromFace;
      final nxt = _nextFaceInCycle(cur, delta);
      _prefetchAround(nxt);
      _fromFace = cur;
      _toFace = nxt;
      _direction = sign;
      _progress = 0.0;
      _animateTo(1.0);
      return;
    }
    if (_progress < 0.5) {
      if (_target == 1.0 && (sign > 0) != (_direction > 0)) {
        _queued = null;
        _animateTo(0.0);
        return;
      }
      if (_target == 0.0 && (sign > 0) == (_direction > 0)) {
        _queued = null;
        _animateTo(1.0);
        return;
      }
    }
    final endFace = _target == 1.0 ? _toFace : _fromFace;
    final nxt = _nextFaceInCycle(endFace, delta);
    _prefetchAround(nxt);
    _queued = (nxt, sign);
    _animateTo(_target);
  }

  void _animateTo(double target) {
    _target = target;
    if (!_ticker.isActive) {
      _lastElapsed = null;
      _ticker.start();
    }
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    final double dt;
    if (_lastElapsed == null) {
      _lastElapsed = elapsed;
      dt = 1.0 / 60.0;
    } else {
      final us = (elapsed - _lastElapsed!).inMicroseconds;
      _lastElapsed = elapsed;
      dt = us <= 0 ? 1.0 / 60.0 : math.min(0.1, us / 1000000.0);
    }
    final keepGoing = _step(dt);
    if (!keepGoing) _stopTicker();
    if (mounted) setState(() {});
  }

  bool _step(double dt) {
    if (widget.instant) dt = 1000; // reduced motion: every turn lands in one frame
    var dur = _navSteady ? flipStepDuration : flipDuration;
    if (_queued != null) dur *= 0.6;
    var stepScale = 1.0;
    if (_fromFace == -1 && _target == peekProgress) {
      final rem = math.max(0.0, peekProgress - _progress);
      stepScale = math.max(0.32, math.min(1.0, rem / 0.09)) * 1.15;
    } else if (_fromFace == -1 && _target == 0.0 && _progress <= peekProgress + 0.01) {
      stepScale = math.max(0.32, math.min(1.0, _progress / 0.09)) * 1.05;
    }

    if (_target > _progress) {
      _progress = math.min(_target, _progress + (dt / dur) * stepScale);
    } else if (_target < _progress) {
      _progress = math.max(_target, _progress - (dt / dur) * stepScale);
    }

    if (_progress == _target) {
      if (_queued != null) {
        final (nxtFace, nxtDir) = _queued!;
        _queued = null;
        final curFace = _target == 1.0 ? _toFace : _fromFace;
        if (nxtFace != curFace) {
          _prefetchAround(nxtFace);
          _fromFace = curFace;
          _toFace = nxtFace;
          _direction = nxtDir;
          _progress = 0.0;
          _target = 1.0;
          return true;
        }
      }
      if (_target == 1.0 && _toFace == -1) {
        _fromFace = -1;
        _toFace = 0;
        _direction = 1.0;
        _progress = 0.0;
        _target = 0.0;
        if (!_selected && _promoteName != null) {
          _promote(_promoteName!);
          _promoteName = null;
        }
      } else if (_target == 0.0 && _fromFace == -1) {
        if (!_selected && _promoteName != null) {
          _promote(_promoteName!);
          _promoteName = null;
        }
      }
      if (_interactive && ((_target == 1.0 && _progress >= 1.0) || (_target == 0.0 && _progress <= 0.0))) {
        _navSteady = true;
      }
    }

    return _progress != _target || _queued != null;
  }

  (int, double) _faceAndAngle() {
    final eased = 0.5 - 0.5 * math.cos(math.pi * _progress);
    if (eased <= 0.5) {
      return (_fromFace, _direction * (180.0 * eased));
    }
    return (_toFace, _direction * (180.0 * (eased - 1.0)));
  }

  Widget _faceImage(int face) {
    final path = face >= 0 && face < _wallpapers.length ? _wallpapers[face] : widget.preview;
    return Image(
      key: ValueKey('face-$path'),
      image: ResizeImage(FileImage(File(path)), width: 640),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = visibleFace;
    if (widget.onShownChanged != null && shown != _reportedShown) {
      _reportedShown = shown;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onShownChanged?.call();
      });
    }
    final (face, localDeg) = _faceAndAngle();
    final isIdleFront = _fromFace == -1 && _progress <= 0.0;
    final double badgesOpacity;
    if (face == -1) {
      final fade = math.max(0.0, (localDeg.abs() - 20.0) / 28.0);
      badgesOpacity = math.max(0.0, 1.0 - fade);
    } else {
      badgesOpacity = 0.0;
    }
    final faceOpacity = (1.0 - localDeg.abs() / 55.0).clamp(0.0, 1.0);
    final showNav = _wallpapers.isNotEmpty && ((_interactive && _navSteady) || face >= 0);
    final navOpacity = (_interactive && _navSteady) ? 1.0 : faceOpacity;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        Widget cardFace;
        if (isIdleFront || w <= 0 || h <= 0) {
          cardFace = ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: SizedBox.expand(child: _faceImage(-1)),
          );
        } else {
          final d = math.max(w * 1.8, 260.0);
          final rad = localDeg * math.pi / 180.0;
          final scale = (d - (w / 2.0) * math.sin(rad).abs()) / d;
          final shade = 0.38 * math.sin(rad).abs();
          final rimAlpha = 0.42 * math.sin(math.min(math.pi * 0.5, rad.abs() * 2.4));
          final transform = Matrix4.identity()
            ..setEntry(3, 2, -1.0 / d)
            ..rotateY(rad)
            ..multiply(Matrix4.diagonal3Values(scale, scale, 1.0));
          cardFace = Transform(
            alignment: Alignment.center,
            transform: transform,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _faceImage(face),
                  if (shade > 0.005)
                    IgnorePointer(
                      child: ColoredBox(color: Colors.black.withValues(alpha: shade)),
                    ),
                  if (rimAlpha > 0.02 && localDeg.abs() < 84.0)
                    IgnorePointer(
                      child: Align(
                        alignment: localDeg > 0 ? Alignment.centerLeft : Alignment.centerRight,
                        child: Container(
                          width: math.min(2.0, w),
                          height: h,
                          color: Colors.white.withValues(alpha: rimAlpha),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            cardFace,
            if (widget.badges != null)
              Positioned(
                left: 6,
                right: 40,
                bottom: 6,
                child: IgnorePointer(
                  ignoring: badgesOpacity <= 0.01,
                  child: Opacity(opacity: badgesOpacity, child: widget.badges),
                ),
              ),
            if (showNav && navOpacity > 0.01) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Opacity(
                  opacity: navOpacity,
                  child: _FlipOverlayButton(
                    key: ValueKey('flip-prev-${widget.slug}'),
                    icon: Icons.chevron_left,
                    tooltip: _nextFaceInCycle(face, -1) == -1 ? tr("Preview") : tr("Previous wallpaper"),
                    onTap: () => rotateStep(-1),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: navOpacity,
                  child: _FlipOverlayButton(
                    key: ValueKey('flip-next-${widget.slug}'),
                    icon: Icons.chevron_right,
                    tooltip: _nextFaceInCycle(face, 1) == -1 ? tr("Preview") : tr("Next wallpaper"),
                    onTap: () => rotateStep(1),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _FlipOverlayButton extends StatefulWidget {
  const _FlipOverlayButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_FlipOverlayButton> createState() => _FlipOverlayButtonState();
}

class _FlipOverlayButtonState extends State<_FlipOverlayButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = cornerSizes(context).control;
    final Color bg;
    final Color fg;
    if (_hover) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else {
      bg = Colors.black.withValues(alpha: .6);
      fg = Colors.white;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip,
          child: Container(
            margin: const EdgeInsets.all(5),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(r)),
            child: Icon(widget.icon, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}
