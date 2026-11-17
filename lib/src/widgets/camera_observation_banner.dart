import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/services/camera_observation_service.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

/// Status strip for the opt-in camera observation feature.
///
/// The mapping from observation state to text lives here so the chat page does
/// not carry privacy-sensitive wording inline. Unknown/idle states collapse.
class CameraObservationBanner extends StatelessWidget {
  const CameraObservationBanner({
    super.key,
    required this.state,
    required this.onClose,
  });

  final CameraObservationState state;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = switch (state.status) {
      'starting' || 'requestingPermission' => strings.cameraObservationStarting,
      'observing' =>
        state.faceDetected
            ? strings.cameraObservationDetected
            : strings.cameraObservationSearching,
      'permissionDenied' => strings.cameraObservationDenied,
      'unsupported' => strings.cameraObservationUnsupported,
      'error' => strings.cameraObservationFailed,
      'stopped'
          when state.reason == 'background' ||
              state.reason == 'permission_granted_tap_to_start' =>
        strings.cameraObservationRestart,
      _ => null,
    };
    if (label == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: theme.colorScheme.secondaryContainer,
        shape: AppShapes.field,
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(
              Icons.videocam_outlined,
              size: 18,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              tooltip: strings.cameraObservationClose,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ],
        ),
      ),
    );
  }
}
