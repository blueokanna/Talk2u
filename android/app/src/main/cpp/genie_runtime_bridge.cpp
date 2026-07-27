#include <jni.h>
#include <dlfcn.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace {

using Status = int32_t;
using ConfigHandle = const void*;
using DialogHandle = const void*;
using QueryCallback = void (*)(const char*, int32_t, const void*);
using CreateConfig = Status (*)(const char*, ConfigHandle*);
using FreeConfig = Status (*)(ConfigHandle);
using CreateDialog = Status (*)(ConfigHandle, DialogHandle*);
using QueryDialog = Status (*)(DialogHandle, const char*, int32_t, QueryCallback, const void*);
using SignalDialog = Status (*)(DialogHandle, int32_t);
using FreeDialog = Status (*)(DialogHandle);

struct Api {
    void* library = nullptr;
    CreateConfig createConfig = nullptr;
    FreeConfig freeConfig = nullptr;
    CreateDialog createDialog = nullptr;
    QueryDialog query = nullptr;
    SignalDialog signal = nullptr;
    FreeDialog freeDialog = nullptr;

    bool Ready() const {
        return library != nullptr && createConfig != nullptr && freeConfig != nullptr &&
               createDialog != nullptr && query != nullptr && signal != nullptr &&
               freeDialog != nullptr;
    }
};

Api& GetApi() {
    static Api api;
    static std::once_flag once;
    std::call_once(once, [] {
        api.library = dlopen("libGenie.so", RTLD_NOW | RTLD_LOCAL);
        if (api.library == nullptr) return;
        api.createConfig = reinterpret_cast<CreateConfig>(
            dlsym(api.library, "GenieDialogConfig_createFromJson"));
        api.freeConfig = reinterpret_cast<FreeConfig>(
            dlsym(api.library, "GenieDialogConfig_free"));
        api.createDialog = reinterpret_cast<CreateDialog>(
            dlsym(api.library, "GenieDialog_create"));
        api.query = reinterpret_cast<QueryDialog>(dlsym(api.library, "GenieDialog_query"));
        api.signal = reinterpret_cast<SignalDialog>(dlsym(api.library, "GenieDialog_signal"));
        api.freeDialog = reinterpret_cast<FreeDialog>(dlsym(api.library, "GenieDialog_free"));
        if (!api.Ready()) {
            dlclose(api.library);
            api = Api{};
        }
    });
    return api;
}

std::mutex handlesMutex;
struct DialogSession {
    DialogHandle dialog;
    FreeDialog freeDialog;

    DialogSession(DialogHandle value, FreeDialog release)
        : dialog(value), freeDialog(release) {}
    DialogSession(const DialogSession&) = delete;
    DialogSession& operator=(const DialogSession&) = delete;

    ~DialogSession() {
        if (dialog != nullptr && freeDialog != nullptr) freeDialog(dialog);
    }
};
using DialogSessionPtr = std::shared_ptr<DialogSession>;
std::unordered_map<jlong, DialogSessionPtr> handles;
jlong nextHandle = 1;

void Throw(JNIEnv* environment, const char* type, const std::string& message) {
    jclass exception = environment->FindClass(type);
    if (exception != nullptr) environment->ThrowNew(exception, message.c_str());
}

std::string JStringToUtf8(JNIEnv* environment, jstring value) {
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
        bytes, 0, static_cast<jsize>(value.size()),
        reinterpret_cast<const jbyte*>(value.data()));
    jclass stringClass = environment->FindClass("java/lang/String");
    jmethodID constructor = environment->GetMethodID(
        stringClass, "<init>", "([BLjava/lang/String;)V");
    jstring charset = environment->NewStringUTF("UTF-8");
    auto result = static_cast<jstring>(
        environment->NewObject(stringClass, constructor, bytes, charset));
    environment->DeleteLocalRef(charset);
    environment->DeleteLocalRef(stringClass);
    environment->DeleteLocalRef(bytes);
    return result;
}

void AppendResponse(const char* response, int32_t, const void* userData) {
    if (response == nullptr || userData == nullptr) return;
    static_cast<std::string*>(const_cast<void*>(userData))->append(response);
}

DialogSessionPtr FindHandle(jlong id) {
    std::lock_guard<std::mutex> lock(handlesMutex);
    const auto item = handles.find(id);
    return item == handles.end() ? nullptr : item->second;
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_blue_talk2u_GenieRuntimeBridge_nativeAvailable(JNIEnv*, jobject) {
    return GetApi().Ready() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_blue_talk2u_GenieRuntimeBridge_nativeCreate(
    JNIEnv* environment, jobject, jstring configJson) {
    Api& api = GetApi();
    if (!api.Ready()) {
        Throw(environment, "java/lang/IllegalStateException", "libGenie.so is unavailable");
        return 0;
    }
    const std::string json = JStringToUtf8(environment, configJson);
    ConfigHandle config = nullptr;
    const Status configStatus = api.createConfig(json.c_str(), &config);
    if (configStatus != 0 || config == nullptr) {
        Throw(environment, "java/lang/IllegalArgumentException",
              "Genie rejected dialog config, status=" + std::to_string(configStatus));
        return 0;
    }
    DialogHandle dialog = nullptr;
    const Status dialogStatus = api.createDialog(config, &dialog);
    api.freeConfig(config);
    if (dialogStatus != 0 || dialog == nullptr) {
        Throw(environment, "java/lang/IllegalStateException",
              "Genie failed to create dialog, status=" + std::to_string(dialogStatus));
        return 0;
    }
    std::lock_guard<std::mutex> lock(handlesMutex);
    const jlong id = nextHandle++;
    handles.emplace(id, std::make_shared<DialogSession>(dialog, api.freeDialog));
    return id;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_blue_talk2u_GenieRuntimeBridge_nativeQuery(
    JNIEnv* environment, jobject, jlong id, jstring prompt) {
    Api& api = GetApi();
    const DialogSessionPtr session = FindHandle(id);
    if (!api.Ready() || session == nullptr) {
        Throw(environment, "java/lang/IllegalStateException", "Genie dialog is not loaded");
        return nullptr;
    }
    const std::string input = JStringToUtf8(environment, prompt);
    std::string response;
    const Status status = api.query(
        session->dialog, input.c_str(), 0, AppendResponse, &response);
    if (status != 0 && status != 1 && status != 3) {
        Throw(environment, "java/lang/IllegalStateException",
              "Genie query failed, status=" + std::to_string(status));
        return nullptr;
    }
    return Utf8ToJString(environment, response);
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_GenieRuntimeBridge_nativeStop(JNIEnv*, jobject, jlong id) {
    Api& api = GetApi();
    const DialogSessionPtr session = FindHandle(id);
    if (api.Ready() && session != nullptr) api.signal(session->dialog, 0x01);
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_GenieRuntimeBridge_nativeFree(JNIEnv*, jobject, jlong id) {
    DialogSessionPtr session;
    {
        std::lock_guard<std::mutex> lock(handlesMutex);
        const auto item = handles.find(id);
        if (item != handles.end()) {
            session = std::move(item->second);
            handles.erase(item);
        }
    }
    // The shared session stays alive until an in-flight query or stop call
    // releases its reference, preventing a use-after-free across activities.
    session.reset();
}
