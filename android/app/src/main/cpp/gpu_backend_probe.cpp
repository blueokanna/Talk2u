#include <jni.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::string JsonEscape(const char* raw) {
    const std::string value = raw == nullptr ? "" : raw;
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
            case '\"': output << "\\\""; break;
            case '\\': output << "\\\\"; break;
            case '\b': output << "\\b"; break;
            case '\f': output << "\\f"; break;
            case '\n': output << "\\n"; break;
            case '\r': output << "\\r"; break;
            case '\t': output << "\\t"; break;
            default:
                if (character < 0x20) {
                    constexpr char digits[] = "0123456789abcdef";
                    output << "\\u00" << digits[(character >> 4) & 0x0f]
                           << digits[character & 0x0f];
                } else {
                    output << character;
                }
        }
    }
    return output.str();
}

std::string VulkanVersion(uint32_t version) {
    std::ostringstream output;
    output << VK_VERSION_MAJOR(version) << '.'
           << VK_VERSION_MINOR(version) << '.'
           << VK_VERSION_PATCH(version);
    return output.str();
}

struct VulkanProbeResult {
    bool loader = false;
    bool instance = false;
    bool surfaceExtensions = false;
    bool graphicsQueue = false;
    bool swapchainExtension = false;
    bool logicalDevice = false;
    bool hardwareDevice = false;
    int resultCode = VK_ERROR_INITIALIZATION_FAILED;
    std::string deviceName;
    std::string apiVersion;

    bool Ready() const {
        return loader && instance && surfaceExtensions && graphicsQueue &&
               swapchainExtension && logicalDevice && hardwareDevice;
    }
};

template <typename T>
T LoadGlobal(PFN_vkGetInstanceProcAddr getProc, const char* name) {
    return reinterpret_cast<T>(getProc(VK_NULL_HANDLE, name));
}

template <typename T>
T LoadInstance(PFN_vkGetInstanceProcAddr getProc, VkInstance instance, const char* name) {
    return reinterpret_cast<T>(getProc(instance, name));
}

bool HasExtension(const std::vector<VkExtensionProperties>& extensions, const char* name) {
    return std::any_of(extensions.begin(), extensions.end(), [name](const auto& extension) {
        return std::string(extension.extensionName) == name;
    });
}

