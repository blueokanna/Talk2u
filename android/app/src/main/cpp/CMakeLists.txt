cmake_minimum_required(VERSION 3.22.1)

project(talk2u_gpu_probe LANGUAGES CXX)

add_library(
    talk2u_gpu_probe
    SHARED
    gpu_backend_probe.cpp
    genie_runtime_bridge.cpp
)

target_compile_features(talk2u_gpu_probe PRIVATE cxx_std_17)
target_compile_options(talk2u_gpu_probe PRIVATE -Wall -Wextra -Werror=return-type)

find_library(log-lib log REQUIRED)
find_library(egl-lib EGL REQUIRED)
find_library(gles-lib GLESv2 REQUIRED)
find_library(dl-lib dl REQUIRED)

target_link_libraries(
    talk2u_gpu_probe
    PRIVATE
    ${log-lib}
    ${egl-lib}
    ${gles-lib}
    ${dl-lib}
)
