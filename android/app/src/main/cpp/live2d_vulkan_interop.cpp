#include "live2d_vulkan_interop.h"

#define VK_USE_PLATFORM_ANDROID_KHR
#include <vulkan/vulkan.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace talk2u {
namespace {

void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

bool HasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
    return std::any_of(extensions.begin(), extensions.end(), [name](const auto& extension) {
        return std::strcmp(extension.extensionName, name) == 0;
    });
}

}  // namespace

struct VulkanInterop::Impl {
    ANativeWindow* window = nullptr;
    uint32_t width = 1;
    uint32_t height = 1;

    EGLDisplay eglDisplay = EGL_NO_DISPLAY;
    EGLContext eglContext = EGL_NO_CONTEXT;
    EGLSurface eglPbuffer = EGL_NO_SURFACE;
    EGLConfig eglConfig = nullptr;
    EGLImageKHR eglImage = EGL_NO_IMAGE_KHR;
    GLuint eglTexture = 0;
    GLuint eglFramebuffer = 0;
    PFNEGLCREATEIMAGEKHRPROC createEglImage = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroyEglImage = nullptr;
    PFNEGLCREATESYNCKHRPROC createEglSync = nullptr;
    PFNEGLDESTROYSYNCKHRPROC destroyEglSync = nullptr;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC dupNativeFenceFd = nullptr;
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getNativeClientBuffer = nullptr;
    void (*glEglImageTargetTexture)(GLenum, GLeglImageOES) = nullptr;

    AHardwareBuffer* hardwareBuffer = nullptr;

    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t queueFamily = 0;
    uint32_t timestampValidBits = 0;
    float timestampPeriod = 0.0F;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkFormat swapchainFormat = VK_FORMAT_UNDEFINED;
    VkExtent2D swapchainExtent{};
    std::vector<VkImage> swapchainImages;
    VkImage ahbImage = VK_NULL_HANDLE;
    VkDeviceMemory ahbMemory = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkSemaphore imageAvailable = VK_NULL_HANDLE;
    VkSemaphore renderFinished = VK_NULL_HANDLE;
    VkSemaphore importedEglFence = VK_NULL_HANDLE;
    VkFence frameFence = VK_NULL_HANDLE;
    VkQueryPool timestampQueryPool = VK_NULL_HANDLE;
    bool timestampPending = false;
    bool timestampHasSample = false;
    uint64_t timestampWindowNanos = 0;
    double timestampPercent = 0.0;
    std::chrono::steady_clock::time_point timestampWindowStarted;
    uint64_t outOfDateFrames = 0;
    uint64_t suboptimalFrames = 0;

    PFN_vkGetAndroidHardwareBufferPropertiesANDROID getAhbProperties = nullptr;
    PFN_vkImportSemaphoreFdKHR importSemaphoreFd = nullptr;

    ~Impl() { Destroy(); }

    void Initialize(ANativeWindow* nativeWindow, uint32_t requestedWidth, uint32_t requestedHeight) {
        Require(nativeWindow != nullptr, "Vulkan compositor received no Android Surface");
        window = nativeWindow;
        width = std::max(1U, requestedWidth);
        height = std::max(1U, requestedHeight);
        CreateEgl();
        CreateHardwareBuffer();
        CreateVulkan();
    }