VulkanProbeResult ProbeVulkan() {
    VulkanProbeResult output;
    void* library = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (library == nullptr) return output;
    output.loader = true;

    const auto getInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
        dlsym(library, "vkGetInstanceProcAddr"));
    if (getInstanceProcAddr == nullptr) {
        dlclose(library);
        return output;
    }

    const auto enumerateInstanceExtensions = LoadGlobal<PFN_vkEnumerateInstanceExtensionProperties>(
        getInstanceProcAddr, "vkEnumerateInstanceExtensionProperties");
    const auto createInstance = LoadGlobal<PFN_vkCreateInstance>(
        getInstanceProcAddr, "vkCreateInstance");
    if (enumerateInstanceExtensions == nullptr || createInstance == nullptr) {
        dlclose(library);
        return output;
    }

    uint32_t instanceExtensionCount = 0;
    if (enumerateInstanceExtensions(nullptr, &instanceExtensionCount, nullptr) != VK_SUCCESS) {
        dlclose(library);
        return output;
    }
    std::vector<VkExtensionProperties> instanceExtensions(instanceExtensionCount);
    if (instanceExtensionCount > 0 &&
        enumerateInstanceExtensions(nullptr, &instanceExtensionCount, instanceExtensions.data()) != VK_SUCCESS) {
        dlclose(library);
        return output;
    }
    output.surfaceExtensions =
        HasExtension(instanceExtensions, "VK_KHR_surface") &&
        HasExtension(instanceExtensions, "VK_KHR_android_surface");

    std::vector<const char*> enabledInstanceExtensions;
    if (output.surfaceExtensions) {
        enabledInstanceExtensions = {"VK_KHR_surface", "VK_KHR_android_surface"};
    }

    VkApplicationInfo applicationInfo{};
    applicationInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    applicationInfo.pApplicationName = "Talk2U GPU Probe";
    applicationInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    applicationInfo.pEngineName = "Talk2U";
    applicationInfo.engineVersion = VK_MAKE_VERSION(1, 0, 0);
    applicationInfo.apiVersion = VK_API_VERSION_1_0;

    VkInstanceCreateInfo instanceInfo{};
    instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.pApplicationInfo = &applicationInfo;
    instanceInfo.enabledExtensionCount = static_cast<uint32_t>(enabledInstanceExtensions.size());
    instanceInfo.ppEnabledExtensionNames = enabledInstanceExtensions.data();

    VkInstance instance = VK_NULL_HANDLE;
    output.resultCode = createInstance(&instanceInfo, nullptr, &instance);
    if (output.resultCode != VK_SUCCESS || instance == VK_NULL_HANDLE) {
        dlclose(library);
        return output;
    }
    output.instance = true;

    const auto destroyInstance = LoadInstance<PFN_vkDestroyInstance>(
        getInstanceProcAddr, instance, "vkDestroyInstance");
    const auto enumeratePhysicalDevices = LoadInstance<PFN_vkEnumeratePhysicalDevices>(
        getInstanceProcAddr, instance, "vkEnumeratePhysicalDevices");
    const auto getPhysicalDeviceProperties = LoadInstance<PFN_vkGetPhysicalDeviceProperties>(
        getInstanceProcAddr, instance, "vkGetPhysicalDeviceProperties");
    const auto getQueueFamilyProperties = LoadInstance<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        getInstanceProcAddr, instance, "vkGetPhysicalDeviceQueueFamilyProperties");
    const auto enumerateDeviceExtensions = LoadInstance<PFN_vkEnumerateDeviceExtensionProperties>(
        getInstanceProcAddr, instance, "vkEnumerateDeviceExtensionProperties");
    const auto createDevice = LoadInstance<PFN_vkCreateDevice>(
        getInstanceProcAddr, instance, "vkCreateDevice");
    const auto getDeviceProcAddr = LoadInstance<PFN_vkGetDeviceProcAddr>(
        getInstanceProcAddr, instance, "vkGetDeviceProcAddr");

    if (destroyInstance == nullptr || enumeratePhysicalDevices == nullptr ||
        getPhysicalDeviceProperties == nullptr || getQueueFamilyProperties == nullptr ||
        enumerateDeviceExtensions == nullptr || createDevice == nullptr ||
        getDeviceProcAddr == nullptr) {
        if (destroyInstance != nullptr) destroyInstance(instance, nullptr);
        dlclose(library);
        return output;
    }

    uint32_t physicalDeviceCount = 0;
    VkResult enumerateResult = enumeratePhysicalDevices(instance, &physicalDeviceCount, nullptr);
    if (enumerateResult == VK_SUCCESS && physicalDeviceCount > 0) {
        std::vector<VkPhysicalDevice> physicalDevices(physicalDeviceCount);
        enumerateResult = enumeratePhysicalDevices(instance, &physicalDeviceCount, physicalDevices.data());
        for (const VkPhysicalDevice physicalDevice : physicalDevices) {
            if (enumerateResult != VK_SUCCESS) break;

            uint32_t queueCount = 0;
            getQueueFamilyProperties(physicalDevice, &queueCount, nullptr);
            std::vector<VkQueueFamilyProperties> queues(queueCount);
            if (queueCount > 0) {
                getQueueFamilyProperties(physicalDevice, &queueCount, queues.data());
            }
            const auto queue = std::find_if(queues.begin(), queues.end(), [](const auto& properties) {
                return properties.queueCount > 0 &&
                       (properties.queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0;
            });
            if (queue == queues.end()) continue;
            output.graphicsQueue = true;
            const uint32_t queueIndex = static_cast<uint32_t>(std::distance(queues.begin(), queue));

            uint32_t deviceExtensionCount = 0;
            if (enumerateDeviceExtensions(
                    physicalDevice, nullptr, &deviceExtensionCount, nullptr) != VK_SUCCESS) {
                continue;
            }
            std::vector<VkExtensionProperties> deviceExtensions(deviceExtensionCount);
            if (deviceExtensionCount > 0 && enumerateDeviceExtensions(
                    physicalDevice, nullptr, &deviceExtensionCount, deviceExtensions.data()) != VK_SUCCESS) {
                continue;
            }
            if (!HasExtension(deviceExtensions, "VK_KHR_swapchain")) continue;
            output.swapchainExtension = true;

            const float priority = 1.0F;
            VkDeviceQueueCreateInfo queueInfo{};
            queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueInfo.queueFamilyIndex = queueIndex;
            queueInfo.queueCount = 1;
            queueInfo.pQueuePriorities = &priority;

            const char* deviceExtension = "VK_KHR_swapchain";
            VkDeviceCreateInfo deviceInfo{};
            deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
            deviceInfo.queueCreateInfoCount = 1;
            deviceInfo.pQueueCreateInfos = &queueInfo;
            deviceInfo.enabledExtensionCount = 1;
            deviceInfo.ppEnabledExtensionNames = &deviceExtension;

            VkDevice device = VK_NULL_HANDLE;
            output.resultCode = createDevice(physicalDevice, &deviceInfo, nullptr, &device);
            if (output.resultCode != VK_SUCCESS || device == VK_NULL_HANDLE) continue;

            VkPhysicalDeviceProperties properties{};
            getPhysicalDeviceProperties(physicalDevice, &properties);
            output.deviceName = properties.deviceName;
            output.apiVersion = VulkanVersion(properties.apiVersion);
            output.logicalDevice = true;
            const std::string normalizedDeviceName = output.deviceName;
            output.hardwareDevice =
                properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU &&
                normalizedDeviceName.find("SwiftShader") == std::string::npos &&
                normalizedDeviceName.find("swiftshader") == std::string::npos;

            const auto destroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(
                getDeviceProcAddr(device, "vkDestroyDevice"));
            if (destroyDevice != nullptr) destroyDevice(device, nullptr);
            break;
        }
    }

    destroyInstance(instance, nullptr);
    dlclose(library);
    return output;
}

