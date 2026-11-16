// Standalone Android executable: exercises the production probe while a caller
// already owns a current EGL context. See docs/android-native-validation.md.
#include "../android/app/src/main/cpp/gpu_backend_probe.cpp"
#include <iostream>

int main() {
    NnApiDeviceProbe classified;
    for (int type = 0; type <= 4; ++type) {
        classified.type = type;
        if (classified.Hardware() != (type == 3 || type == 4)) {
            std::cerr << "NNAPI device classification failed for " << type << '\n';
            return 1;
        }
    }
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor) ||
        !eglBindAPI(EGL_OPENGL_ES_API)) return 2;
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint count = 0;
    if (!eglChooseConfig(display, attributes, &config, 1, &count) || count == 0) return 3;
    const EGLint dimensions[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, dimensions);
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, version);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
        !eglMakeCurrent(display, surface, surface, context)) return 4;
    for (int iteration = 0; iteration < 3; ++iteration) {
        std::cout << BuildResultJson() << std::endl;
        EGLint clientVersion = 0;
        if (eglGetCurrentDisplay() != display || eglGetCurrentContext() != context ||
            eglGetCurrentSurface(EGL_DRAW) != surface || eglGetCurrentSurface(EGL_READ) != surface ||
            !eglQueryContext(display, context, EGL_CONTEXT_CLIENT_VERSION, &clientVersion) ||
            glGetString(GL_VERSION) == nullptr) {
            std::cerr << "GPU probe invalidated the caller's EGL state\n";
            return 5;
        }
    }
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    // This standalone test process owns its only display; production probes don't.
    eglTerminate(display);
    std::cout << "PASS: NNAPI classification and caller EGL context survived three probes\n";
    return 0;
}