    void CreateEgl() {
        eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        Require(eglDisplay != EGL_NO_DISPLAY, "eglGetDisplay failed");
        EGLint major = 0;
        EGLint minor = 0;
        Require(eglInitialize(eglDisplay, &major, &minor) == EGL_TRUE, "eglInitialize failed");
        Require(eglBindAPI(EGL_OPENGL_ES_API) == EGL_TRUE, "eglBindAPI failed");
        const EGLint configAttributes[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_NONE,
        };
        EGLint count = 0;
        Require(eglChooseConfig(eglDisplay, configAttributes, &eglConfig, 1, &count) == EGL_TRUE && count == 1,
                "No EGL ES2 pbuffer configuration");
        const EGLint surfaceAttributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        eglPbuffer = eglCreatePbufferSurface(eglDisplay, eglConfig, surfaceAttributes);
        Require(eglPbuffer != EGL_NO_SURFACE, "eglCreatePbufferSurface failed");
        const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        eglContext = eglCreateContext(eglDisplay, eglConfig, EGL_NO_CONTEXT, contextAttributes);
        Require(eglContext != EGL_NO_CONTEXT, "eglCreateContext failed");
        Require(eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext) == EGL_TRUE,
                "eglMakeCurrent failed");
        createEglImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
            eglGetProcAddress("eglCreateImageKHR"));
        destroyEglImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
            eglGetProcAddress("eglDestroyImageKHR"));
        createEglSync = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
            eglGetProcAddress("eglCreateSyncKHR"));
        destroyEglSync = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(
            eglGetProcAddress("eglDestroySyncKHR"));
        dupNativeFenceFd = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
            eglGetProcAddress("eglDupNativeFenceFDANDROID"));
        getNativeClientBuffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
            eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        glEglImageTargetTexture = reinterpret_cast<void (*)(GLenum, GLeglImageOES)>(
            eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        Require(createEglImage != nullptr && destroyEglImage != nullptr &&
                    createEglSync != nullptr && destroyEglSync != nullptr &&
                    dupNativeFenceFd != nullptr && getNativeClientBuffer != nullptr &&
                    glEglImageTargetTexture != nullptr,
                "Required EGL image/fence extensions are unavailable");
    }

    void CreateHardwareBuffer() {
        AHardwareBuffer_Desc description{};
        description.width = width;
        description.height = height;
        description.layers = 1;
        description.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
        description.usage = AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER |
            AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
            AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER;
        Require(AHardwareBuffer_allocate(&description, &hardwareBuffer) == 0 && hardwareBuffer != nullptr,
                "AHardwareBuffer allocation failed");
        const EGLClientBuffer clientBuffer = getNativeClientBuffer(hardwareBuffer);
        Require(clientBuffer != nullptr,
                "eglGetNativeClientBufferANDROID(AHardwareBuffer) failed");
        const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        eglImage = createEglImage(
            eglDisplay, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
            clientBuffer, attributes);
        Require(eglImage != EGL_NO_IMAGE_KHR, "eglCreateImageKHR(AHardwareBuffer) failed");
        glGenTextures(1, &eglTexture);
        glBindTexture(GL_TEXTURE_2D, eglTexture);
        glEglImageTargetTexture(GL_TEXTURE_2D, eglImage);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenFramebuffers(1, &eglFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, eglFramebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, eglTexture, 0);
        Require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                "AHardwareBuffer EGL framebuffer is incomplete");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
    }

    void CreateVulkan() {
        uint32_t instanceExtensionCount = 0;
        Require(vkEnumerateInstanceExtensionProperties(nullptr, &instanceExtensionCount, nullptr) == VK_SUCCESS,
                "vkEnumerateInstanceExtensionProperties failed");
        std::vector<VkExtensionProperties> instanceExtensions(instanceExtensionCount);
        Require(vkEnumerateInstanceExtensionProperties(nullptr, &instanceExtensionCount, instanceExtensions.data()) == VK_SUCCESS,
                "Unable to enumerate Vulkan instance extensions");
        Require(HasExtension(instanceExtensions, VK_KHR_SURFACE_EXTENSION_NAME) &&
                    HasExtension(instanceExtensions, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME),
                "Vulkan Android surface extensions are unavailable");
        const char* enabledInstanceExtensions[] = {
            VK_KHR_SURFACE_EXTENSION_NAME,
            VK_KHR_ANDROID_SURFACE_EXTENSION_NAME,
        };
        VkApplicationInfo applicationInfo{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        applicationInfo.pApplicationName = "Talk2U Live2D";
        applicationInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
        applicationInfo.pEngineName = "Talk2U";
        applicationInfo.engineVersion = VK_MAKE_VERSION(1, 0, 0);
        applicationInfo.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        instanceInfo.pApplicationInfo = &applicationInfo;
        instanceInfo.enabledExtensionCount = 2;
        instanceInfo.ppEnabledExtensionNames = enabledInstanceExtensions;
        Require(vkCreateInstance(&instanceInfo, nullptr, &instance) == VK_SUCCESS,
                "vkCreateInstance failed");

        VkAndroidSurfaceCreateInfoKHR surfaceInfo{VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR};
        surfaceInfo.window = window;
        Require(vkCreateAndroidSurfaceKHR(instance, &surfaceInfo, nullptr, &surface) == VK_SUCCESS,
                "vkCreateAndroidSurfaceKHR failed");

        uint32_t physicalCount = 0;
        Require(vkEnumeratePhysicalDevices(instance, &physicalCount, nullptr) == VK_SUCCESS && physicalCount > 0,
                "No Vulkan physical device is available");
        std::vector<VkPhysicalDevice> physicalDevices(physicalCount);
        vkEnumeratePhysicalDevices(instance, &physicalCount, physicalDevices.data());
        const std::array<const char*, 5> requiredDeviceExtensions = {
            VK_KHR_SWAPCHAIN_EXTENSION_NAME,
            VK_ANDROID_EXTERNAL_MEMORY_ANDROID_HARDWARE_BUFFER_EXTENSION_NAME,
            VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
        };
        for (VkPhysicalDevice candidate : physicalDevices) {
            uint32_t queueCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &queueCount, nullptr);
            std::vector<VkQueueFamilyProperties> queues(queueCount);
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &queueCount, queues.data());
            for (uint32_t index = 0; index < queueCount; ++index) {
                VkBool32 present = VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(candidate, index, surface, &present);
                if (queues[index].queueCount == 0 ||
                    (queues[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0 || !present) continue;
                uint32_t extensionCount = 0;
                vkEnumerateDeviceExtensionProperties(candidate, nullptr, &extensionCount, nullptr);
                std::vector<VkExtensionProperties> extensions(extensionCount);
                vkEnumerateDeviceExtensionProperties(candidate, nullptr, &extensionCount, extensions.data());
                if (std::all_of(requiredDeviceExtensions.begin(), requiredDeviceExtensions.end(),
                                [&](const char* name) { return HasExtension(extensions, name); })) {
                    physicalDevice = candidate;
                    queueFamily = index;
                    timestampValidBits = queues[index].timestampValidBits;
                    break;
                }
            }
            if (physicalDevice != VK_NULL_HANDLE) break;
        }
        Require(physicalDevice != VK_NULL_HANDLE,
                "No Vulkan device supports AHardwareBuffer external memory and fence semaphores");
        const float priority = 1.0F;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex = queueFamily;
        queueInfo.queueCount = 1;
        queueInfo.pQueuePriorities = &priority;
        const char* deviceExtensions[] = {
            VK_KHR_SWAPCHAIN_EXTENSION_NAME,
            VK_ANDROID_EXTERNAL_MEMORY_ANDROID_HARDWARE_BUFFER_EXTENSION_NAME,
            VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
        };
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        deviceInfo.queueCreateInfoCount = 1;
        deviceInfo.pQueueCreateInfos = &queueInfo;
        deviceInfo.enabledExtensionCount = 5;
        deviceInfo.ppEnabledExtensionNames = deviceExtensions;
        Require(vkCreateDevice(physicalDevice, &deviceInfo, nullptr, &device) == VK_SUCCESS,
                "vkCreateDevice failed");
        vkGetDeviceQueue(device, queueFamily, 0, &queue);
        VkPhysicalDeviceProperties physicalProperties{};
        vkGetPhysicalDeviceProperties(physicalDevice, &physicalProperties);
        timestampPeriod = physicalProperties.limits.timestampPeriod;
        getAhbProperties = reinterpret_cast<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(
            vkGetDeviceProcAddr(device, "vkGetAndroidHardwareBufferPropertiesANDROID"));
        importSemaphoreFd = reinterpret_cast<PFN_vkImportSemaphoreFdKHR>(
            vkGetDeviceProcAddr(device, "vkImportSemaphoreFdKHR"));
        Require(getAhbProperties != nullptr && importSemaphoreFd != nullptr,
                "Vulkan AHardwareBuffer/fence entry points are unavailable");

        CreateSwapchain();
        VkExternalMemoryImageCreateInfo externalImageInfo{
            VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
        externalImageInfo.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
        VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        imageInfo.pNext = &externalImageInfo;
        imageInfo.imageType = VK_IMAGE_TYPE_2D;
        imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
        imageInfo.extent = {width, height, 1};
        imageInfo.mipLevels = 1;
        imageInfo.arrayLayers = 1;
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
        imageInfo.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        Require(vkCreateImage(device, &imageInfo, nullptr, &ahbImage) == VK_SUCCESS,
                "vkCreateImage(AHardwareBuffer) failed");
        VkAndroidHardwareBufferPropertiesANDROID bufferProperties{
            VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID};
        Require(getAhbProperties(device, hardwareBuffer, &bufferProperties) == VK_SUCCESS,
                "vkGetAndroidHardwareBufferPropertiesANDROID failed");
        VkMemoryRequirements requirements{};
        vkGetImageMemoryRequirements(device, ahbImage, &requirements);
        uint32_t memoryType = UINT32_MAX;
        VkPhysicalDeviceMemoryProperties memoryProperties{};
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memoryProperties);
        for (uint32_t index = 0; index < memoryProperties.memoryTypeCount; ++index) {
            if ((requirements.memoryTypeBits & (1U << index)) != 0 &&
                (bufferProperties.memoryTypeBits & (1U << index)) != 0) {
                memoryType = index;
                break;
            }
        }
        Require(memoryType != UINT32_MAX, "No Vulkan memory type can import AHardwareBuffer");
        VkImportAndroidHardwareBufferInfoANDROID importInfo{
            VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID};
        importInfo.buffer = hardwareBuffer;
        VkMemoryDedicatedAllocateInfo dedicatedInfo{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
        dedicatedInfo.pNext = &importInfo;
        dedicatedInfo.image = ahbImage;
        VkMemoryAllocateInfo allocateInfo{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocateInfo.pNext = &dedicatedInfo;
        allocateInfo.allocationSize = bufferProperties.allocationSize;
        allocateInfo.memoryTypeIndex = memoryType;
        Require(vkAllocateMemory(device, &allocateInfo, nullptr, &ahbMemory) == VK_SUCCESS,
                "vkAllocateMemory(AHardwareBuffer) failed");
        Require(vkBindImageMemory(device, ahbImage, ahbMemory, 0) == VK_SUCCESS,
                "vkBindImageMemory(AHardwareBuffer) failed");

        VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolInfo.queueFamilyIndex = queueFamily;
        Require(vkCreateCommandPool(device, &poolInfo, nullptr, &commandPool) == VK_SUCCESS,
                "vkCreateCommandPool failed");
        VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandInfo.commandPool = commandPool;
        commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        commandInfo.commandBufferCount = 1;
        Require(vkAllocateCommandBuffers(device, &commandInfo, &commandBuffer) == VK_SUCCESS,
                "vkAllocateCommandBuffers failed");
        VkSemaphoreCreateInfo semaphoreInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        Require(vkCreateSemaphore(device, &semaphoreInfo, nullptr, &imageAvailable) == VK_SUCCESS &&
                    vkCreateSemaphore(device, &semaphoreInfo, nullptr, &renderFinished) == VK_SUCCESS &&
                    vkCreateSemaphore(device, &semaphoreInfo, nullptr, &importedEglFence) == VK_SUCCESS,
                "vkCreateSemaphore failed");
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        Require(vkCreateFence(device, &fenceInfo, nullptr, &frameFence) == VK_SUCCESS,
                "vkCreateFence failed");
        if (timestampValidBits > 0 && timestampPeriod > 0.0F) {
            VkQueryPoolCreateInfo queryInfo{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
            queryInfo.queryType = VK_QUERY_TYPE_TIMESTAMP;
            queryInfo.queryCount = 2;
            Require(vkCreateQueryPool(device, &queryInfo, nullptr, &timestampQueryPool) == VK_SUCCESS,
                    "vkCreateQueryPool(timestamp) failed");
            timestampWindowStarted = std::chrono::steady_clock::now();
        }
    }

    void CreateSwapchain() {
        VkSurfaceCapabilitiesKHR capabilities{};
        Require(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &capabilities) == VK_SUCCESS,
                "vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed");
        uint32_t formatCount = 0;
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, nullptr);
        std::vector<VkSurfaceFormatKHR> formats(formatCount);
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, formats.data());
        Require(!formats.empty(), "Vulkan surface has no formats");
        const auto preferred = std::find_if(formats.begin(), formats.end(), [](const auto& format) {
            return format.format == VK_FORMAT_R8G8B8A8_UNORM;
        });
        const VkSurfaceFormatKHR selected = preferred == formats.end() ? formats.front() : *preferred;
        swapchainFormat = selected.format;
        swapchainExtent = capabilities.currentExtent.width == UINT32_MAX
            ? VkExtent2D{std::clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
                         std::clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)}
            : capabilities.currentExtent;
        uint32_t imageCount = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0) imageCount = std::min(imageCount, capabilities.maxImageCount);
        VkSwapchainCreateInfoKHR swapInfo{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
        swapInfo.surface = surface;
        swapInfo.minImageCount = imageCount;
        swapInfo.imageFormat = swapchainFormat;
        swapInfo.imageColorSpace = selected.colorSpace;
        swapInfo.imageExtent = swapchainExtent;
        swapInfo.imageArrayLayers = 1;
        swapInfo.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        swapInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        swapInfo.preTransform = capabilities.currentTransform;
        constexpr std::array<VkCompositeAlphaFlagBitsKHR, 4> compositeAlphaModes{
            VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
            VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
            VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        };
        const auto alpha = std::find_if(
            compositeAlphaModes.begin(), compositeAlphaModes.end(), [&](const auto mode) {
                return (capabilities.supportedCompositeAlpha & mode) != 0;
            });
        Require(alpha != compositeAlphaModes.end(), "Vulkan surface has no composite alpha mode");
        Require((capabilities.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0,
                "Vulkan surface cannot receive a GPU transfer");
        swapInfo.compositeAlpha = *alpha;
        swapInfo.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        swapInfo.clipped = VK_TRUE;
        Require(vkCreateSwapchainKHR(device, &swapInfo, nullptr, &swapchain) == VK_SUCCESS,
                "vkCreateSwapchainKHR failed");
        uint32_t count = 0;
        vkGetSwapchainImagesKHR(device, swapchain, &count, nullptr);
        swapchainImages.resize(count);
        vkGetSwapchainImagesKHR(device, swapchain, &count, swapchainImages.data());
    }

    int ExportEglFence() {
        const EGLint attributes[] = {EGL_NONE};
        EGLSyncKHR fence = createEglSync(
            eglDisplay, EGL_SYNC_NATIVE_FENCE_ANDROID, attributes);
        Require(fence != EGL_NO_SYNC_KHR, "eglCreateSyncKHR(native fence) failed");
        glFlush();
        const int fd = dupNativeFenceFd(eglDisplay, fence);
        destroyEglSync(eglDisplay, fence);
        Require(fd >= 0, "eglDupNativeFenceFDANDROID failed");
        return fd;
    }

    void MakeCurrent() {
        Require(eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext) == EGL_TRUE,
                "eglMakeCurrent failed for Live2D frame");
        glBindFramebuffer(GL_FRAMEBUFFER, eglFramebuffer);
        glViewport(0, 0, static_cast<GLsizei>(width), static_cast<GLsizei>(height));
    }

    void BeginFrame() {
        Require(vkWaitForFences(device, 1, &frameFence, VK_TRUE, UINT64_MAX) == VK_SUCCESS,
                "vkWaitForFences failed");
        PollTimestampQuery();
        MakeCurrent();
    }

    void PollTimestampQuery() {
        if (timestampQueryPool == VK_NULL_HANDLE || !timestampPending) return;
        std::array<uint64_t, 2> values{};
        const VkResult result = vkGetQueryPoolResults(
            device, timestampQueryPool, 0, 2, sizeof(values), values.data(), sizeof(uint64_t),
            VK_QUERY_RESULT_64_BIT);
        if (result == VK_NOT_READY) return;
        Require(result == VK_SUCCESS, "vkGetQueryPoolResults(timestamp) failed");
        timestampPending = false;
        const uint64_t mask = timestampValidBits >= 64
            ? std::numeric_limits<uint64_t>::max()
            : (uint64_t{1} << timestampValidBits) - 1U;
        const uint64_t ticks = (values[1] - values[0]) & mask;
        timestampWindowNanos += static_cast<uint64_t>(
            static_cast<double>(ticks) * static_cast<double>(timestampPeriod));
        const auto now = std::chrono::steady_clock::now();
        const auto wallNanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
            now - timestampWindowStarted).count();
        if (wallNanos >= 1'000'000'000LL) {
            timestampPercent = std::clamp(
                static_cast<double>(timestampWindowNanos) * 100.0 / static_cast<double>(wallNanos),
                0.0, 100.0);
            timestampHasSample = true;
            timestampWindowNanos = 0;
            timestampWindowStarted = now;
        }
    }

    void EndFrame() {
        const int fenceFd = ExportEglFence();
        VkImportSemaphoreFdInfoKHR importInfo{VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR};
        importInfo.semaphore = importedEglFence;
        importInfo.flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT;
        importInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        importInfo.fd = fenceFd;
        Require(importSemaphoreFd(device, &importInfo) == VK_SUCCESS,
                "vkImportSemaphoreFdKHR(EGL fence) failed");
        uint32_t imageIndex = 0;
        const VkResult acquire = vkAcquireNextImageKHR(
            device, swapchain, UINT64_MAX, imageAvailable, VK_NULL_HANDLE, &imageIndex);
        if (acquire == VK_ERROR_OUT_OF_DATE_KHR) {
            ++outOfDateFrames;
            return;
        }
        if (acquire == VK_SUBOPTIMAL_KHR) {
            ++suboptimalFrames;
        } else {
            Require(acquire == VK_SUCCESS, "vkAcquireNextImageKHR failed");
        }
        vkResetCommandBuffer(commandBuffer, 0);
        VkCommandBufferBeginInfo beginInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        Require(vkBeginCommandBuffer(commandBuffer, &beginInfo) == VK_SUCCESS,
                "vkBeginCommandBuffer failed");
        if (timestampQueryPool != VK_NULL_HANDLE) {
            vkCmdResetQueryPool(commandBuffer, timestampQueryPool, 0, 2);
            vkCmdWriteTimestamp(
                commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, timestampQueryPool, 0);
        }
        VkImageMemoryBarrier barriers[2]{};
        barriers[0].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barriers[0].srcAccessMask = 0;
        barriers[0].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barriers[0].oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barriers[0].newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barriers[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
        barriers[0].dstQueueFamilyIndex = queueFamily;
        barriers[0].image = ahbImage;
        barriers[0].subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        barriers[1].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barriers[1].srcAccessMask = 0;
        barriers[1].dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barriers[1].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barriers[1].newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[1].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[1].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barriers[1].image = swapchainImages[imageIndex];
        barriers[1].subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 2, barriers);
        VkImageBlit blit{};
        blit.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        // OpenGL framebuffer images use a bottom-left origin; Vulkan presents
        // from the top-left, so reverse the source Y range during the GPU blit.
        blit.srcOffsets[0] = {0, static_cast<int32_t>(height), 0};
        blit.srcOffsets[1] = {static_cast<int32_t>(width), 0, 1};
        blit.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        blit.dstOffsets[1] = {static_cast<int32_t>(swapchainExtent.width), static_cast<int32_t>(swapchainExtent.height), 1};
        vkCmdBlitImage(commandBuffer, ahbImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       swapchainImages[imageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                       1, &blit, VK_FILTER_NEAREST);
        VkImageMemoryBarrier releaseBarriers[2]{};
        releaseBarriers[0] = barriers[0];
        releaseBarriers[0].srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        releaseBarriers[0].dstAccessMask = 0;
        releaseBarriers[0].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        releaseBarriers[0].newLayout = VK_IMAGE_LAYOUT_GENERAL;
        releaseBarriers[0].srcQueueFamilyIndex = queueFamily;
        releaseBarriers[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
        releaseBarriers[1] = barriers[1];
        releaseBarriers[1].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        releaseBarriers[1].dstAccessMask = 0;
        releaseBarriers[1].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        releaseBarriers[1].newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr,
                             2, releaseBarriers);
        if (timestampQueryPool != VK_NULL_HANDLE) {
            vkCmdWriteTimestamp(
                commandBuffer, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, timestampQueryPool, 1);
        }
        Require(vkEndCommandBuffer(commandBuffer) == VK_SUCCESS, "vkEndCommandBuffer failed");
        const VkSemaphore waitSemaphores[] = {imageAvailable, importedEglFence};
        const VkPipelineStageFlags waitStages[] = {
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT};
        VkSubmitInfo submitInfo{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submitInfo.waitSemaphoreCount = 2;
        submitInfo.pWaitSemaphores = waitSemaphores;
        submitInfo.pWaitDstStageMask = waitStages;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &commandBuffer;
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &renderFinished;
        Require(vkResetFences(device, 1, &frameFence) == VK_SUCCESS,
                "vkResetFences failed");
        Require(vkQueueSubmit(queue, 1, &submitInfo, frameFence) == VK_SUCCESS,
                "vkQueueSubmit failed");
        timestampPending = timestampQueryPool != VK_NULL_HANDLE;
        VkPresentInfoKHR presentInfo{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
        presentInfo.waitSemaphoreCount = 1;
        presentInfo.pWaitSemaphores = &renderFinished;
        presentInfo.swapchainCount = 1;
        presentInfo.pSwapchains = &swapchain;
        presentInfo.pImageIndices = &imageIndex;
        const VkResult present = vkQueuePresentKHR(queue, &presentInfo);
        if (present == VK_ERROR_OUT_OF_DATE_KHR) {
            ++outOfDateFrames;
        } else if (present == VK_SUBOPTIMAL_KHR) {
            ++suboptimalFrames;
        } else {
            Require(present == VK_SUCCESS, "vkQueuePresentKHR failed");
        }
    }

    void DestroySharedTarget() {
        if (eglDisplay != EGL_NO_DISPLAY) eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext);
        if (eglFramebuffer != 0) glDeleteFramebuffers(1, &eglFramebuffer);
        if (eglTexture != 0) glDeleteTextures(1, &eglTexture);
        eglFramebuffer = 0;
        eglTexture = 0;
        if (eglImage != EGL_NO_IMAGE_KHR && destroyEglImage != nullptr) {
            destroyEglImage(eglDisplay, eglImage);
        }
        eglImage = EGL_NO_IMAGE_KHR;
        if (hardwareBuffer != nullptr) AHardwareBuffer_release(hardwareBuffer);
        hardwareBuffer = nullptr;
    }

    void Destroy() {
        if (device != VK_NULL_HANDLE) vkDeviceWaitIdle(device);
        if (device != VK_NULL_HANDLE) {
            if (frameFence != VK_NULL_HANDLE) vkDestroyFence(device, frameFence, nullptr);
            if (timestampQueryPool != VK_NULL_HANDLE) {
                vkDestroyQueryPool(device, timestampQueryPool, nullptr);
            }
            if (importedEglFence != VK_NULL_HANDLE) vkDestroySemaphore(device, importedEglFence, nullptr);
            if (renderFinished != VK_NULL_HANDLE) vkDestroySemaphore(device, renderFinished, nullptr);
            if (imageAvailable != VK_NULL_HANDLE) vkDestroySemaphore(device, imageAvailable, nullptr);
            if (commandPool != VK_NULL_HANDLE) vkDestroyCommandPool(device, commandPool, nullptr);
            if (ahbImage != VK_NULL_HANDLE) vkDestroyImage(device, ahbImage, nullptr);
            if (ahbMemory != VK_NULL_HANDLE) vkFreeMemory(device, ahbMemory, nullptr);
            if (swapchain != VK_NULL_HANDLE) vkDestroySwapchainKHR(device, swapchain, nullptr);
            vkDestroyDevice(device, nullptr);
        }
        device = VK_NULL_HANDLE;
        timestampQueryPool = VK_NULL_HANDLE;
        timestampPending = false;
        if (instance != VK_NULL_HANDLE) {
            if (surface != VK_NULL_HANDLE) vkDestroySurfaceKHR(instance, surface, nullptr);
            vkDestroyInstance(instance, nullptr);
        }
        instance = VK_NULL_HANDLE;
        surface = VK_NULL_HANDLE;
        physicalDevice = VK_NULL_HANDLE;
        DestroySharedTarget();
        if (eglDisplay != EGL_NO_DISPLAY) {
            eglMakeCurrent(eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (eglContext != EGL_NO_CONTEXT) eglDestroyContext(eglDisplay, eglContext);
            if (eglPbuffer != EGL_NO_SURFACE) eglDestroySurface(eglDisplay, eglPbuffer);
            eglTerminate(eglDisplay);
        }
        eglDisplay = EGL_NO_DISPLAY;
        eglContext = EGL_NO_CONTEXT;
        eglPbuffer = EGL_NO_SURFACE;
        if (window != nullptr) ANativeWindow_release(window);
        window = nullptr;
    }
};

VulkanInterop::VulkanInterop() = default;

VulkanInterop::~VulkanInterop() { Destroy(); }

void VulkanInterop::Initialize(JNIEnv* env, jobject surface, uint32_t width, uint32_t height) {
    Require(env != nullptr && surface != nullptr, "Invalid Android Surface");
    Destroy();
    impl_ = std::make_unique<Impl>();
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    try {
        impl_->Initialize(window, width, height);
        ready_ = true;
    } catch (...) {
        if (window != nullptr && impl_->window == nullptr) ANativeWindow_release(window);
        impl_.reset();
        ready_ = false;
        throw;
    }
}

void VulkanInterop::Resize(uint32_t width, uint32_t height) {
    if (!impl_ || !ready_) return;
    if (impl_->width == std::max(1U, width) && impl_->height == std::max(1U, height)) return;
    ANativeWindow* window = impl_->window;
    ANativeWindow_acquire(window);
    impl_->window = nullptr;
    impl_->Destroy();
    impl_ = std::make_unique<Impl>();
    ready_ = false;
    try {
        impl_->Initialize(window, width, height);
        ready_ = true;
    } catch (...) {
        impl_.reset();
        throw;
    }
}

void VulkanInterop::BeginFrame() {
    Require(impl_ != nullptr && ready_, "Vulkan compositor is not ready");
    impl_->BeginFrame();
}

void VulkanInterop::MakeCurrent() {
    Require(impl_ != nullptr && ready_, "Vulkan compositor is not ready");
    impl_->MakeCurrent();
}

void VulkanInterop::EndFrame() {
    Require(impl_ != nullptr && ready_, "Vulkan compositor is not ready");
    impl_->EndFrame();
}

void VulkanInterop::Destroy() {
    if (impl_) impl_->Destroy();
    impl_.reset();
    ready_ = false;
}

std::string VulkanInterop::Diagnostics() const {
    if (!impl_ || !ready_) return "{\"ready\":false}";
    VkPhysicalDeviceProperties properties{};
    vkGetPhysicalDeviceProperties(impl_->physicalDevice, &properties);
    return std::string("{\"ready\":true,\"backend\":\"Vulkan\",\"device\":\"") +
        properties.deviceName +
        "\",\"cpuCopy\":false,\"gpuBlit\":true,"
        "\"synchronization\":\"EGL native fence -> VkSemaphore\","
        "\"gpuTiming\":{\"available\":" +
        std::string(impl_->timestampHasSample ? "true" : "false") +
        ",\"scope\":\"Live2D Vulkan presentation\","
        "\"source\":\"Vulkan timestamp query\"" +
        (impl_->timestampHasSample
             ? ",\"percent\":" + std::to_string(impl_->timestampPercent)
             : std::string()) + "}," +
        "\"outOfDateFrames\":" + std::to_string(impl_->outOfDateFrames) +
        ",\"suboptimalFrames\":" + std::to_string(impl_->suboptimalFrames) + "}";
}

}  // namespace talk2u