struct OpenGlProbeResult {
    bool ready = false;
    int major = 0;
    int minor = 0;
    int eglError = EGL_SUCCESS;
    std::string vendor;
    std::string renderer;
    std::string version;
    bool software = false;
};

struct NnApiDeviceProbe {
    std::string name;
    std::string version;
    int type = -1;
    int64_t featureLevel = 0;

    bool Hardware() const {
        return type == 0 || type == 2 || type == 3;
    }
};

struct NnApiProbeResult {
    bool loader = false;
    bool enumeration = false;
    int resultCode = -1;
    std::vector<NnApiDeviceProbe> devices;

    bool HasHardware() const {
        return std::any_of(devices.begin(), devices.end(), [](const auto& device) {
            return device.Hardware();
        });
    }
};

NnApiProbeResult ProbeNnApi() {
    NnApiProbeResult output;
    void* library = dlopen("libneuralnetworks.so", RTLD_NOW | RTLD_LOCAL);
    if (library == nullptr) return output;
    output.loader = true;

    using Device = void;
    using GetDeviceCount = int (*)(uint32_t*);
    using GetDevice = int (*)(uint32_t, const Device**);
    using GetName = int (*)(const Device*, const char**);
    using GetVersion = int (*)(const Device*, const char**);
    using GetType = int (*)(const Device*, int32_t*);
    using GetFeatureLevel = int (*)(const Device*, int64_t*);

    const auto getDeviceCount = reinterpret_cast<GetDeviceCount>(
        dlsym(library, "ANeuralNetworks_getDeviceCount"));
    const auto getDevice = reinterpret_cast<GetDevice>(
        dlsym(library, "ANeuralNetworks_getDevice"));
    const auto getName = reinterpret_cast<GetName>(
        dlsym(library, "ANeuralNetworksDevice_getName"));
    const auto getVersion = reinterpret_cast<GetVersion>(
        dlsym(library, "ANeuralNetworksDevice_getVersion"));
    const auto getType = reinterpret_cast<GetType>(
        dlsym(library, "ANeuralNetworksDevice_getType"));
    const auto getFeatureLevel = reinterpret_cast<GetFeatureLevel>(
        dlsym(library, "ANeuralNetworksDevice_getFeatureLevel"));
    if (getDeviceCount == nullptr || getDevice == nullptr || getName == nullptr ||
        getVersion == nullptr || getType == nullptr || getFeatureLevel == nullptr) {
        dlclose(library);
        return output;
    }

    uint32_t count = 0;
    output.resultCode = getDeviceCount(&count);
    if (output.resultCode != 0) {
        dlclose(library);
        return output;
    }
    output.enumeration = true;
    for (uint32_t index = 0; index < count; ++index) {
        const Device* device = nullptr;
        if (getDevice(index, &device) != 0 || device == nullptr) continue;
        const char* name = nullptr;
        const char* version = nullptr;
        int32_t type = -1;
        int64_t featureLevel = 0;
        if (getName(device, &name) != 0 || getType(device, &type) != 0 ||
            getFeatureLevel(device, &featureLevel) != 0) {
            continue;
        }
        getVersion(device, &version);
        output.devices.push_back({
            name == nullptr ? "" : name,
            version == nullptr ? "" : version,
            type,
            featureLevel,
        });
    }
    dlclose(library);
    return output;
}

