import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/memory_pressure_service.dart';

/// Image cache that records the two clearing calls without decoding anything.
class _RecordingCache extends ImageCache {
  int clears = 0;

  @override
  void clear() {
    clears++;
    super.clear();
  }

  @override
  void clearLiveImages() {
    clears++;
    super.clearLiveImages();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bounds the image cache instead of accepting the 100 MB default', () {
    final cache = _RecordingCache();
    MemoryPressureService.configureImageCache(cache);
    expect(cache.maximumSize, MemoryPressureService.maximumCachedImages);
    expect(
      cache.maximumSizeBytes,
      MemoryPressureService.maximumCachedImageBytes,
    );
    expect(cache.maximumSizeBytes, lessThan(100 << 20));
  });

  test('trim clears images and releases cached audio exactly once', () async {
    final cache = _RecordingCache();
    var audioReleases = 0;
    await MemoryPressureService.trim(
      imageCache: cache,
      releaseAudio: () async => audioReleases++,
    );
    expect(cache.clears, 2);
    expect(audioReleases, 1);
  });
}
