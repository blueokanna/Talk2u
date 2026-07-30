import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/services/accelerator_telemetry_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:webview_cef/webview_cef.dart';
import 'package:webview_windows/webview_windows.dart' as windows_webview;

abstract final class Live2dModelPaths {
  static const bundledMao =
      'asset:///model/Live2d/mao/runtime/mao_pro.model3.json';
}

Future<void>? _desktopCefInitialization;

Future<void> _initializeDesktopCef() async {
  final existing = _desktopCefInitialization;
  if (existing != null) return existing;
  final initialization = WebviewManager().initialize(userAgent: 'Talk2U/1.0');
  _desktopCefInitialization = initialization;
  try {
    await initialization;
  } catch (_) {
    if (identical(_desktopCefInitialization, initialization)) {
      _desktopCefInitialization = null;
    }
    rethrow;
  }
}

class Live2dAvatar extends StatefulWidget {
  final String modelPath;

  const Live2dAvatar({super.key, required this.modelPath});

  @override
  State<Live2dAvatar> createState() => _Live2dAvatarState();
}

class _Live2dAvatarState extends State<Live2dAvatar> {
  MethodChannel? _channel;
  WebViewController? _desktopController;
  windows_webview.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessageSubscription;
  double _lastAmplitude = -1;
  bool _wasSpeaking = false;
  int _lastCueRevision = -1;
  String? _error;
  Map<String, dynamic>? _readyDetails;
  bool _diagnosticsLoading = false;
  bool _recoverableError = false;
  bool _restartScheduled = false;
  int _viewGeneration = 0;
  int _automaticRestarts = 0;

