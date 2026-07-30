cmake_minimum_required(VERSION 3.22.1)

project(talk2u_native LANGUAGES CXX)

if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
    message(FATAL_ERROR "Talk2U MOSS/QNN runtime supports arm64-v8a only")
endif()

set(ORT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime/include")
set(ORT_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libonnxruntime.so")

if(NOT EXISTS "${ORT_LIBRARY}")
    message(FATAL_ERROR "Missing matching ONNX Runtime library: ${ORT_LIBRARY}")
endif()
if(NOT EXISTS "${ORT_INCLUDE_DIR}/onnxruntime_c_api.h")
    message(FATAL_ERROR "Missing matching ONNX Runtime headers: ${ORT_INCLUDE_DIR}")
endif()

add_library(onnxruntime SHARED IMPORTED)
set_target_properties(onnxruntime PROPERTIES IMPORTED_LOCATION "${ORT_LIBRARY}")

add_library(
    moss
    SHARED
    MossTTSNativeLibs.cpp
    MossTtsQnnSession.cpp
    SentencePieceTokenizer.cpp
)
target_compile_features(moss PRIVATE cxx_std_20)
target_compile_options(
    moss
    PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Werror=return-type
    -fvisibility=hidden
)
target_include_directories(
    moss
    PRIVATE
    "${ORT_INCLUDE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
)
target_link_options(moss PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(moss PRIVATE onnxruntime android dl log)

add_library(
    talk2u_gpu_probe
    SHARED
    gpu_backend_probe.cpp
)

target_compile_features(talk2u_gpu_probe PRIVATE cxx_std_17)
target_compile_options(talk2u_gpu_probe PRIVATE -Wall -Wextra -Werror=return-type)

find_library(log-lib log REQUIRED)
find_library(egl-lib EGL REQUIRED)
find_library(gles-lib GLESv2 REQUIRED)
find_library(dl-lib dl REQUIRED)
find_library(vulkan-lib vulkan REQUIRED)

target_link_libraries(
    talk2u_gpu_probe
    PRIVATE
    ${log-lib}
    ${egl-lib}
    ${gles-lib}
    ${dl-lib}
)

if(NOT DEFINED TALK2U_CUBISM_SDK_ROOT OR TALK2U_CUBISM_SDK_ROOT STREQUAL "")
    message(FATAL_ERROR "TALK2U_CUBISM_SDK_ROOT must point to Cubism SDK for Native 5")
endif()

file(TO_CMAKE_PATH "${TALK2U_CUBISM_SDK_ROOT}" CUBISM_SDK_ROOT)
set(CUBISM_CORE_PATH "${CUBISM_SDK_ROOT}/Core")
set(CUBISM_FRAMEWORK_PATH "${CUBISM_SDK_ROOT}/Framework")
set(FRAMEWORK_SOURCE OpenGL)

add_library(Live2DCubismCore STATIC IMPORTED)
set_target_properties(
    Live2DCubismCore
    PROPERTIES
    IMPORTED_LOCATION "${CUBISM_CORE_PATH}/lib/android/${ANDROID_ABI}/libLive2DCubismCore.a"
    INTERFACE_INCLUDE_DIRECTORIES "${CUBISM_CORE_PATH}/include"
)

add_subdirectory(
    "${CUBISM_FRAMEWORK_PATH}"
    "${CMAKE_CURRENT_BINARY_DIR}/cubism-framework"
)
target_compile_definitions(Framework PUBLIC CSM_TARGET_ANDROID_ES2)

add_library(
    talk2u_live2d
    SHARED
    live2d_native_renderer.cpp
    live2d_vulkan_interop.cpp
)
target_compile_features(talk2u_live2d PRIVATE cxx_std_17)
target_compile_options(talk2u_live2d PRIVATE -Wall -Wextra -Werror=return-type)
target_compile_definitions(talk2u_live2d PRIVATE CSM_TARGET_ANDROID_ES2)
target_include_directories(
    talk2u_live2d
    PRIVATE
    "${CUBISM_SDK_ROOT}/Samples/OpenGL/thirdParty/stb"
)
target_link_options(talk2u_live2d PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(
    talk2u_live2d
    PRIVATE
    Framework
    Live2DCubismCore
    android
    log
    ${egl-lib}
    GLESv2
    ${vulkan-lib}
)