bool TryOpenGlContext(EGLDisplay display, int requestedMajor, OpenGlProbeResult* output) {
    const EGLint renderableType = requestedMajor >= 3
        ? EGL_OPENGL_ES3_BIT_KHR
        : EGL_OPENGL_ES2_BIT;
    const EGLint configAttributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, renderableType,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint configCount = 0;
    if (eglChooseConfig(display, configAttributes, &config, 1, &configCount) != EGL_TRUE ||
        configCount == 0) {
        output->eglError = eglGetError();
        return false;
    }

    const EGLint surfaceAttributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
    if (surface == EGL_NO_SURFACE) {
        output->eglError = eglGetError();
        return false;
    }

    const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, requestedMajor, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    if (context == EGL_NO_CONTEXT) {
        output->eglError = eglGetError();
        eglDestroySurface(display, surface);
        return false;
    }

    if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        output->eglError = eglGetError();
        eglDestroyContext(display, context);
        eglDestroySurface(display, surface);
        return false;
    }

    const auto vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
    const auto renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
    const auto version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
    output->ready = vendor != nullptr && renderer != nullptr && version != nullptr;
    output->major = requestedMajor;
    output->vendor = vendor == nullptr ? "" : vendor;
    output->renderer = renderer == nullptr ? "" : renderer;
    output->version = version == nullptr ? "" : version;
    std::string rendererName = output->renderer;
    std::transform(rendererName.begin(), rendererName.end(), rendererName.begin(), [](unsigned char value) {
        return static_cast<char>(std::tolower(value));
    });
    output->software = rendererName.find("swiftshader") != std::string::npos ||
                       rendererName.find("llvmpipe") != std::string::npos ||
                       rendererName.find("software") != std::string::npos;
    output->ready = output->ready && !output->software;
    output->eglError = output->ready ? EGL_SUCCESS : static_cast<int>(glGetError());

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    return output->ready;
}

