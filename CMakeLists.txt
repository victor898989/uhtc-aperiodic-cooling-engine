cmake_minimum_required(VERSION 3.18)
project(UHTCNativeAccel LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CUDA_STANDARD 17)

# ==================================================================
#  Unified Native Engine (CUDA + FPGA HLS + Bridge API)
# ==================================================================
add_subdirectory(src/Native)

# ==================================================================
#  OpenVDB-3D-Printing Engine modules
# ==================================================================
enable_testing()
add_subdirectory(src/core)
add_subdirectory(src/cuda)
add_subdirectory(src/slicing)
add_subdirectory(src/io)
add_subdirectory(tests)

# ==================================================================
#  Summary
# ==================================================================
message(STATUS "")
message(STATUS "=== UHTC Aperiodic Cooling Engine — Top-Level Build ===")
message(STATUS "  C# solution    : UHTCEngine.sln  (src/CSharp/UhtcAperiodicCoolingEngine.csproj)")
message(STATUS "  Native library : build/lib/libuhtc_native_accel.so")
message(STATUS "  FPGA kernels   : build/xclbin/  (requires Vitis 2024.1+)")
message(STATUS "  C API header   : src/Native/FPGA/Bridge/NativeEngineAPI.h")
message(STATUS "  C# interop     : src/CSharp/Interop/UnsafeNativeMethods.cs")
message(STATUS "========================================================")