  @override
  void initState() {
    super.initState();
    OfflineSpeechService.instance.addListener(_syncMouth);
    if (_usesDesktopRenderer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_usesWindowsWebView) {
          unawaited(_initializeWindowsRenderer());
        } else {
          unawaited(_initializeDesktopRenderer());
        }
      });
    }
  }

  bool get _usesWindowsWebView =>
      defaultTargetPlatform == TargetPlatform.windows;
  bool get _usesDesktopCef => defaultTargetPlatform == TargetPlatform.linux;
  bool get _usesDesktopRenderer => _usesWindowsWebView || _usesDesktopCef;

  void _syncMouth() {
    _pushSpeechState();
  }

  void _pushSpeechState({bool force = false}) {
    final speech = OfflineSpeechService.instance;
    if (force || speech.speaking != _wasSpeaking) {
      _invoke('setSpeaking', {'value': speech.speaking});
      if (!speech.speaking) {
        _invoke('setMouth', {'value': 0.0});
        _invoke('resetExpression', const {});
        _lastCueRevision = -1;
      }
    }
    if (speech.speaking &&
        (force || speech.animationCueRevision != _lastCueRevision)) {
      _invoke('perform', {'cue': speech.animationCue});
      _lastCueRevision = speech.animationCueRevision;
    }
    _wasSpeaking = speech.speaking;
    final value = speech.amplitude;
    if (!force && (value - _lastAmplitude).abs() < 0.025) return;
    _lastAmplitude = value;
    _invoke('setMouth', {'value': value});
  }

  void _invoke(String method, Map<String, Object> arguments) {
    _channel?.invokeMethod<void>(method, arguments).catchError((_) {});
    final script = switch (method) {
      'setMouth' => 'Talk2UAvatar.setMouth(${jsonEncode(arguments['value'])})',
      'setSpeaking' =>
        'Talk2UAvatar.setSpeaking(${jsonEncode(arguments['value'])})',
      'perform' => 'Talk2UAvatar.perform(${jsonEncode(arguments['cue'])})',
      'resetExpression' => 'Talk2UAvatar.resetExpression()',
      _ => null,
    };
    if (script == null) return;
    final desktop = _desktopController;
    if (desktop != null && desktop.value) {
      desktop.executeJavaScript(script).catchError((_) {});
    }
    final windows = _windowsController;
    if (windows != null && windows.value.isInitialized) {
      windows.executeScript(script).catchError((_) {});
    }
  }

  String _desktopAssetPath(String relativePath) {
    final separator = Platform.pathSeparator;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final normalizedRelativePath = relativePath.replaceAll('/', separator);
    return '$executableDirectory${separator}data${separator}flutter_assets'
        '$separator$normalizedRelativePath';
  }

  String _desktopModelUri() {
    const prefix = 'asset:///';
    if (widget.modelPath.startsWith(prefix)) {
      return Uri.file(
        _desktopAssetPath(widget.modelPath.substring(prefix.length)),
      ).toString();
    }
    final parsed = Uri.tryParse(widget.modelPath);
    if (parsed != null && parsed.hasScheme) return parsed.toString();
    return Uri.file(widget.modelPath).toString();
  }

  String _desktopPageUri() => Uri.file(
    _desktopAssetPath('assets/live2d/index.html'),
  ).replace(queryParameters: {'model': _desktopModelUri()}).toString();

  Future<void> _initializeWindowsRenderer() async {
    final generation = _viewGeneration;
    final controller = windows_webview.WebviewController();
    try {
      await controller.initialize();
      if (!mounted || generation != _viewGeneration) {
        controller.dispose();
        return;
      }
      await controller.setBackgroundColor(Colors.transparent);
      await controller.addVirtualHostNameMapping(
        'talk2u.assets',
        _desktopAssetPath(''),
        windows_webview.WebviewHostResourceAccessKind.allow,
      );
      final modelMapping = _windowsModelMapping();
      final modelFolder = modelMapping.folder;
      if (modelFolder != null) {
        await controller.addVirtualHostNameMapping(
          'talk2u.model',
          modelFolder,
          windows_webview.WebviewHostResourceAccessKind.allow,
        );
      }
      await controller.addScriptToExecuteOnDocumentCreated('''
        window.Talk2uNative = {
          postMessage: message => window.chrome.webview.postMessage(message),
          getRendererCapabilities: () => JSON.stringify({
            viewHardwareAccelerated: true,
            applicationHardwareAccelerationRequested: true,
            webViewVersion: navigator.userAgent,
            nativeProbe: {
              preferredNativeBackend: 'WebView2 GPU compositor'
            }
          })
        };
      ''');
      await _windowsMessageSubscription?.cancel();
      _windowsMessageSubscription = controller.webMessage.listen((message) {
        if (message is String) {
          _handleStatus(message);
        } else if (message != null) {
          _handleStatus(jsonEncode(message));
        }
      });
      _windowsController = controller;
      final page = Uri.https('talk2u.assets', '/assets/live2d/index.html', {
        'model': modelMapping.url,
      }).toString();
      await controller.loadUrl(page);
      if (!mounted || generation != _viewGeneration) {
        await _windowsMessageSubscription?.cancel();
        _windowsMessageSubscription = null;
        controller.dispose();
        return;
      }
      setState(() {});
    } catch (error) {
      await _windowsMessageSubscription?.cancel();
      _windowsMessageSubscription = null;
      if (identical(_windowsController, controller)) {
        _windowsController = null;
      }
      controller.dispose();
      if (!mounted || generation != _viewGeneration) return;
      final strings = AppLocalizations.of(context);
      setState(() {
        _error = strings.live2dRuntimeFailed('$error');
        _recoverableError = true;
      });
    }
  }

  ({String url, String? folder}) _windowsModelMapping() {
    const assetPrefix = 'asset:///';
    if (widget.modelPath.startsWith(assetPrefix)) {
      return (
        url: Uri.https(
          'talk2u.assets',
          '/${widget.modelPath.substring(assetPrefix.length)}',
        ).toString(),
        folder: null,
      );
    }

    final parsed = Uri.tryParse(widget.modelPath);
    if (parsed != null && parsed.hasScheme && parsed.scheme != 'file') {
      return (url: parsed.toString(), folder: null);
    }
    final modelFile = File(
      parsed?.scheme == 'file' ? parsed!.toFilePath() : widget.modelPath,
    ).absolute;
    var root = modelFile.parent;
    var foundImportRoot = false;
    while (root.parent.path != root.path) {
      if (p.basename(root.path).toLowerCase() == 'live2d_models') {
        foundImportRoot = true;
        break;
      }
      root = root.parent;
    }
    if (!foundImportRoot) root = modelFile.parent;
    final relative = p
        .relative(modelFile.path, from: root.path)
        .replaceAll('\\', '/');
    return (
      url: Uri.https('talk2u.model', '/$relative').toString(),
      folder: root.path,
    );
  }

  Future<void> _initializeDesktopRenderer() async {
    final generation = _viewGeneration;
    try {
      await _initializeDesktopCef();
      if (!mounted || generation != _viewGeneration) return;
      final controller = WebviewManager().createWebView(
        loading: const Center(child: CircularProgressIndicator()),
        injectUserScripts: InjectUserScripts(),
      );
      _desktopController = controller;
      controller.setWebviewListener(
        WebviewEventsListener(
          onConsoleMessage: (level, message, source, line) {
            if (level >= 4 && mounted && _error == null) {
              final strings = AppLocalizations.of(context);
              setState(() => _error = strings.live2dScriptFailed(message));
            }
          },
        ),
      );
      await controller.initialize(_desktopPageUri());
      if (!mounted || generation != _viewGeneration) {
        controller.dispose();
        return;
      }
      await controller.setJavaScriptChannels({
        JavascriptChannel(
          name: 'Talk2uNative',
          onMessageReceived: (message) => _handleStatus(message.message),
        ),
      });
      await controller.executeJavaScript('window.flushTalk2uStatus?.()');
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted || generation != _viewGeneration) return;
      final strings = AppLocalizations.of(context);
      setState(() {
        _error = strings.live2dRuntimeFailed('$error');
        _recoverableError = true;
      });
    }
  }

  void _onCreated(int viewId) {
    final channel = MethodChannel('talk2u/live2d_$viewId');
    channel.setMethodCallHandler((call) async {
      if (call.method != 'status' || call.arguments is! String) return;
      _handleStatus(call.arguments as String);
    });
    _channel = channel;
    if (mounted) {
      setState(() {
        _error = null;
        _readyDetails = null;
        _recoverableError = false;
      });
    }
    channel.invokeMethod<String>('getStatus').then((status) {
      if (status != null) _handleStatus(status);
    }, onError: (_) {});
  }

  void _handleStatus(String message) {
    try {
      final status = jsonDecode(message) as Map<String, dynamic>;
      if (!mounted) return;
      final strings = AppLocalizations.of(context);
      setState(() {
        _error = status['type'] == 'error'
            ? status['message'] as String? ?? strings.live2dLoadFailed
            : null;
        _recoverableError =
            status['type'] == 'error' && status['recoverable'] == true;
        if (status['type'] == 'ready') _readyDetails = status;
      });
      if (status['type'] == 'ready') _pushSpeechState(force: true);
      if (_recoverableError && _automaticRestarts < 1) {
        _automaticRestarts++;
        _scheduleRendererRestart();
      }
    } catch (_) {
      if (mounted) {
        final strings = AppLocalizations.of(context);
        setState(() => _error = strings.live2dInvalidStatus);
      }
    }
  }

  void _scheduleRendererRestart() {
    if (_restartScheduled) return;
    _restartScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      _restartScheduled = false;
      if (mounted && _recoverableError) _restartRenderer();
    });
  }

  void _restartRenderer() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _desktopController?.dispose();
    _desktopController = null;
    unawaited(_windowsMessageSubscription?.cancel());
    _windowsMessageSubscription = null;
    _windowsController?.dispose();
    _windowsController = null;
    setState(() {
      _viewGeneration++;
      _error = null;
      _readyDetails = null;
      _recoverableError = false;
      _lastAmplitude = -1;
      _lastCueRevision = -1;
    });
    if (_usesWindowsWebView) {
      unawaited(_initializeWindowsRenderer());
    } else if (_usesDesktopCef) {
      unawaited(_initializeDesktopRenderer());
    }
  }

  Map<String, dynamic> _decodeDiagnostics(
    String raw,
    AppLocalizations strings,
  ) {
    dynamic value = jsonDecode(raw);
    if (value is String) value = jsonDecode(value);
    if (value is! Map) throw FormatException(strings.diagnosticsInvalidJson);
    return Map<String, dynamic>.from(value);
  }

  String _usageValue(
    Map<dynamic, dynamic>? metric,
    AppLocalizations strings,
    String unavailable,
  ) {
    final percent = metric?['percent'];
    if (metric?['available'] != true || percent is! num) return unavailable;
    return strings.percentValue(percent.toStringAsFixed(1));
  }

  Future<void> _showDiagnostics() async {
    if (_diagnosticsLoading ||
        (_channel == null &&
            _desktopController == null &&
            _windowsController == null)) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() => _diagnosticsLoading = true);
    try {
      final raw = _channel != null
          ? await _channel!.invokeMethod<String>('diagnostics')
          : _windowsController != null
          ? await _windowsController!.executeScript(
              'Talk2UAvatar.diagnostics()',
            )
          : await _desktopController!.evaluateJavascript(
              'Talk2UAvatar.diagnostics()',
            );
      final details = raw == null
          ? _readyDetails ?? const {}
          : _decodeDiagnostics(raw.toString(), strings);
      if (!mounted) return;
      final usage = details['resourceUsage'] as Map?;
      final renderer = details['renderer'] as Map?;
      final policy = details['rendererPolicy'] as Map?;
      final platform = renderer?['platform'] as Map?;
      final interop = platform?['vulkanInterop'] as Map?;
      final backend =
          policy?['actualBackend']?.toString() ??
          renderer?['backend']?.toString() ??
          strings.usageUnavailable;
      final gpuDevice =
          interop?['device']?.toString() ??
          renderer?['renderer']?.toString() ??
          strings.usageUnavailable;
      final frameCount = details['frameCount']?.toString() ?? '0';
      final accelerator = await AcceleratorTelemetryService.instance.sample();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.live2dDiagnostics),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DiagnosticRow(label: strings.renderBackend, value: backend),
              _DiagnosticRow(label: strings.gpuDevice, value: gpuDevice),
              _DiagnosticRow(label: strings.renderedFrames, value: frameCount),
              _DiagnosticRow(
                label: strings.cpuUsage,
                value: _usageValue(
                  usage?['cpu'] as Map?,
                  strings,
                  strings.usageUnavailable,
                ),
              ),
              _DiagnosticRow(
                label: strings.gpuUsage,
                value: _usageValue(
                  usage?['gpu'] as Map?,
                  strings,
                  strings.gpuUsageUnavailable,
                ),
              ),
              _DiagnosticRow(
                label: strings.npuUsage,
                value:
                    accelerator?.available != true ||
                        accelerator?.percent == null
                    ? strings.npuUsageUnavailable
                    : strings.npuRecentWorkload(
                        accelerator!.percent!.toStringAsFixed(1),
                      ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.close),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.diagnosticsFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _diagnosticsLoading = false);
    }
  }

  @override
  void dispose() {
    OfflineSpeechService.instance.removeListener(_syncMouth);
    _channel?.setMethodCallHandler(null);
    _desktopController?.dispose();
    unawaited(_windowsMessageSubscription?.cancel());
    _windowsController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final Widget renderer;
    if (defaultTargetPlatform == TargetPlatform.android) {
      renderer = PlatformViewLink(
        key: ValueKey('${widget.modelPath}::$_viewGeneration'),
        viewType: 'talk2u/live2d',
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
        onCreatePlatformView: (params) {
          return PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: 'talk2u/live2d',
              layoutDirection: TextDirection.ltr,
              creationParams: {
                'modelPath': widget.modelPath,
                'backgroundColor': Theme.of(
                  context,
                ).scaffoldBackgroundColor.toARGB32(),
              },
              creationParamsCodec: const StandardMessageCodec(),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener(_onCreated)
            ..create();
        },
      );
    } else if (_usesWindowsWebView) {
      final controller = _windowsController;
      renderer = controller == null
          ? const Center(child: CircularProgressIndicator())
          : windows_webview.Webview(controller);
    } else if (_usesDesktopCef) {
      final controller = _desktopController;
      renderer = controller == null
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<bool>(
              valueListenable: controller,
              builder: (context, ready, _) =>
                  ready ? controller.webviewWidget : controller.loadingWidget,
            );
    } else {
      renderer = Center(child: Text(strings.currentPlatformUnavailable));
    }
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          renderer,
          if (_readyDetails != null)
            Align(
              alignment: Alignment.topRight,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: strings.live2dDiagnosticsTooltip,
                  onPressed: _diagnosticsLoading ? null : _showDiagnostics,
                  icon: _diagnosticsLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.info_outline),
                ),
              ),
            ),
          if (_error != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _error!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      IconButton(
                        tooltip: strings.reloadLive2d,
                        onPressed: _restartRenderer,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  final String label;
  final String value;

  const _DiagnosticRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        const SizedBox(width: 12),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