OpenGlProbeResult ProbeOpenGl() {
    OpenGlProbeResult output;
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        output.eglError = eglGetError();
        return output;
    }
    EGLint eglMajor = 0;
    EGLint eglMinor = 0;
    if (eglInitialize(display, &eglMajor, &eglMinor) != EGL_TRUE) {
        output.eglError = eglGetError();
        return output;
    }
    output.minor = eglMinor;
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        output.eglError = eglGetError();
        eglTerminate(display);
        return output;
    }

    if (!TryOpenGlContext(display, 3, &output)) {
        output = OpenGlProbeResult{};
        output.minor = eglMinor;
        TryOpenGlContext(display, 2, &output);
    }
    eglTerminate(display);
    return output;
}

std::string BuildResultJson() {
    const VulkanProbeResult vulkan = ProbeVulkan();
    const OpenGlProbeResult openGl = ProbeOpenGl();
    const NnApiProbeResult nnapi = ProbeNnApi();
    const char* preferred = vulkan.Ready() ? "vulkan" : openGl.ready ? "opengl-es" : "none";

    std::ostringstream output;
    output << "{\"schemaVersion\":2"
           << ",\"preferredNativeBackend\":\"" << preferred << "\""
           << ",\"vulkan\":{"
           << "\"ready\":" << (vulkan.Ready() ? "true" : "false")
           << ",\"loader\":" << (vulkan.loader ? "true" : "false")
           << ",\"instance\":" << (vulkan.instance ? "true" : "false")
           << ",\"surfaceExtensions\":" << (vulkan.surfaceExtensions ? "true" : "false")
           << ",\"graphicsQueue\":" << (vulkan.graphicsQueue ? "true" : "false")
           << ",\"swapchainExtension\":" << (vulkan.swapchainExtension ? "true" : "false")
           << ",\"logicalDevice\":" << (vulkan.logicalDevice ? "true" : "false")
           << ",\"hardwareDevice\":" << (vulkan.hardwareDevice ? "true" : "false")
           << ",\"resultCode\":" << vulkan.resultCode
           << ",\"deviceName\":\"" << JsonEscape(vulkan.deviceName.c_str()) << "\""
           << ",\"apiVersion\":\"" << JsonEscape(vulkan.apiVersion.c_str()) << "\"}"
           << ",\"openGlEs\":{"
           << "\"ready\":" << (openGl.ready ? "true" : "false")
           << ",\"major\":" << openGl.major
           << ",\"eglMinor\":" << openGl.minor
           << ",\"eglError\":" << openGl.eglError
           << ",\"software\":" << (openGl.software ? "true" : "false")
           << ",\"vendor\":\"" << JsonEscape(openGl.vendor.c_str()) << "\""
           << ",\"renderer\":\"" << JsonEscape(openGl.renderer.c_str()) << "\""
           << ",\"version\":\"" << JsonEscape(openGl.version.c_str()) << "\"}"
           << ",\"nnapi\":{"
           << "\"loader\":" << (nnapi.loader ? "true" : "false")
           << ",\"enumeration\":" << (nnapi.enumeration ? "true" : "false")
           << ",\"hardwareDevice\":" << (nnapi.HasHardware() ? "true" : "false")
           << ",\"resultCode\":" << nnapi.resultCode
           << ",\"devices\":[";
    for (size_t index = 0; index < nnapi.devices.size(); ++index) {
        if (index > 0) output << ',';
        const auto& device = nnapi.devices[index];
        output << "{\"name\":\"" << JsonEscape(device.name.c_str()) << "\""
               << ",\"version\":\"" << JsonEscape(device.version.c_str()) << "\""
               << ",\"type\":" << device.type
               << ",\"featureLevel\":" << device.featureLevel
               << ",\"hardware\":" << (device.Hardware() ? "true" : "false") << '}';
    }
    output << "]}}";
    return output.str();
}

}

extern "C" JNIEXPORT jstring JNICALL
Java_com_blue_talk2u_GpuBackendProbe_nativeProbe(JNIEnv* environment, jobject) {
    const std::string result = BuildResultJson();
    return environment->NewStringUTF(result.c_str());
}
