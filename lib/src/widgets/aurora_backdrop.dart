import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:talk2u/src/rendering/aurora_engine.dart';

/// A slow, theme-tinted light field behind the whole application.
///
/// The field is rendered **once** into a `ui.Image` per theme/size signature and
/// then blitted with a small translation on every ambient frame. That is the
/// difference between "an animated gradient" and "a renderer": the original
/// painter rebuilt three radial-gradient shaders per frame and filled the whole
/// screen with them, which is fill-rate the phone GPU needs for the Live2D
/// avatar. A cached image blit costs one texture sample per pixel and no shader
/// construction.
///
/// The image is rasterised at 55 % of the logical size. A soft, out-of-focus
/// gradient carries no high-frequency detail, so the downscale is invisible and
/// cuts the pixel work by roughly 3×; the `FilterQuality.low` blit stretches it
/// back without ringing.
///
/// Motion comes from [AuroraEngine]'s single clock, at 30 notifications per
/// second. The painter only reads the clock inside its own layer, so a page
/// rebuild never touches the field, and the field never rebuilds a page.
class AuroraBackdrop extends StatefulWidget {
  const AuroraBackdrop({
    super.key,
    required this.child,
    this.veilOpacity = 0.90,
  });

  final Widget child;

  /// Opacity of the surface veil painted over the field. Higher keeps text
  /// contrast higher and the field less visible.
  final double veilOpacity;

  /// Fraction of logical pixels used for the field raster. Values above 0.75
  /// buy nothing visible and cost fill rate.
  static const double rasterScale = 0.55;

  /// Pause before a new theme is rasterised. Theme changes animate for ~400 ms;
  /// without this the field would rasterise every animation frame.
  static const Duration rasterDebounce = Duration(milliseconds: 180);

  @override
  State<AuroraBackdrop> createState() => _AuroraBackdropState();
}

