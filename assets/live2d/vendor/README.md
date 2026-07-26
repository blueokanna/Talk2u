# Live2D runtime files

This directory contains the redistributable parts of the Android Web runtime:

- `pixi.min.js`: PixiJS 6.5.10, MIT License
- `cubism4.min.js`: pixi-live2d-display 0.4.0 Cubism runtime, MIT License
- the matching `*.LICENSE.txt` files

The proprietary `live2dcubismcore.min.js` is intentionally not committed. For
offline model rendering, obtain Cubism SDK for Web 5.x under Live2D's terms and
run:

```powershell
.\tool\install_live2d_core.ps1 `
  -SdkRoot 'D:\path\to\CubismSdkForWeb-5-r.x' `
  -AcceptLive2DLicense
```

Without that local file, the app attempts the official Live2D HTTPS CDN. That
fallback is online mode and must not be described as offline rendering.

Compatibility boundary: pixi-live2d-display 0.4.0 registers a Cubism 4 API
runtime. Talk2U requires Cubism Core 5 and validates MOC3 version 5 / CDI3
version 3 models, but this is not the official Cubism SDK for Native 5
Framework or its native Vulkan renderer. Android System WebView/ANGLE owns the
actual Vulkan versus OpenGL ES backend choice; check the in-app diagnostics on
every target device.
