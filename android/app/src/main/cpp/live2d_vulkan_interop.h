#pragma once

#include <jni.h>

#include <cstdint>
#include <memory>
#include <string>

namespace talk2u {

// Owns the cross-API render target and compositor. Cubism only sees the EGL
// framebuffer; Vulkan owns presentation. The AHardwareBuffer is retained by
// this object for the complete lifetime of both API images.
class VulkanInterop {
public:
    VulkanInterop();
    VulkanInterop(const VulkanInterop&) = delete;
    VulkanInterop& operator=(const VulkanInterop&) = delete;
    ~VulkanInterop();

    void Initialize(JNIEnv* env, jobject surface, uint32_t width, uint32_t height);
    void Resize(uint32_t width, uint32_t height);
    void MakeCurrent();
    void BeginFrame();
    void EndFrame();
    void Destroy();

    bool ready() const { return ready_; }
    std::string Diagnostics() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    bool ready_ = false;
};

}  // namespace talk2u
