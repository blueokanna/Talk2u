#include <jni.h>

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>

#include <CubismDefaultParameterId.hpp>
#include <CubismFramework.hpp>
#include <CubismModelSettingJson.hpp>
#include <Effect/CubismBreath.hpp>
#include <Effect/CubismEyeBlink.hpp>
#include <ICubismAllocator.hpp>
#include <Id/CubismIdManager.hpp>
#include <Math/CubismMatrix44.hpp>
#include <Model/CubismUserModel.hpp>
#include <Motion/ACubismMotion.hpp>
#include <Motion/CubismBreathUpdater.hpp>
#include <Motion/CubismExpressionUpdater.hpp>
#include <Motion/CubismEyeBlinkUpdater.hpp>
#include <Motion/CubismMotion.hpp>
#include <Motion/CubismPhysicsUpdater.hpp>
#include <Motion/CubismPoseUpdater.hpp>
#include <Rendering/OpenGL/CubismOffscreenManager_OpenGLES2.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>
#include <Rendering/OpenGL/CubismShader_OpenGLES2.hpp>
#include <Type/csmMap.hpp>
#include <Type/csmString.hpp>
#include <Type/csmVector.hpp>

#include "live2d_vulkan_interop.h"

#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

namespace Csm = Live2D::Cubism::Framework;
using Csm::ACubismMotion;
using Csm::CubismBreath;
using Csm::CubismFramework;
using Csm::CubismIdHandle;
using Csm::CubismMatrix44;
using Csm::CubismModelSettingJson;
using Csm::CubismMotion;
using Csm::CubismUserModel;
using Csm::csmByte;
using Csm::csmFloat32;
using Csm::csmInt32;
using Csm::csmMap;
using Csm::csmSizeInt;
using Csm::csmString;
using Csm::csmUint32;
using Csm::csmVector;
using Csm::Rendering::CubismOffscreenManager_OpenGLES2;
using Csm::Rendering::CubismRenderer_OpenGLES2;
constexpr char kAssetPrefix[] = "asset:///";
constexpr char kFrameworkShaderPrefix[] = "FrameworkShaders/";
constexpr csmInt32 kPriorityIdle = 1;
constexpr csmInt32 kPriorityForce = 3;

bool IsSoftwareRenderer(const char* renderer) {
    if (renderer == nullptr) return true;
    std::string value(renderer);
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value.find("swiftshader") != std::string::npos ||
           value.find("llvmpipe") != std::string::npos ||
           value.find("softpipe") != std::string::npos ||
           value.find("lavapipe") != std::string::npos ||
           value.find("software") != std::string::npos;
}

void GL_APIENTRY GlDebugMessage(
    GLenum,
    GLenum,
    GLuint,
    GLenum severity,
    GLsizei,
    const GLchar* message,
    const void*) {
    __android_log_print(
        severity == GL_DEBUG_SEVERITY_HIGH_KHR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN,
        "Talk2U.Live2D.GL",
        "%s",
        message == nullptr ? "OpenGL ES debug message is empty" : message);
}

void EnableGlDebugMessages() {
    auto callback = reinterpret_cast<PFNGLDEBUGMESSAGECALLBACKKHRPROC>(
        eglGetProcAddress("glDebugMessageCallbackKHR"));
    if (callback == nullptr) return;
    glEnable(GL_DEBUG_OUTPUT_KHR);
    glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR);
    callback(GlDebugMessage, nullptr);
}

class Allocator final : public Csm::ICubismAllocator {
public:
    void* Allocate(const Csm::csmSizeType size) override {
        return std::malloc(size);
    }

    void Deallocate(void* memory) override {
        std::free(memory);
    }

    void* AllocateAligned(
        const Csm::csmSizeType size,
        const Csm::csmUint32 alignment) override {
        const size_t offset = alignment - 1U + sizeof(void*);
        void* allocation = Allocate(size + offset);
        if (allocation == nullptr) return nullptr;
        size_t address = reinterpret_cast<size_t>(allocation) + sizeof(void*);
        const size_t remainder = address % alignment;
        if (remainder != 0U) address += alignment - remainder;
        reinterpret_cast<void**>(address)[-1] = allocation;
        return reinterpret_cast<void*>(address);
    }

    void DeallocateAligned(void* memory) override {
        if (memory != nullptr) Deallocate(static_cast<void**>(memory)[-1]);
    }
};

Allocator allocator;
CubismFramework::Option frameworkOptions;
std::once_flag frameworkOnce;
AAssetManager* frameworkAssets = nullptr;
std::mutex frameworkLogMutex;
std::string frameworkLog;
std::string frameworkAssetFailure;

void SetFrameworkAssetFailure(const std::string& message) {
    std::lock_guard<std::mutex> lock(frameworkLogMutex);
    frameworkAssetFailure = message;
}

csmByte* LoadFrameworkAsset(const std::string path, csmSizeInt* outSize) {
    if (frameworkAssets == nullptr || outSize == nullptr || path.empty()) {
        SetFrameworkAssetFailure("Rejected Cubism shader path: " + path);
        return nullptr;
    }
    const std::string fileName = path.rfind(kFrameworkShaderPrefix, 0) == 0
        ? path.substr(sizeof(kFrameworkShaderPrefix) - 1U)
        : path;
    if (fileName.empty() || fileName.find_first_of("/\\:") != std::string::npos ||
        fileName.size() < 5U ||
        (fileName.compare(fileName.size() - 5U, 5U, ".vert") != 0 &&
         fileName.compare(fileName.size() - 5U, 5U, ".frag") != 0)) {
        SetFrameworkAssetFailure("Rejected Cubism shader asset name: " + fileName);
        return nullptr;
    }
    std::unique_ptr<AAsset, decltype(&AAsset_close)> asset(
        AAssetManager_open(frameworkAssets, fileName.c_str(), AASSET_MODE_BUFFER),
        AAsset_close);
    if (!asset) {
        SetFrameworkAssetFailure("Missing Cubism shader asset: " + fileName);
        return nullptr;
    }
    const off64_t length = AAsset_getLength64(asset.get());
    if (length <= 0 || length > static_cast<off64_t>(INT32_MAX)) {
        SetFrameworkAssetFailure("Invalid Cubism shader asset size: " + fileName);
        return nullptr;
    }
    auto* bytes = new csmByte[static_cast<size_t>(length)];
    size_t offset = 0;
    while (offset < static_cast<size_t>(length)) {
        const int count = AAsset_read(
            asset.get(), bytes + offset, static_cast<size_t>(length) - offset);
        if (count <= 0) {
            delete[] bytes;
            SetFrameworkAssetFailure("Unable to read Cubism shader asset: " + fileName);
            return nullptr;
        }
        offset += static_cast<size_t>(count);
    }
    *outSize = static_cast<csmSizeInt>(length);
    return bytes;
}

