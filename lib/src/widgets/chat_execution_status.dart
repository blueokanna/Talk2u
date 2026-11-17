import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/services/call_session.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/widgets/fluid_switcher.dart';

/// One-line execution route summary: LLM backend, TTS backend, duplex mode.
///
/// The route is evidence, not decoration: an item only claims hardware when the
/// native report proved it with a completed turn. When the route changes, the
/// strip swaps through [FluidSwitcher] so a call starting or a backend becoming
/// verified reads as a transition rather than a layout jump.
class ChatExecutionStatus extends StatelessWidget {
  const ChatExecutionStatus({
    super.key,
    required this.chatState,
    required this.session,
  });

  final ChatState chatState;
  final CallSession? session;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        OfflineLlmService.instance,
        MossTtsService.instance,
      ]),
      builder: (context, _) {
        final llm = OfflineLlmService.instance;
        final moss = MossTtsService.instance;
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final items = <({IconData icon, String label, Color color})>[];

        if (chatState.usesAndroidOfflineProvider) {
          items.add((
            icon: llm.hardwareAccelerationVerified
                ? Icons.memory
                : Icons.pending_outlined,
            label: strings.llmRoute(llm.accelerationDescription),
            color: llm.hardwareAccelerationVerified
                ? colors.primary
                : colors.onSurfaceVariant,
          ));
        }
        if (moss.ready) {
          items.add((
            icon: moss.hardwareAccelerationVerified
                ? Icons.graphic_eq
                : Icons.pending_outlined,
            label: strings.ttsRoute(moss.accelerationLabel),
            color: moss.hardwareAccelerationVerified
                ? colors.primary
                : colors.onSurfaceVariant,
          ));
        }
        final activeSession = session;
        if (activeSession != null && activeSession.active) {
          final fullDuplex = activeSession.acousticBargeIn;
          items.add((
            icon: fullDuplex ? Icons.record_voice_over : Icons.hearing,
            label: fullDuplex ? strings.callFullDuplex : strings.callHalfDuplex,
            color: fullDuplex ? colors.primary : colors.onSurfaceVariant,
          ));
        }
        final signature = items
            .map((item) => '${item.icon.codePoint}:${item.label}')
            .join('|');
        return FluidSwitcher(
          axis: Axis.vertical,
          child: items.isEmpty
              ? const SizedBox.shrink(key: ValueKey('route-empty'))
              : Material(
                  key: ValueKey('route-$signature'),
                  color: colors.surfaceContainerLow,
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final item in items)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Icon(item.icon, size: 16, color: item.color),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      item.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelMedium
                                          ?.copyWith(color: item.color),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
