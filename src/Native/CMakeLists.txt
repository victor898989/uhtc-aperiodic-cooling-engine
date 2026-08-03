# SPDX-License-Identifier: Apache-2.0
#
# src/Native/CMakeLists.txt
#
# Unified build for UHTC Native Acceleration:
#   - CUDA shared library  (libuhtc_native_accel.so)
#   - FPGA HLS OBJECT lib  (for v++ / Vitis compilation to .xclbin)
#   - Bridge API           (C-linkage, imported by C# UnsafeNativeMethods.cs)

cmake_minimum_required(VERSION 3.18)

# ==================================================================
#  CUDA shared library
#  Note: uses explicit source list to avoid duplicate symbols from
#  the legacy uhc_native_api.cu (now superseded by FPGA/Bridge/)
# ==================================================================
set(UHC_CUDA_SOURCES
    # --- UHTC domain kernels ---
    Cuda/uhc_material_properties.h
    Cuda/uhc_thermal_solver.cu
    Cuda/uhc_thermal_solver.h
    Cuda/uhc_deposition.cu
    Cuda/uhc_deposition.h
    Cuda/uhc_oxygen_barrier.cu
    Cuda/uhc_oxygen_barrier.h
    Cuda/uhc_kinetic_solver.cu
    Cuda/uhc_oxygen_diffusion.cu

    # --- NanoVDB infrastructure ---
    Cuda/nanovdb.cu
    Cuda/dilate_nanovdb_cuda.cpp
    Cuda/dilate_nanovdb_cuda_kernels.cu
    Cuda/main.cc
    Cuda/Maps.cc
    Cuda/Transform.cc
    Cuda/Proximity.cc
    Cuda/openvdb.cc
    Cuda/OpenDB_Examples/coarsen_nanovdb_cuda.cpp
    Cuda/OpenDB_Examples/coarsen_nanovdb_cuda_kernels.cu

    # --- Unified bridge (C-linkage API for C# P/Invoke) ---
    FPGA/Bridge/NativeEngineAPI.cpp
)

add_library(uhtc_native_accel SHARED ${UHC_CUDA_SOURCES})

set_target_properties(uhtc_native_accel PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    POSITION_INDEPENDENT_CODE ON
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/../build/lib
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/../build/bin
    CUDA_ARCHITECTURES "70;75;80;86"
)

target_compile_definitions(uhtc_native_accel PRIVATE
    NANOVDB_USE_CUDA=1
    NANOVDB_USE_OPENVDB=1
)

target_include_directories(uhtc_native_accel PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/Cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/FPGA/Bridge
    ${CMAKE_CURRENT_SOURCE_DIR}/FPGA/hls
    ${CMAKE_CURRENT_SOURCE_DIR}/Common
    ${CMAKE_CURRENT_SOURCE_DIR}/../CSharp/Interop
)

# ==================================================================
#  FPGA HLS — OBJECT library for Vitis v++ compilation
# ==================================================================
find_program(VITIS_HLS_EXE vitis_hls)
if(VITIS_HLS_EXE)
    message(STATUS "Found Vitis HLS: ${VITIS_HLS_EXE}")

    set(UHC_FPGA_HLS_SOURCES
        FPGA/hls/laser_controller.cpp
        FPGA/hls/uhc_fpga_types.h
        FPGA/Bridge/NativeEngineAPI.h
    )

    add_library(uhtc_xrt_kernels OBJECT ${UHC_FPGA_HLS_SOURCES})

    set_target_properties(uhtc_xrt_kernels PROPERTIES
        CXX_STANDARD 17
        POSITION_INDEPENDENT_CODE ON
    )

    target_include_directories(uhtc_xrt_kernels PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/FPGA/hls
        ${CMAKE_CURRENT_SOURCE_DIR}/FPGA/Bridge
    )

    message(STATUS "  FPGA HLS target  : uhtc_xrt_kernels")
    message(STATUS "  Compile with     : v++ -t hw -k laser_controller_kernel ...")
else()
    message(STATUS "Vitis HLS not found — skipping uhtc_xrt_kernels target")
endif()

# ==================================================================
#  Host-side FPGA driver (links against uhtc_native_accel)
# ==================================================================
add_library(uhtc_fpga_driver STATIC
    FPGA/drivers/zcu104_driver.cpp
)

target_link_libraries(uhtc_fpga_driver PUBLIC uhtc_native_accel)

# ==================================================================
#  Summary
# ==================================================================
message(STATUS "")
message(STATUS "=== UHTC Native Engine (src/Native) ===")
message(STATUS "  CUDA library      : uhtc_native_accel")
message(STATUS "  Bridge header     : FPGA/Bridge/NativeEngineAPI.h")
message(STATUS "  FPGA HLS kernels  : FPGA/hls/laser_controller.cpp")
message(STATUS "  FPGA host driver  : FPGA/drivers/zcu104_driver.cpp")
if(VITIS_HLS_EXE)
    message(STATUS "  XRT kernel target : uhtc_xrt_kernels (OBJECT for v++)")
endif()
message(STATUS "========================================")