void ReleaseFrameworkAsset(csmByte* bytes) {
    delete[] bytes;
}

void LogCubism(const char* message) {
    if (message == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(frameworkLogMutex);
        frameworkLog = message;
    }
    __android_log_write(ANDROID_LOG_WARN, "Talk2U.Live2D", message);
}

std::string LastFrameworkLog() {
    std::lock_guard<std::mutex> lock(frameworkLogMutex);
    if (frameworkAssetFailure.empty()) return frameworkLog;
    if (frameworkLog.empty()) return frameworkAssetFailure;
    return frameworkLog + "; " + frameworkAssetFailure;
}

void EnsureFramework(AAssetManager* assets) {
    if (assets == nullptr) throw std::runtime_error("Android AssetManager is unavailable");
    std::call_once(frameworkOnce, [assets] {
        frameworkAssets = assets;
        frameworkOptions.LogFunction = LogCubism;
        frameworkOptions.LoggingLevel = CubismFramework::Option::LogLevel_Warning;
        frameworkOptions.LoadFileFunction = LoadFrameworkAsset;
        frameworkOptions.ReleaseBytesFunction = ReleaseFrameworkAsset;
        if (!CubismFramework::StartUp(&allocator, &frameworkOptions)) {
            throw std::runtime_error("Cubism Framework startup failed");
        }
        CubismFramework::Initialize();
        if (!CubismFramework::IsInitialized()) {
            throw std::runtime_error("Cubism Framework initialization failed");
        }
    });
}

std::string JStringToUtf8(JNIEnv* environment, jstring value) {
    if (value == nullptr) return {};
    jclass stringClass = environment->FindClass("java/lang/String");
    jmethodID getBytes = environment->GetMethodID(
        stringClass, "getBytes", "(Ljava/lang/String;)[B");
    jstring charset = environment->NewStringUTF("UTF-8");
    auto bytes = static_cast<jbyteArray>(
        environment->CallObjectMethod(value, getBytes, charset));
    environment->DeleteLocalRef(charset);
    environment->DeleteLocalRef(stringClass);
    if (bytes == nullptr) return {};
    const jsize length = environment->GetArrayLength(bytes);
    std::string output(static_cast<size_t>(length), '\0');
    environment->GetByteArrayRegion(
        bytes, 0, length, reinterpret_cast<jbyte*>(output.data()));
    environment->DeleteLocalRef(bytes);
    return output;
}

jstring Utf8ToJString(JNIEnv* environment, const std::string& value) {
    jbyteArray bytes = environment->NewByteArray(static_cast<jsize>(value.size()));
    environment->SetByteArrayRegion(
        bytes,
        0,
        static_cast<jsize>(value.size()),
        reinterpret_cast<const jbyte*>(value.data()));
    jclass stringClass = environment->FindClass("java/lang/String");
    jmethodID constructor = environment->GetMethodID(
        stringClass, "<init>", "([BLjava/lang/String;)V");
    jstring charset = environment->NewStringUTF("UTF-8");
    auto output = static_cast<jstring>(
        environment->NewObject(stringClass, constructor, bytes, charset));
    environment->DeleteLocalRef(charset);
    environment->DeleteLocalRef(stringClass);
    environment->DeleteLocalRef(bytes);
    return output;
}

void Throw(JNIEnv* environment, const std::string& message) {
    jclass type = environment->FindClass("java/lang/IllegalStateException");
    if (type != nullptr) environment->ThrowNew(type, message.c_str());
}

std::string JsonEscape(const char* raw) {
    const std::string value = raw == nullptr ? "" : raw;
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
            case '"': output << "\\\""; break;
            case '\\': output << "\\\\"; break;
            case '\b': output << "\\b"; break;
            case '\f': output << "\\f"; break;
            case '\n': output << "\\n"; break;
            case '\r': output << "\\r"; break;
            case '\t': output << "\\t"; break;
            default:
                if (character < 0x20U) {
                    constexpr char digits[] = "0123456789abcdef";
                    output << "\\u00" << digits[(character >> 4U) & 0x0fU]
                           << digits[character & 0x0fU];
                } else {
                    output << character;
                }
        }
    }
    return output.str();
}

