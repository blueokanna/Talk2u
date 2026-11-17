import 'package:flutter/material.dart';

/// The Material 3 shape scale, as the only source of corner geometry.
///
/// The numeric tokens are the published Material 3 shape scale:
///
/// | token | radius |
/// | --- | --- |
/// | extra small | 4 |
/// | small | 8 |
/// | medium | 12 |
/// | large | 16 |
/// | extra large | 28 |
/// | full | stadium |
///
/// Surfaces that carry content use [RoundedSuperellipseBorder] — the
/// continuous-curvature "squircle" Material 3 Expressive uses for large
/// containers. At the same radius it reads softer than a circular arc, and it
/// removes the visible corner discontinuity a plain [RoundedRectangleBorder]
/// shows on cards and dialogs.
///
/// Nothing in `lib/` may create a corner radius inline. A widget picks a named
/// role from this class, which is what keeps a card, a dialog and a sheet from
/// drifting into three different geometries.
abstract final class AppShapes {
  // ------------------------------------------------------------------- tokens

  static const double none = 0;
  static const double extraSmall = 4;
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double extraLarge = 28;

  static const Radius radiusExtraSmall = Radius.circular(extraSmall);
  static const Radius radiusSmall = Radius.circular(small);
  static const Radius radiusMedium = Radius.circular(medium);
  static const Radius radiusLarge = Radius.circular(large);
  static const Radius radiusExtraLarge = Radius.circular(extraLarge);

  static const BorderRadius cornersExtraSmall = BorderRadius.all(
    radiusExtraSmall,
  );
  static const BorderRadius cornersSmall = BorderRadius.all(radiusSmall);
  static const BorderRadius cornersMedium = BorderRadius.all(radiusMedium);
  static const BorderRadius cornersLarge = BorderRadius.all(radiusLarge);
  static const BorderRadius cornersExtraLarge = BorderRadius.all(
    radiusExtraLarge,
  );

  static const BorderRadius cornersTopExtraLarge = BorderRadius.vertical(
    top: radiusExtraLarge,
  );
  static const BorderRadius cornersBottomExtraLarge = BorderRadius.vertical(
    bottom: radiusExtraLarge,
  );
  static const BorderRadius cornersLeadingExtraLarge = BorderRadius.horizontal(
    right: radiusExtraLarge,
  );
  static const BorderRadius cornersTrailingExtraLarge = BorderRadius.horizontal(
    left: radiusExtraLarge,
  );

  // ---------------------------------------------------------- semantic roles

  /// Large content container: cards, dialogs, empty-state panels.
  ///
  /// Material 3 Expressive keeps large containers at the extra-large radius;
  /// a 28 dp superellipse is the shape the reference apps show for exactly this
  /// role.
  static const OutlinedBorder surface = RoundedSuperellipseBorder(
    borderRadius: cornersExtraLarge,
  );

  /// Overlay container: menus, popup menus, snackbars.
  ///
  /// The baseline menu radius is extra small. A 4 dp superellipse is visually
  /// indistinguishable from a square corner, so the expressive menu keeps the
  /// same silhouette at [small]; the shape is still one of the Material 3 scale
  /// tokens rather than an arbitrary number.
  static const OutlinedBorder overlay = RoundedSuperellipseBorder(
    borderRadius: cornersSmall,
  );

  /// Text field and inline editor container.
  static const OutlinedBorder field = RoundedSuperellipseBorder(
    borderRadius: cornersMedium,
  );

  /// Bottom sheet: only the edge that touches content is curved.
  static const OutlinedBorder sheet = RoundedSuperellipseBorder(
    borderRadius: cornersTopExtraLarge,
  );

  /// Navigation drawer: the edge that faces the content is curved.
  static const OutlinedBorder drawer = RoundedSuperellipseBorder(
    borderRadius: cornersLeadingExtraLarge,
  );

  /// Floating action button. Material 3 uses the large token for this role.
  static const OutlinedBorder fab = RoundedSuperellipseBorder(
    borderRadius: cornersLarge,
  );

  /// Interactive pill: buttons, chips, switches, segmented controls.
  static const OutlinedBorder pill = StadiumBorder();

  /// Small label riding on a larger surface: a "thinking" badge, a tag.
  static const OutlinedBorder badge = RoundedSuperellipseBorder(
    borderRadius: cornersSmall,
  );

  /// A transcript bubble whose tail sits on the sender's side.
  ///
  /// The three "body" corners use the extra-large radius; the corner closest to
  /// the avatar collapses to the small token, which is what produces the tail
  /// without a second painted shape.
  static BorderRadius bubbleRadius({required bool mine}) => BorderRadius.only(
    topLeft: radiusExtraLarge,
    topRight: radiusExtraLarge,
    bottomLeft: mine ? radiusExtraLarge : radiusSmall,
    bottomRight: mine ? radiusSmall : radiusExtraLarge,
  );

  static OutlinedBorder bubble({required bool mine}) =>
      RoundedSuperellipseBorder(borderRadius: bubbleRadius(mine: mine));

  /// Shape decoration for a non-Material surface that still needs a Material 3
  /// silhouette (a painted background behind text).
  static ShapeDecoration decoration({
    required Color color,
    required OutlinedBorder shape,
    BorderSide? side,
  }) => ShapeDecoration(
    color: color,
    shape: side == null ? shape : shape.copyWith(side: side),
  );
}
