#include "MossTtsQnnSession.h"

#include <jni.h>

#include <atomic>
#include <filesystem>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace {

std::mutex g_sessions_mutex;
std::unordered_map<jlong, std::shared_ptr<MossTtsQnnSession>> g_sessions;
std::atomic<jlong> g_next_handle{1};

class UtfChars final {
public:
    UtfChars(JNIEnv* env, jstring value, const char* label) : env_(env), value_(value) {
        if (!value_) throw std::invalid_argument(std::string(label) + " is null");
        chars_ = env_->GetStringUTFChars(value_, nullptr);
        if (!chars_) throw std::runtime_error(std::string("Cannot read ") + label);
    }

    ~UtfChars() {
        if (chars_) env_->ReleaseStringUTFChars(value_, chars_);
    }

    [[nodiscard]] std::string String() const { return chars_; }

private:
    JNIEnv* env_;
    jstring value_;
    const char* chars_ = nullptr;
};

void Throw(JNIEnv* env, const char* class_name, const std::string& message) {
    jclass type = env->FindClass(class_name);
    if (type) env->ThrowNew(type, message.c_str());
}

template <typename Result, typename Function>
Result Guard(JNIEnv* env, Result fallback, Function&& function) {
    try {
        return function();
    } catch (const std::invalid_argument& error) {
        if (!env->ExceptionCheck()) Throw(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        if (!env->ExceptionCheck()) Throw(env, "java/lang/IllegalStateException", error.what());
    } catch (...) {
        if (!env->ExceptionCheck()) {
            Throw(env, "java/lang/IllegalStateException", "Unknown native MOSS failure");
        }
    }
    return fallback;
}

std::shared_ptr<MossTtsQnnSession> SessionFor(jlong handle) {
    if (handle <= 0) throw std::invalid_argument("Invalid native session handle");
    std::lock_guard lock(g_sessions_mutex);
    const auto found = g_sessions.find(handle);
    if (found == g_sessions.end()) throw std::invalid_argument("Native session is closed");
    return found->second;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_blue_talk2u_NativeMossRuntime_nativeCreateSession(
    JNIEnv* env, jclass, jstring model_root, jstring native_library_dir,
    jstring context_cache_dir, jstring fast_rpc_dir, jboolean hardware_only,
    jboolean enable_context_cache, jobject progress_callback) {
    return Guard<jlong>(env, 0, [&] {
        UtfChars model(env, model_root, "modelRoot");
        UtfChars libraries(env, native_library_dir, "nativeLibraryDir");
        UtfChars cache(env, context_cache_dir, "contextCacheDir");
        UtfChars rpc(env, fast_rpc_dir, "fastRpcDir");
        MossTtsQnnSession::InitConfig config;
        config.model_root = model.String();
        config.native_library_dir = libraries.String();
        config.context_cache_dir = cache.String();
        config.fast_rpc_dir = rpc.String();
        config.hardware_only = hardware_only == JNI_TRUE;
        config.enable_context_cache = enable_context_cache == JNI_TRUE;
        if (!progress_callback) throw std::invalid_argument("progressCallback is null");
        jclass callback_class = env->GetObjectClass(progress_callback);
        if (!callback_class) throw std::runtime_error("Cannot inspect progressCallback");
        const jmethodID on_progress =
            env->GetMethodID(callback_class, "onProgress", "(Ljava/lang/String;)V");
        env->DeleteLocalRef(callback_class);
        if (!on_progress) throw std::runtime_error("progressCallback has no onProgress method");
        config.progress_callback = [env, progress_callback, on_progress](const std::string& stage) {
            jstring value = env->NewStringUTF(stage.c_str());
            if (!value) throw std::runtime_error("Cannot allocate progress stage");
            env->CallVoidMethod(progress_callback, on_progress, value);
            env->DeleteLocalRef(value);
            if (env->ExceptionCheck()) throw std::runtime_error("Progress callback failed");
        };
        auto session = std::make_shared<MossTtsQnnSession>(std::move(config));
        const jlong handle = g_next_handle.fetch_add(1, std::memory_order_relaxed);
        if (handle <= 0) throw std::runtime_error("Native handle space exhausted");
        std::lock_guard lock(g_sessions_mutex);
        g_sessions.emplace(handle, std::move(session));
        return handle;
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_blue_talk2u_NativeMossRuntime_nativeProbeQnn(
    JNIEnv* env, jclass, jstring native_library_dir) {
    return Guard<jint>(env, 0, [&] {
        UtfChars libraries(env, native_library_dir, "nativeLibraryDir");
        return MossTtsQnnSession::ProbeQnnPlugin(libraries.String());
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_blue_talk2u_NativeMossRuntime_nativeRun(
    JNIEnv* env, jclass, jlong handle, jstring text, jstring output_path,
    jstring voice, jint max_frames, jlong seed) {
    return Guard<jstring>(env, nullptr, [&] {
        const auto session = SessionFor(handle);
        UtfChars input_text(env, text, "text");
        UtfChars output(env, output_path, "outputPath");
        UtfChars selected_voice(env, voice, "voice");
        const auto result = session->Synthesize(input_text.String(), output.String(),
                                                selected_voice.String(), max_frames,
                                                static_cast<uint64_t>(seed));
        return env->NewStringUTF(result.ToJson().c_str());
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_blue_talk2u_NativeMossRuntime_nativeGetTelemetry(
    JNIEnv* env, jclass, jlong handle) {
    return Guard<jstring>(env, nullptr, [&] {
        const auto session = SessionFor(handle);
        return env->NewStringUTF(session->TelemetryJson().c_str());
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_blue_talk2u_NativeMossRuntime_nativeRelease(
    JNIEnv* env, jclass, jlong handle) {
    Guard<int>(env, 0, [&] {
        std::shared_ptr<MossTtsQnnSession> removed;
        {
            std::lock_guard lock(g_sessions_mutex);
            const auto found = g_sessions.find(handle);
            if (found == g_sessions.end()) return 0;
            removed = std::move(found->second);
            g_sessions.erase(found);
        }
        removed.reset();
        return 0;
    });
}
