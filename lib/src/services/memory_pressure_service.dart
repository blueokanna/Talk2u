import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';

/// Applies Android memory-pressure trims on the Dart side.
///
/// The platform keeps the largest allocations (engine, GL, QNN), but Dart still
/// owns decoded images and synthesised WAV files. Dropping those on
/// `onTrimMemory` returns memory without touching an installed model, so the
/// next reply or utterance still works.
abstract final class MemoryPressureService {
  static const _channel = MethodChannel('talk2u/memory');

  /// Flutter keeps 1000 images / 100 MB by default. The UI shows no remote
  /// images, so the cache only needs to cover the current screen.
  static const maximumCachedImages = 64;
  static const maximumCachedImageBytes = 32 << 20;

  static bool _installed = false;

  /// Registers the platform handler and bounds the image cache.
  static void install({ImageCache? imageCache}) {
    configureImageCache(imageCache);
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'trim') await trim();
    });
  }

  /// Bounds the image cache without clearing it, so the first frame is not lost.
  static void configureImageCache([ImageCache? imageCache]) {
    final cache = imageCache ?? PaintingBinding.instance.imageCache;
    cache.maximumSize = maximumCachedImages;
    cache.maximumSizeBytes = maximumCachedImageBytes;
  }

  /// Drops decoded images and cached synthesis files.
  ///
  /// [imageCache] and [releaseAudio] are injectable so the behaviour can be
  /// asserted without a live platform channel.
  @visibleForTesting
  static Future<void> trim({
    ImageCache? imageCache,
    Future<void> Function()? releaseAudio,
  }) async {
    final cache = imageCache ?? PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    await (releaseAudio ?? MossTtsService.instance.trimAudioCache)();
  }
}