bool IsSafeRelativePath(const std::string& value) {
    if (value.empty() || value.front() == '/' || value.front() == '\\' ||
        value.find(':') != std::string::npos || value.find('\0') != std::string::npos) {
        return false;
    }
    size_t start = 0;
    while (start <= value.size()) {
        const size_t end = value.find_first_of("/\\", start);
        const std::string part = value.substr(start, end - start);
        if (part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}

class ModelSource {
public:
    ModelSource(AAssetManager* assets, std::string modelPath)
        : assets_(assets), asset_(modelPath.rfind(kAssetPrefix, 0) == 0) {
        if (asset_) modelPath.erase(0, sizeof(kAssetPrefix) - 1U);
        if (modelPath.empty()) throw std::invalid_argument("Live2D model path is empty");
        const size_t separator = modelPath.find_last_of("/\\");
        root_ = separator == std::string::npos ? "" : modelPath.substr(0, separator + 1U);
        setting_ = separator == std::string::npos ? modelPath : modelPath.substr(separator + 1U);
        if (asset_) {
            if (!IsSafeRelativePath(modelPath)) {
                throw std::invalid_argument("Live2D asset path is unsafe");
            }
            root_ = "flutter_assets/" + root_;
        }
    }

    std::vector<csmByte> ReadSetting() const {
        return Read(setting_);
    }

    std::vector<csmByte> Read(const std::string& relative) const {
        if (!IsSafeRelativePath(relative)) {
            throw std::invalid_argument("Live2D model contains an unsafe relative path");
        }
        const std::string path = root_ + relative;
        if (asset_) return ReadAsset(path);
        return ReadFile(path);
    }

private:
    std::vector<csmByte> ReadAsset(const std::string& path) const {
        if (assets_ == nullptr) throw std::runtime_error("Android AssetManager is unavailable");
        std::unique_ptr<AAsset, decltype(&AAsset_close)> asset(
            AAssetManager_open(assets_, path.c_str(), AASSET_MODE_BUFFER),
            AAsset_close);
        if (!asset) throw std::runtime_error("Live2D asset is missing: " + path);
        const off64_t length = AAsset_getLength64(asset.get());
        if (length <= 0 || length > static_cast<off64_t>(UINT32_MAX)) {
            throw std::runtime_error("Live2D asset size is invalid: " + path);
        }
        std::vector<csmByte> bytes(static_cast<size_t>(length));
        size_t offset = 0;
        while (offset < bytes.size()) {
            const int count = AAsset_read(
                asset.get(), bytes.data() + offset, bytes.size() - offset);
            if (count <= 0) throw std::runtime_error("Live2D asset read failed: " + path);
            offset += static_cast<size_t>(count);
        }
        return bytes;
    }

    static std::vector<csmByte> ReadFile(const std::string& path) {
        std::ifstream input(path, std::ios::binary | std::ios::ate);
        if (!input) throw std::runtime_error("Live2D file is missing: " + path);
        const std::streamsize length = input.tellg();
        if (length <= 0 || length > static_cast<std::streamsize>(UINT32_MAX)) {
            throw std::runtime_error("Live2D file size is invalid: " + path);
        }
        input.seekg(0, std::ios::beg);
        std::vector<csmByte> bytes(static_cast<size_t>(length));
        if (!input.read(reinterpret_cast<char*>(bytes.data()), length)) {
            throw std::runtime_error("Live2D file read failed: " + path);
        }
        return bytes;
    }

    AAssetManager* assets_;
    bool asset_;
    std::string root_;
    std::string setting_;
};

class NativeModel final : public CubismUserModel {
    struct DecodedTexture {
        csmUint32 index;
        int width;
        int height;
        std::string fileName;
        std::vector<unsigned char> pixels;
    };

public:
    explicit NativeModel(ModelSource source) : source_(std::move(source)) {
        LoadContent();
        DecodeTextures();
    }

    ~NativeModel() override {
        ReleaseGraphics();
        for (auto& item : motions_) ACubismMotion::Delete(item.second);
        for (auto& item : expressions_) ACubismMotion::Delete(item.second);
    }

    void CreateGraphics(csmUint32 width, csmUint32 height) {
        ReleaseGraphics();
        CreateRenderer(std::max<csmUint32>(1U, width), std::max<csmUint32>(1U, height));
        auto* renderer = GetRenderer<CubismRenderer_OpenGLES2>();
        if (renderer == nullptr) throw std::runtime_error("Cubism OpenGL ES renderer creation failed");
        renderer->IsPremultipliedAlpha(true);
        GLint maximumTextureSize = 0;
        glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximumTextureSize);
        for (const auto& decoded : decodedTextures_) {
            if (decoded.width > maximumTextureSize || decoded.height > maximumTextureSize) {
                throw std::runtime_error(
                    "Live2D texture exceeds the GPU limit: " + decoded.fileName);
            }
            while (glGetError() != GL_NO_ERROR) {}
            GLuint texture = 0;
            glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_2D, texture);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
            glTexImage2D(
                GL_TEXTURE_2D,
                0,
                GL_RGBA,
                decoded.width,
                decoded.height,
                0,
                GL_RGBA,
                GL_UNSIGNED_BYTE,
                decoded.pixels.data());
            glGenerateMipmap(GL_TEXTURE_2D);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            const GLenum error = glGetError();
            if (texture == 0 || error != GL_NO_ERROR) {
                if (texture != 0) glDeleteTextures(1, &texture);
                throw std::runtime_error("Live2D texture upload failed: " + decoded.fileName);
            }
            textures_.push_back(texture);
            renderer->BindTexture(decoded.index, texture);
        }
        glBindTexture(GL_TEXTURE_2D, 0);
    }

    void ReleaseGraphics() {
        if (!textures_.empty()) {
            glDeleteTextures(static_cast<GLsizei>(textures_.size()), textures_.data());
            textures_.clear();
        }
        DeleteRenderer();
    }

    void Resize(csmUint32 width, csmUint32 height) {
        surfaceWidth_ = std::max<csmUint32>(1U, width);
        surfaceHeight_ = std::max<csmUint32>(1U, height);
        SetRenderTargetSize(surfaceWidth_, surfaceHeight_);
    }

    void Update(csmFloat32 deltaTime) {
        _motionUpdated = false;
        _model->LoadParameters();
        if (_motionManager->IsFinished()) {
            StartMotion("Idle", 0, kPriorityIdle);
        } else {
            _motionUpdated = _motionManager->UpdateMotion(_model, deltaTime);
        }
        _model->SaveParameters();
        _updateScheduler.OnLateUpdate(_model, deltaTime);
        const csmFloat32 mouth = speaking_ ? mouth_ : 0.0F;
        for (csmUint32 index = 0; index < lipSyncIds_.GetSize(); ++index) {
            _model->SetParameterValue(lipSyncIds_[index], mouth);
        }
        _model->Update();
    }

    void Draw() {
        if (surfaceWidth_ == 0 || surfaceHeight_ == 0) return;
        CubismMatrix44 projection;
        const float displayRatio = static_cast<float>(surfaceHeight_) /
            static_cast<float>(surfaceWidth_);
        const float canvasRatio = _model->GetCanvasHeight() / _model->GetCanvasWidth();
        if (canvasRatio < displayRatio) {
            _modelMatrix->SetWidth(2.0F);
            projection.Scale(1.0F, static_cast<float>(surfaceWidth_) /
                static_cast<float>(surfaceHeight_));
        } else {
            _modelMatrix->SetHeight(2.0F);
            projection.Scale(static_cast<float>(surfaceHeight_) /
                static_cast<float>(surfaceWidth_), 1.0F);
        }
        projection.MultiplyByMatrix(_modelMatrix);
        auto* renderer = GetRenderer<CubismRenderer_OpenGLES2>();
        renderer->SetMvpMatrix(&projection);
        renderer->DrawModel();
    }

    bool StartMotion(const std::string& group, csmInt32 index, csmInt32 priority) {
        const auto item = motions_.find(MotionKey(group, index));
        if (item == motions_.end()) return false;
        if (priority == kPriorityForce) {
            _motionManager->SetReservePriority(priority);
        } else if (!_motionManager->ReserveMotion(priority)) {
            return false;
        }
        _motionManager->StartMotionPriority(item->second, false, priority);
        return true;
    }

    bool SetExpression(const std::string& name) {
        const auto item = expressions_.find(name);
        if (item == expressions_.end()) return false;
        _expressionManager->StartMotion(item->second, false);
        return true;
    }

    void ResetExpression() {
        _expressionManager->StopAllMotions();
    }

    void SetMouth(float value) {
        mouth_ = std::clamp(value, 0.0F, 1.0F);
    }

    void SetSpeaking(bool value) {
        speaking_ = value;
        if (!value) mouth_ = 0.0F;
    }

    std::string LipSyncJson() const {
        std::ostringstream output;
        output << '[';
        for (csmUint32 index = 0; index < lipSyncIds_.GetSize(); ++index) {
            if (index != 0) output << ',';
            output << '"' << JsonEscape(lipSyncIds_[index]->GetString().GetRawString()) << '"';
        }
        output << ']';
        return output.str();
    }

private:
    static std::string MotionKey(const std::string& group, csmInt32 index) {
        return group + '\x1f' + std::to_string(index);
    }

    void LoadContent() {
        const std::vector<csmByte> settingBytes = source_.ReadSetting();
        setting_ = std::make_unique<CubismModelSettingJson>(
            settingBytes.data(), static_cast<csmSizeInt>(settingBytes.size()));
        const char* modelFile = setting_->GetModelFileName();
        if (modelFile == nullptr || *modelFile == '\0') {
            throw std::runtime_error("Live2D model3.json has no Moc file");
        }
        const std::vector<csmByte> moc = source_.Read(modelFile);
        LoadModel(moc.data(), static_cast<csmSizeInt>(moc.size()), true);
        if (_model == nullptr || _modelMatrix == nullptr) {
            throw std::runtime_error("Cubism Core rejected the Moc file");
        }

        for (csmInt32 index = 0; index < setting_->GetExpressionCount(); ++index) {
            const char* name = setting_->GetExpressionName(index);
            const char* file = setting_->GetExpressionFileName(index);
            if (name == nullptr || file == nullptr || *file == '\0') continue;
            const std::vector<csmByte> bytes = source_.Read(file);
            ACubismMotion* expression = LoadExpression(
                bytes.data(), static_cast<csmSizeInt>(bytes.size()), name);
            if (expression != nullptr) expressions_.emplace(name, expression);
        }
        if (!expressions_.empty()) {
            _updateScheduler.AddUpdatableList(
                CSM_NEW Csm::CubismExpressionUpdater(*_expressionManager));
        }

        const char* physics = setting_->GetPhysicsFileName();
        if (physics != nullptr && *physics != '\0') {
            const std::vector<csmByte> bytes = source_.Read(physics);
            LoadPhysics(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
            if (_physics != nullptr) {
                _updateScheduler.AddUpdatableList(CSM_NEW Csm::CubismPhysicsUpdater(*_physics));
            }
        }

        const char* pose = setting_->GetPoseFileName();
        if (pose != nullptr && *pose != '\0') {
            const std::vector<csmByte> bytes = source_.Read(pose);
            LoadPose(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
            if (_pose != nullptr) {
                _updateScheduler.AddUpdatableList(CSM_NEW Csm::CubismPoseUpdater(*_pose));
            }
        }

        if (setting_->GetEyeBlinkParameterCount() > 0) {
            _eyeBlink = Csm::CubismEyeBlink::Create(setting_.get());
            _updateScheduler.AddUpdatableList(
                CSM_NEW Csm::CubismEyeBlinkUpdater(_motionUpdated, *_eyeBlink));
        }

        _breath = CubismBreath::Create();
        csmVector<CubismBreath::BreathParameterData> breath;
        auto* ids = CubismFramework::GetIdManager();
        breath.PushBack({ids->GetId(Csm::DefaultParameterId::ParamAngleX), 0.0F, 15.0F, 6.5345F, 0.5F});
        breath.PushBack({ids->GetId(Csm::DefaultParameterId::ParamAngleY), 0.0F, 8.0F, 3.5345F, 0.5F});
        breath.PushBack({ids->GetId(Csm::DefaultParameterId::ParamAngleZ), 0.0F, 10.0F, 5.5345F, 0.5F});
        breath.PushBack({ids->GetId(Csm::DefaultParameterId::ParamBodyAngleX), 0.0F, 4.0F, 15.5345F, 0.5F});
        breath.PushBack({ids->GetId(Csm::DefaultParameterId::ParamBreath), 0.5F, 0.5F, 3.2345F, 0.5F});
        _breath->SetParameters(breath);
        _updateScheduler.AddUpdatableList(CSM_NEW Csm::CubismBreathUpdater(*_breath));

        const char* userData = setting_->GetUserDataFile();
        if (userData != nullptr && *userData != '\0') {
            const std::vector<csmByte> bytes = source_.Read(userData);
            LoadUserData(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
        }

        for (csmInt32 index = 0; index < setting_->GetEyeBlinkParameterCount(); ++index) {
            eyeBlinkIds_.PushBack(setting_->GetEyeBlinkParameterId(index));
        }
        for (csmInt32 index = 0; index < setting_->GetLipSyncParameterCount(); ++index) {
            lipSyncIds_.PushBack(setting_->GetLipSyncParameterId(index));
        }

        csmMap<csmString, csmFloat32> layout;
        setting_->GetLayoutMap(layout);
        _modelMatrix->SetupFromLayout(layout);
        _model->SaveParameters();

        for (csmInt32 groupIndex = 0; groupIndex < setting_->GetMotionGroupCount(); ++groupIndex) {
            const char* group = setting_->GetMotionGroupName(groupIndex);
            if (group == nullptr) continue;
            for (csmInt32 index = 0; index < setting_->GetMotionCount(group); ++index) {
                const char* file = setting_->GetMotionFileName(group, index);
                if (file == nullptr || *file == '\0') continue;
                const std::vector<csmByte> bytes = source_.Read(file);
                CubismMotion* motion = static_cast<CubismMotion*>(LoadMotion(
                    bytes.data(),
                    static_cast<csmSizeInt>(bytes.size()),
                    nullptr,
                    nullptr,
                    nullptr,
                    setting_.get(),
                    group,
                    index,
                    true));
                if (motion == nullptr) continue;
                motion->SetEffectIds(eyeBlinkIds_, lipSyncIds_);
                motions_.emplace(MotionKey(group, index), motion);
            }
        }
        _motionManager->StopAllMotions();
        _updateScheduler.SortUpdatableList();
        _initialized = true;
    }

    void DecodeTextures() {
        decodedTextures_.reserve(static_cast<size_t>(setting_->GetTextureCount()));
        for (csmInt32 index = 0; index < setting_->GetTextureCount(); ++index) {
            const char* fileName = setting_->GetTextureFileName(index);
            if (fileName == nullptr || *fileName == '\0') continue;
            const std::vector<csmByte> encoded = source_.Read(fileName);
            if (encoded.size() > static_cast<size_t>(INT_MAX)) {
                throw std::runtime_error("Live2D PNG is too large: " + std::string(fileName));
            }
            int width = 0;
            int height = 0;
            int channels = 0;
            unsigned char* decoded = stbi_load_from_memory(
                encoded.data(),
                static_cast<int>(encoded.size()),
                &width,
                &height,
                &channels,
                STBI_rgb_alpha);
            if (decoded == nullptr) {
                throw std::runtime_error("Live2D PNG decode failed: " + std::string(fileName));
            }
            if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
                stbi_image_free(decoded);
                throw std::runtime_error(
                    "Live2D texture exceeds 4096x4096: " + std::string(fileName));
            }
            const size_t byteCount = static_cast<size_t>(width) *
                static_cast<size_t>(height) * 4U;
            std::vector<unsigned char> pixels(decoded, decoded + byteCount);
            stbi_image_free(decoded);
            for (size_t offset = 0; offset < pixels.size(); offset += 4U) {
                const unsigned int alpha = pixels[offset + 3U];
                pixels[offset] = static_cast<unsigned char>(
                    (pixels[offset] * alpha + 127U) / 255U);
                pixels[offset + 1U] = static_cast<unsigned char>(
                    (pixels[offset + 1U] * alpha + 127U) / 255U);
                pixels[offset + 2U] = static_cast<unsigned char>(
                    (pixels[offset + 2U] * alpha + 127U) / 255U);
            }
            decodedTextures_.push_back({
                static_cast<csmUint32>(index), width, height, fileName, std::move(pixels)});
        }
    }

    ModelSource source_;
    std::unique_ptr<CubismModelSettingJson> setting_;
    std::unordered_map<std::string, ACubismMotion*> motions_;
    std::unordered_map<std::string, ACubismMotion*> expressions_;
    std::vector<DecodedTexture> decodedTextures_;
    csmVector<CubismIdHandle> eyeBlinkIds_;
    csmVector<CubismIdHandle> lipSyncIds_;
    std::vector<GLuint> textures_;
    csmUint32 surfaceWidth_ = 1;
    csmUint32 surfaceHeight_ = 1;
    csmFloat32 mouth_ = 0.0F;
    bool speaking_ = false;
    bool _motionUpdated = false;
};

class Session {
public:
    Session(AAssetManager* assets, std::string modelPath, uint32_t backgroundColor)
        : assets_(assets),
          source_(assets, std::move(modelPath)),
          clearRed_(static_cast<float>((backgroundColor >> 16U) & 0xffU) / 255.0F),
          clearGreen_(static_cast<float>((backgroundColor >> 8U) & 0xffU) / 255.0F),
          clearBlue_(static_cast<float>(backgroundColor & 0xffU) / 255.0F) {}

    ~Session() {
        try {
            SurfaceDestroyed();
        } catch (...) {
        }
    }

    void Prepare() {
        EnsureFramework(assets_);
        if (!model_) model_ = std::make_unique<NativeModel>(source_);
    }

    void SurfaceCreated(JNIEnv* environment, jobject surface, csmUint32 width, csmUint32 height) {
        ready_ = false;
        frameCount_ = 0;
        consecutiveGlErrors_ = 0;
        width_ = std::max<csmUint32>(1U, width);
        height_ = std::max<csmUint32>(1U, height);
        interop_.Initialize(environment, surface, width_, height_);
        interop_.MakeCurrent();
        const char* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
        const char* vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
        const char* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
        if (IsSoftwareRenderer(renderer) || version == nullptr) {
            throw std::runtime_error("OpenGL ES hardware context is unavailable");
        }
        glRenderer_ = renderer;
        glVendor_ = vendor == nullptr ? "" : vendor;
        glVersion_ = version;
        EnableGlDebugMessages();
        if (!model_) throw std::runtime_error("Live2D model preparation is incomplete");
        model_->CreateGraphics(width_, height_);
        model_->Resize(width_, height_);
        graphicsActive_ = true;
        InitializeGpuTimers();
        glClearColor(clearRed_, clearGreen_, clearBlue_, 1.0F);
        glClear(GL_COLOR_BUFFER_BIT);
        ready_ = true;
        lastFrame_ = std::chrono::steady_clock::now();
    }

    bool ReleaseGraphics() {
        if (!graphicsActive_) return false;
        ready_ = false;
        ReleaseGpuTimers();
        model_->ReleaseGraphics();
        graphicsActive_ = false;
        return true;
    }

    void ReleaseGlobalGraphics() {
        CubismOffscreenManager_OpenGLES2::ReleaseInstance();
        Csm::Rendering::CubismShader_OpenGLES2::GetInstance()
            ->ReleaseInvalidShaderProgram();
        Csm::Rendering::CubismRenderer::StaticRelease();
    }

    bool SurfaceDestroyed(bool releaseGlobalGraphics = false) {
        ready_ = false;
        bool released = false;
        if (interop_.ready()) {
            interop_.MakeCurrent();
            released = ReleaseGraphics();
            if (released && releaseGlobalGraphics) {
                ReleaseGlobalGraphics();
            }
            interop_.Destroy();
        } else {
            released = graphicsActive_;
            graphicsActive_ = false;
        }
        return released;
    }

    void SurfaceChanged(csmUint32 width, csmUint32 height) {
        if (!interop_.ready()) throw std::runtime_error("Vulkan presentation surface is unavailable");
        const csmUint32 nextWidth = std::max<csmUint32>(1U, width);
        const csmUint32 nextHeight = std::max<csmUint32>(1U, height);
        if (nextWidth != width_ || nextHeight != height_) {
            interop_.MakeCurrent();
            if (ReleaseGraphics()) ReleaseGlobalGraphics();
            interop_.Resize(nextWidth, nextHeight);
        }
        width_ = nextWidth;
        height_ = nextHeight;
        interop_.MakeCurrent();
        if (model_ && !graphicsActive_) {
            graphicsActive_ = true;
            try {
                model_->CreateGraphics(width_, height_);
                InitializeGpuTimers();
            } catch (...) {
                ReleaseGraphics();
                throw;
            }
        }
        if (model_) model_->Resize(width_, height_);
        ready_ = graphicsActive_;
        glClearColor(clearRed_, clearGreen_, clearBlue_, 1.0F);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    bool DrawFrame() {
        if (!ready_ || !model_) return false;
        interop_.BeginFrame();
        while (glGetError() != GL_NO_ERROR) {}
        PollGpuTimers();
        BeginGpuTimer();
        GLenum frameError = GL_NO_ERROR;
        const char* errorStage = "none";
        const auto captureError = [&](const char* stage) {
            const GLenum error = glGetError();
            if (frameError == GL_NO_ERROR && error != GL_NO_ERROR) {
                frameError = error;
                errorStage = stage;
            }
        };
        const auto now = std::chrono::steady_clock::now();
        const float delta = std::clamp(
            std::chrono::duration<float>(now - lastFrame_).count(),
            1.0F / 240.0F,
            0.1F);
        lastFrame_ = now;
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glClearColor(clearRed_, clearGreen_, clearBlue_, 1.0F);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        captureError("frame setup");
        model_->Update(delta);
        auto* offscreenManager = CubismOffscreenManager_OpenGLES2::GetInstance();
        offscreenManager->BeginFrameProcess();
        captureError("offscreen begin");
        model_->Draw();
        captureError("model draw");
        offscreenManager->EndFrameProcess();
        captureError("offscreen end");
        offscreenManager->ReleaseStaleRenderTextures();
        captureError("offscreen release");
        EndGpuTimer();
        // Always submit the frame after BeginFrame() resets the fence. Returning
        // early here would leave it unsignaled and deadlock the next frame.
        interop_.EndFrame();
        if (frameError != GL_NO_ERROR) {
            ++consecutiveGlErrors_;
            if (consecutiveGlErrors_ < 3U) return false;
            std::ostringstream message;
            message << "Cubism OpenGL ES frame failed at " << errorStage
                    << ": 0x" << std::hex << frameError;
            const std::string frameworkLog = LastFrameworkLog();
            if (!frameworkLog.empty()) message << "; " << frameworkLog;
            throw std::runtime_error(message.str());
        }
        consecutiveGlErrors_ = 0;
        ++frameCount_;
        return frameCount_ == 1U;
    }

    void SetMouth(float value) {
        if (model_) model_->SetMouth(value);
    }

    void SetSpeaking(bool value) {
        if (model_) model_->SetSpeaking(value);
    }

    void Motion(const std::string& group, csmInt32 index) {
        if (!model_ || !model_->StartMotion(group, index, kPriorityForce)) {
            throw std::invalid_argument("Live2D motion does not exist");
        }
    }

    void Expression(const std::string& name) {
        if (!model_ || !model_->SetExpression(name)) {
            throw std::invalid_argument("Live2D expression does not exist");
        }
    }

    void ResetExpression() {
        if (model_) model_->ResetExpression();
    }

    std::string Diagnostics() const {
        const uint32_t core = Live2D::Cubism::Core::csmGetVersion();
        const uint32_t major = (core & 0xff000000U) >> 24U;
        const uint32_t minor = (core & 0x00ff0000U) >> 16U;
        const uint32_t patch = core & 0x0000ffffU;
        std::ostringstream output;
        output << "{\"type\":\"ready\",\"modelVersion\":3,"
               << "\"frameworkVersion\":\"Cubism SDK for Native 5 R.5\","
               << "\"coreVersion\":{\"major\":" << major
               << ",\"minor\":" << minor << ",\"patch\":" << patch << "},"
               << "\"renderer\":{\"api\":\"OpenGL ES + Vulkan\","
               << "\"backend\":\"Cubism OpenGL ES -> AHardwareBuffer -> Vulkan\"," 
               << "\"renderer\":\"" << JsonEscape(glRenderer_.c_str()) << "\","
               << "\"vendor\":\"" << JsonEscape(glVendor_.c_str()) << "\","
               << "\"version\":\"" << JsonEscape(glVersion_.c_str()) << "\","
               << "\"gpuTiming\":" << GpuTimingDiagnostics() << ','
               << "\"platform\":{\"vulkanInterop\":" << interop_.Diagnostics() << "}},"
               << "\"rendererPolicy\":{\"actualBackend\":"
               << "\"Cubism OpenGL ES -> AHardwareBuffer -> Vulkan\"," 
               << "\"hardwareRequired\":true,\"presentationBackend\":\"Vulkan swapchain\"},"
               << "\"frameCount\":" << frameCount_ << ','
               << "\"lipSyncIds\":" << (model_ ? model_->LipSyncJson() : "[]") << ','
               << "\"cueCoverage\":[\"neutral\",\"greeting\",\"wave\",\"nod\","
               << "\"hug\",\"talking\",\"talkingSoft\",\"emphasis\",\"thinking\","
               << "\"dramatic\",\"happy\",\"sad\",\"angry\",\"shy\",\"surprise\"],"
               << "\"naturalCapabilities\":{\"eyeBlink\":true,\"breath\":true,"
               << "\"physics\":true,\"pose\":true,\"lipSync\":true}}";
        return output.str();
    }

private:
    void InitializeGpuTimers() {
        ReleaseGpuTimers();
        const char* extensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        if (extensions == nullptr || std::strstr(extensions, "GL_EXT_disjoint_timer_query") == nullptr) {
            return;
        }
        genQueries_ = reinterpret_cast<PFNGLGENQUERIESEXTPROC>(
            eglGetProcAddress("glGenQueriesEXT"));
        deleteQueries_ = reinterpret_cast<PFNGLDELETEQUERIESEXTPROC>(
            eglGetProcAddress("glDeleteQueriesEXT"));
        beginQuery_ = reinterpret_cast<PFNGLBEGINQUERYEXTPROC>(
            eglGetProcAddress("glBeginQueryEXT"));
        endQuery_ = reinterpret_cast<PFNGLENDQUERYEXTPROC>(
            eglGetProcAddress("glEndQueryEXT"));
        getQueryObjectUiv_ = reinterpret_cast<PFNGLGETQUERYOBJECTUIVEXTPROC>(
            eglGetProcAddress("glGetQueryObjectuivEXT"));
        getQueryObjectUi64v_ = reinterpret_cast<PFNGLGETQUERYOBJECTUI64VEXTPROC>(
            eglGetProcAddress("glGetQueryObjectui64vEXT"));
        if (genQueries_ == nullptr || deleteQueries_ == nullptr || beginQuery_ == nullptr ||
            endQuery_ == nullptr || getQueryObjectUiv_ == nullptr || getQueryObjectUi64v_ == nullptr) {
            return;
        }
        genQueries_(static_cast<GLsizei>(gpuQueries_.size()), gpuQueries_.data());
        gpuTimerSupported_ = std::all_of(
            gpuQueries_.begin(), gpuQueries_.end(), [](GLuint query) { return query != 0; });
        gpuWindowStarted_ = std::chrono::steady_clock::now();
        gpuWindowNanos_ = 0;
        gpuTimerPercent_ = 0.0;
        gpuTimerHasSample_ = false;
        gpuQueryPending_.fill(false);
    }

    void ReleaseGpuTimers() {
        if (gpuTimerActive_ && endQuery_ != nullptr) endQuery_(GL_TIME_ELAPSED_EXT);
        gpuTimerActive_ = false;
        if (deleteQueries_ != nullptr && std::any_of(
                gpuQueries_.begin(), gpuQueries_.end(), [](GLuint query) { return query != 0; })) {
            deleteQueries_(static_cast<GLsizei>(gpuQueries_.size()), gpuQueries_.data());
        }
        gpuQueries_.fill(0);
        gpuQueryPending_.fill(false);
        gpuTimerSupported_ = false;
    }

    void PollGpuTimers() {
        if (!gpuTimerSupported_) return;
        GLint disjoint = GL_FALSE;
        glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
        if (disjoint == GL_TRUE) {
            gpuWindowNanos_ = 0;
            gpuWindowStarted_ = std::chrono::steady_clock::now();
        }
        for (size_t index = 0; index < gpuQueries_.size(); ++index) {
            if (!gpuQueryPending_[index]) continue;
            GLuint available = GL_FALSE;
            getQueryObjectUiv_(gpuQueries_[index], GL_QUERY_RESULT_AVAILABLE_EXT, &available);
            if (available != GL_TRUE) continue;
            GLuint64 elapsed = 0;
            getQueryObjectUi64v_(gpuQueries_[index], GL_QUERY_RESULT_EXT, &elapsed);
            gpuQueryPending_[index] = false;
            if (disjoint != GL_TRUE) gpuWindowNanos_ += elapsed;
        }
        const auto now = std::chrono::steady_clock::now();
        const auto wallNanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
            now - gpuWindowStarted_).count();
        if (wallNanos >= 1'000'000'000LL) {
            gpuTimerPercent_ = std::clamp(
                static_cast<double>(gpuWindowNanos_) * 100.0 / static_cast<double>(wallNanos),
                0.0, 100.0);
            gpuTimerHasSample_ = disjoint != GL_TRUE;
            gpuWindowNanos_ = 0;
            gpuWindowStarted_ = now;
        }
    }

    void BeginGpuTimer() {
        if (!gpuTimerSupported_ || gpuTimerActive_) return;
        for (size_t offset = 0; offset < gpuQueries_.size(); ++offset) {
            const size_t index = (gpuQueryCursor_ + offset) % gpuQueries_.size();
            if (gpuQueryPending_[index]) continue;
            beginQuery_(GL_TIME_ELAPSED_EXT, gpuQueries_[index]);
            gpuTimerActive_ = true;
            gpuActiveQuery_ = index;
            gpuQueryCursor_ = (index + 1) % gpuQueries_.size();
            return;
        }
    }

    void EndGpuTimer() {
        if (!gpuTimerActive_) return;
        endQuery_(GL_TIME_ELAPSED_EXT);
        gpuQueryPending_[gpuActiveQuery_] = true;
        gpuTimerActive_ = false;
    }

    std::string GpuTimingDiagnostics() const {
        std::ostringstream output;
        output << "{\"available\":" << (gpuTimerHasSample_ ? "true" : "false")
               << ",\"scope\":\"Live2D renderer\","
               << "\"source\":\"GL_EXT_disjoint_timer_query\"";
        if (gpuTimerHasSample_) output << ",\"percent\":" << gpuTimerPercent_;
        output << '}';
        return output.str();
    }

    AAssetManager* assets_;
    ModelSource source_;
    std::unique_ptr<NativeModel> model_;
    csmUint32 width_ = 1;
    csmUint32 height_ = 1;
    bool ready_ = false;
    bool graphicsActive_ = false;
    uint64_t frameCount_ = 0;
    uint32_t consecutiveGlErrors_ = 0;
    std::array<GLuint, 4> gpuQueries_{};
    std::array<bool, 4> gpuQueryPending_{};
    size_t gpuQueryCursor_ = 0;
    size_t gpuActiveQuery_ = 0;
    bool gpuTimerSupported_ = false;
    bool gpuTimerActive_ = false;
    bool gpuTimerHasSample_ = false;
    uint64_t gpuWindowNanos_ = 0;
    double gpuTimerPercent_ = 0.0;
    std::chrono::steady_clock::time_point gpuWindowStarted_;
    PFNGLGENQUERIESEXTPROC genQueries_ = nullptr;
    PFNGLDELETEQUERIESEXTPROC deleteQueries_ = nullptr;
    PFNGLBEGINQUERYEXTPROC beginQuery_ = nullptr;
    PFNGLENDQUERYEXTPROC endQuery_ = nullptr;
    PFNGLGETQUERYOBJECTUIVEXTPROC getQueryObjectUiv_ = nullptr;
    PFNGLGETQUERYOBJECTUI64VEXTPROC getQueryObjectUi64v_ = nullptr;
    std::chrono::steady_clock::time_point lastFrame_;
    std::string glRenderer_;
    std::string glVendor_;
    std::string glVersion_;
    talk2u::VulkanInterop interop_;
    float clearRed_;
    float clearGreen_;
    float clearBlue_;
};

std::mutex sessionsMutex;
std::unordered_map<jlong, std::unique_ptr<Session>> sessions;
Session* graphicsOwner = nullptr;
jlong nextSession = 1;

Session& FindSession(jlong handle) {
    const auto item = sessions.find(handle);
    if (item == sessions.end()) throw std::invalid_argument("Live2D session is unavailable");
    return *item->second;
}

void ReleaseSessionGraphics(Session& session) {
    const bool ownsGlobalGraphics = graphicsOwner == &session;
    session.SurfaceDestroyed(ownsGlobalGraphics);
    if (ownsGlobalGraphics) graphicsOwner = nullptr;
}

template <typename Action>
void Invoke(JNIEnv* environment, Action action) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        action();
    } catch (const std::exception& error) {
        Throw(environment, error.what());
    }
}

}

