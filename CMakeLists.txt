cmake_minimum_required(VERSION 3.18)
project(UHTCNativeAccel LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CUDA_STANDARD 17)

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/Native/Common
    ${CMAKE_CURRENT_SOURCE_DIR}/src/Native/Cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/src/Native/PikoGK
)

file(GLOB_RECURSE CUDA_SOURCES
    "src/Native/Cuda/*.cu"
    "src/Native/Cuda/*.cpp"
    "src/Native/Cuda/OpenDB_Examples/*.cu"
    "src/Native/Cuda/OpenDB_Examples/*.cpp"
)

add_library(uhtc_native_accel SHARED ${CUDA_SOURCES})

set_target_properties(uhtc_native_accel PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    POSITION_INDEPENDENT_CODE ON
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/build/lib
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/build/bin
)
