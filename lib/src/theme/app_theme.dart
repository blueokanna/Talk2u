import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:talk2u/src/settings/ui_preferences.dart';
import 'package:talk2u/src/theme/app_motion.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

export 'package:talk2u/src/theme/app_motion.dart'
    show AppMotion, FluidPageTransitionsBuilder;
export 'package:talk2u/src/theme/app_shapes.dart' show AppShapes;

/// Page transition backed by the Material 3 Expressive shared-axis motion.
///
/// Kept as a named type because the theme and `motion_policy_test.dart` both
/// refer to it; the behaviour lives in [FluidPageTransitionsBuilder].
class MotionPageTransitionsBuilder extends FluidPageTransitionsBuilder {
  const MotionPageTransitionsBuilder();
}

abstract final class AppTheme {
  static ThemeData build(Brightness brightness, AppColorTheme colorTheme) {
    // `content` keeps the seed hue (the settings page shows the seed as a
    // swatch, so a rotated primary would contradict the label) while still
    // generating the full Material 3 role set. The expressive part of this app
    // is the motion and shape language; the palette only has to stay honest.
    final scheme = ColorScheme.fromSeed(
      seedColor: colorTheme.seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.content,
    );
    final base = Typography.material2021(platform: TargetPlatform.android);
    final textTheme = (brightness == Brightness.dark ? base.white : base.black)
        .apply(
          fontFamily: 'Google Sans',
          fontFamilyFallback: const [
            'HarmonyOS Sans SC',
            'Noto Sans CJK SC',
            'Noto Sans SC',
            'Noto Sans',
            'sans-serif',
          ],
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );
    final outline = OutlineInputBorder(
      borderRadius: AppShapes.cornersMedium,
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      fontFamily: 'Google Sans',
      fontFamilyFallback: const [
        'HarmonyOS Sans SC',
        'Noto Sans CJK SC',
        'Noto Sans SC',
        'Noto Sans',
        'sans-serif',
      ],
      // Transparent on purpose: `AuroraBackdrop` sits behind the navigator and
      // paints the tinted field, so an opaque scaffold would hide it. Card,
      // dialog and sheet surfaces stay opaque, so content contrast is unchanged.
      scaffoldBackgroundColor: Colors.transparent,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      // Material 3 Expressive motion is the app-wide default; `AppMotionPolicy`
      // collapses every duration to zero when the user asks for reduced motion.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: MotionPageTransitionsBuilder(),
          TargetPlatform.iOS: MotionPageTransitionsBuilder(),
          TargetPlatform.macOS: MotionPageTransitionsBuilder(),
          TargetPlatform.windows: MotionPageTransitionsBuilder(),
          TargetPlatform.linux: MotionPageTransitionsBuilder(),
        },
      ),
      // The 2024 progress-indicator and slider appearances replace the 2023
      // ones. The flag is the only supported opt-in until Flutter flips its
      // default, so the deprecation is acknowledged here rather than scattered
      // across call sites.
      // ignore: deprecated_member_use
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
      // ignore: deprecated_member_use
      sliderTheme: const SliderThemeData(year2023: false),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurface),
        // Transparent app bars cannot infer the status-bar icon brightness from
        // their own colour, so a light page would keep white icons over white
        // content. Pin the overlay to the scheme brightness instead.
        systemOverlayStyle: scheme.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarIconBrightness: Brightness.light,
              )
            : SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarIconBrightness: Brightness.dark,
              ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        shape: AppShapes.surface,
      ),
      dialogTheme: DialogThemeData(
        clipBehavior: Clip.antiAlias,
        shape: AppShapes.surface,
        backgroundColor: scheme.surfaceContainerHigh,
        elevation: 3,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        clipBehavior: Clip.antiAlias,
        shape: AppShapes.sheet,
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        dragHandleColor: scheme.onSurfaceVariant,
      ),
      drawerTheme: DrawerThemeData(
        shape: AppShapes.drawer,
        backgroundColor: scheme.surfaceContainerLow,
        elevation: 1,
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: AppShapes.overlay,
        color: scheme.surfaceContainer,
        elevation: 3,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: const WidgetStatePropertyAll(AppShapes.overlay),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
          elevation: const WidgetStatePropertyAll(3),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: AppShapes.pill,
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.secondaryContainer,
        checkmarkColor: scheme.onSecondaryContainer,
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle: textTheme.labelLarge,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: AppShapes.surface,
        collapsedShape: AppShapes.surface,
        backgroundColor: scheme.surfaceContainerLow,
        collapsedBackgroundColor: scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(shape: const WidgetStatePropertyAll(AppShapes.pill)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: outline.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: outline.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: AppShapes.pill,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: AppShapes.pill,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: AppShapes.pill),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: AppShapes.fab,
        elevation: 1,
        focusElevation: 1,
        hoverElevation: 2,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        shape: AppShapes.overlay,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: AppMotion.emphasis,
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: AppShapes.cornersSmall,
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(cursorColor: scheme.primary),
    );
  }
}