extern "C" JNIEXPORT jlong JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeCreate(
    JNIEnv* environment,
    jobject,
    jobject assetManager,
    jstring modelPath,
    jint backgroundColor) {
    try {
        AAssetManager* assets = AAssetManager_fromJava(environment, assetManager);
        auto session = std::make_unique<Session>(
            assets,
            JStringToUtf8(environment, modelPath),
            static_cast<uint32_t>(backgroundColor));
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const jlong handle = nextSession++;
        sessions.emplace(handle, std::move(session));
        return handle;
    } catch (const std::exception& error) {
        Throw(environment, error.what());
        return 0;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativePrepare(
    JNIEnv* environment,
    jobject,
    jlong handle) {
    Invoke(environment, [&] { FindSession(handle).Prepare(); });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeSurfaceCreated(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jobject surface,
    jint width,
    jint height) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        Session& session = FindSession(handle);
        if (graphicsOwner != nullptr && graphicsOwner != &session) {
            ReleaseSessionGraphics(*graphicsOwner);
        }
        ReleaseSessionGraphics(session);
        try {
            session.SurfaceCreated(
                environment,
                surface,
                static_cast<csmUint32>(std::max(1, width)),
                static_cast<csmUint32>(std::max(1, height)));
            graphicsOwner = &session;
        } catch (...) {
            ReleaseSessionGraphics(session);
            throw;
        }
    } catch (const std::exception& error) {
        Throw(environment, error.what());
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeSurfaceDestroyed(
    JNIEnv* environment,
    jobject,
    jlong handle) {
    Invoke(environment, [&] { ReleaseSessionGraphics(FindSession(handle)); });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeSurfaceChanged(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jint width,
    jint height) {
    Invoke(environment, [&] {
        FindSession(handle).SurfaceChanged(
            static_cast<csmUint32>(std::max(1, width)),
            static_cast<csmUint32>(std::max(1, height)));
    });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeDrawFrame(
    JNIEnv* environment,
    jobject,
    jlong handle) {
    jboolean firstFrame = JNI_FALSE;
    Invoke(environment, [&] {
        firstFrame = FindSession(handle).DrawFrame() ? JNI_TRUE : JNI_FALSE;
    });
    return firstFrame;
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeSetMouth(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jfloat value) {
    Invoke(environment, [&] { FindSession(handle).SetMouth(value); });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeSetSpeaking(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jboolean value) {
    Invoke(environment, [&] { FindSession(handle).SetSpeaking(value == JNI_TRUE); });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeMotion(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jstring group,
    jint index) {
    const std::string groupValue = JStringToUtf8(environment, group);
    Invoke(environment, [&] { FindSession(handle).Motion(groupValue, index); });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeExpression(
    JNIEnv* environment,
    jobject,
    jlong handle,
    jstring name) {
    const std::string nameValue = JStringToUtf8(environment, name);
    Invoke(environment, [&] { FindSession(handle).Expression(nameValue); });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeResetExpression(
    JNIEnv* environment,
    jobject,
    jlong handle) {
    Invoke(environment, [&] { FindSession(handle).ResetExpression(); });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeDiagnostics(
    JNIEnv* environment,
    jobject,
    jlong handle) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        return Utf8ToJString(environment, FindSession(handle).Diagnostics());
    } catch (const std::exception& error) {
        Throw(environment, error.what());
        return nullptr;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_Live2dNativeBridge_nativeDestroy(
    JNIEnv*,
    jobject,
    jlong handle) {
    std::lock_guard<std::mutex> lock(sessionsMutex);
    const auto item = sessions.find(handle);
    if (item == sessions.end()) return;
    ReleaseSessionGraphics(*item->second);
    sessions.erase(item);
}