class _AuroraBackdropState extends State<AuroraBackdrop> {
  ui.Image? _field;
  _FieldSignature? _imageSignature;
  _FieldSignature? _requested;
  Timer? _debounce;
  bool _rendering = false;
  bool _pending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleField();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field?.dispose();
    _field = null;
    super.dispose();
  }

  void _scheduleField() {
    final scheme = Theme.of(context).colorScheme;
    final signature = _FieldSignature(
      size: MediaQuery.sizeOf(context),
      primary: scheme.primary.toARGB32(),
      secondary: scheme.secondary.toARGB32(),
      tertiary: scheme.tertiary.toARGB32(),
      surface: scheme.surface.toARGB32(),
      dark: scheme.brightness == Brightness.dark,
    );
    _requested = signature;
    if (signature == _imageSignature && _field != null) return;
    _debounce?.cancel();
    _debounce = Timer(AuroraBackdrop.rasterDebounce, _generateField);
  }

  Future<void> _generateField() async {
    if (!mounted) return;
    final requested = _requested;
    if (requested == null || requested == _imageSignature) return;
    if (_rendering) {
      _pending = true;
      return;
    }
    _rendering = true;
    final image = await _rasterise(requested);
    _rendering = false;
    if (!mounted) {
      image?.dispose();
      return;
    }
    if (requested != _requested) {
      // The theme moved while the field was rendering; that render is already
      // stale, so drop it and let the debounce settle on the new colours.
      image?.dispose();
      _pending = false;
      return;
    }
    final previous = _field;
    setState(() {
      _field = image;
      _imageSignature = image == null ? null : requested;
    });
    if (previous != null) _retire(previous);
    if (_pending) {
      _pending = false;
      _scheduleField();
    }
  }

  /// Disposes after the frame that could still reference the old image.
  void _retire(ui.Image image) {
    SchedulerBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  Future<ui.Image?> _rasterise(_FieldSignature signature) async {
    final size = signature.size;
    if (!size.isFinite || size.isEmpty) return null;
    final width = (size.width * AuroraBackdrop.rasterScale).round().clamp(
      64,
      1600,
    );
    final height = (size.height * AuroraBackdrop.rasterScale).round().clamp(
      64,
      1600,
    );
    final recorder = ui.PictureRecorder();
    ui.Picture? picture;
    try {
      final canvas = Canvas(recorder);
      final surface = Color(signature.surface);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = surface,
      );
      final shortest = math.min(width, height).toDouble();
      final paint = Paint()..isAntiAlias = true;
      final intensity = signature.dark ? 0.55 : 0.38;

      void blob(Offset center, double radius, Color color, double alpha) {
        final rect = Rect.fromCircle(center: center, radius: radius);
        paint.shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha * intensity),
            color.withValues(alpha: 0),
          ],
        ).createShader(rect);
        canvas.drawCircle(center, radius, paint);
      }

      blob(
        Offset(width * 0.25, height * 0.22),
        shortest * 0.55,
        Color(signature.primary),
        0.55,
      );
      blob(
        Offset(width * 0.78, height * 0.30),
        shortest * 0.45,
        Color(signature.tertiary),
        0.45,
      );
      blob(
        Offset(width * 0.55, height * 0.82),
        shortest * 0.60,
        Color(signature.secondary),
        0.40,
      );
      picture = recorder.endRecording();
      return await picture.toImage(width, height);
    } on Object {
      // A raster failure must not take down the app shell; the painter falls
      // back to direct gradients. If the recording never ended, close it so the
      // recorder's buffers are released.
      if (picture == null) {
        try {
          recorder.endRecording().dispose();
        } on Object {
          // Nothing left to release.
        }
      }
      return null;
    } finally {
      picture?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final clock = AuroraEngine.maybeOf(context);
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            willChange: true,
            painter: _AuroraPainter(
              clock: clock,
              image: _field,
              primary: scheme.primary,
              secondary: scheme.secondary,
              tertiary: scheme.tertiary,
              surface: scheme.surface,
              dark: scheme.brightness == Brightness.dark,
              veilOpacity: widget.veilOpacity,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// Whether the current theme has settled enough to rasterise, and for which
/// theme. Value equality matters: an unchanged theme must not restart the work.
@immutable
class _FieldSignature {
  const _FieldSignature({
    required this.size,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.surface,
    required this.dark,
  });

  final Size size;
  final int primary;
  final int secondary;
  final int tertiary;
  final int surface;
  final bool dark;

  @override
  bool operator ==(Object other) =>
      other is _FieldSignature &&
      other.size == size &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.tertiary == tertiary &&
      other.surface == surface &&
      other.dark == dark;

  @override
  int get hashCode =>
      Object.hash(size, primary, secondary, tertiary, surface, dark);
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.clock,
    required this.image,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.surface,
    required this.dark,
    required this.veilOpacity,
  }) : super(repaint: clock);

  final AuroraClock? clock;
  final ui.Image? image;
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Color surface;
  final bool dark;
  final double veilOpacity;

  double get _phase => clock?.phase ?? 0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.low;
    final field = image;
    if (field == null) {
      _paintGradients(canvas, size);
    } else {
      // The raster is 8 % larger than the viewport on each axis so the drift
      // never exposes an edge.
      final phase = _phase;
      final driftX = math.sin(phase) * size.width * 0.015;
      final driftY = math.cos(phase * 0.8) * size.height * 0.012;
      final dst = Rect.fromLTWH(
        -size.width * 0.04 + driftX,
        -size.height * 0.03 + driftY,
        size.width * 1.08,
        size.height * 1.08,
      );
      canvas.drawImageRect(
        field,
        Rect.fromLTWH(0, 0, field.width.toDouble(), field.height.toDouble()),
        dst,
        paint,
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = surface.withValues(alpha: veilOpacity),
    );
  }

  /// Used until the first raster arrives, and if rasterisation is unavailable
  /// (a headless test engine, for example).
  void _paintGradients(Canvas canvas, Size size) {
    // Paint the surface first so this path is opaque. A page uses the backdrop
    // as its background; a transparent fallback would let the previous route
    // show through while the first raster is being prepared.
    canvas.drawRect(Offset.zero & size, Paint()..color = surface);
    final phase = _phase;
    final shortest = math.min(size.width, size.height);
    final intensity = dark ? 0.55 : 0.38;
    final paint = Paint()..isAntiAlias = true;
    void blob(Offset center, double radius, Color color, double alpha) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      paint.shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha * intensity),
          color.withValues(alpha: 0),
        ],
      ).createShader(rect);
      canvas.drawCircle(center, radius, paint);
    }

    final driftX = math.sin(phase) * size.width * 0.02;
    final driftY = math.cos(phase * 0.8) * size.height * 0.02;
    blob(
      Offset(size.width * 0.25 + driftX, size.height * 0.22 + driftY),
      shortest * 0.55,
      primary,
      0.55,
    );
    blob(
      Offset(size.width * 0.78 - driftX, size.height * 0.30),
      shortest * 0.45,
      tertiary,
      0.45,
    );
    blob(
      Offset(size.width * 0.55, size.height * 0.82 - driftY),
      shortest * 0.60,
      secondary,
      0.40,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.clock != clock ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary ||
      oldDelegate.tertiary != tertiary ||
      oldDelegate.surface != surface ||
      oldDelegate.dark != dark ||
      oldDelegate.veilOpacity != veilOpacity;
}
