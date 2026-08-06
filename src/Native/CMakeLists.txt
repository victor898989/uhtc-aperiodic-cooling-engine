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
    Cuda/uhc_rocket_structure.cu
    Cuda/uhc_rocket_structure_api.cu
    Cuda/uhc_rocket_structure.h
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
    ${CMAKE_CURRENT_SOURCE_DIR}/../cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/../io/bin
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
#  CUDA kernel unit tests (uhc_cuda_test_harness)
# ==================================================================
add_executable(uhc_cuda_test_harness
    Cuda/tests/uhc_test_kernels.cu
    Cuda/uhc_kinetic_solver.cu
    Cuda/uhc_oxygen_diffusion.cu
    Cuda/uhc_material_properties.h
)
set_target_properties(uhc_cuda_test_harness PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_ARCHITECTURES "70;75;80;86"
)
target_compile_definitions(uhc_cuda_test_harness PRIVATE
    NANOVDB_USE_CUDA=1
    NANOVDB_USE_OPENVDB=1
)
target_include_directories(uhc_cuda_test_harness PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/Cuda
)
target_link_libraries(uhc_cuda_test_harness PRIVATE uhtc_native_accel)

# ==================================================================
#  Rocket structure smoke test
# ==================================================================
add_executable(uhc_rocket_structure_smoke
    ../../tests/cuda/rocket_structure_smoke.cu
    Cuda/uhc_rocket_structure_api.cu
    Cuda/uhc_rocket_structure.h
    Cuda/uhc_material_properties.h
)
set_target_properties(uhc_rocket_structure_smoke PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_ARCHITECTURES "70;75;80;86"
)
target_compile_definitions(uhc_rocket_structure_smoke PRIVATE
    NANOVDB_USE_CUDA=1
    NANOVDB_USE_OPENVDB=1
)
target_include_directories(uhc_rocket_structure_smoke PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/Cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/../cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/../io/bin
)
target_link_libraries(uhc_rocket_structure_smoke PRIVATE uhtc_native_accel)

# Register with ctest (only if CUDA is available)
if(CMAKE_CUDA_COMPILER)
    enable_testing()
    add_test(NAME uhc_cuda_kernel_tests
             COMMAND uhc_cuda_test_harness
             WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
    set_tests_properties(uhc_cuda_kernel_tests PROPERTIES
        DISABLED $<NOT:$<BOOL:${CUDA_FOUND}>>
        LABELS "cuda;native")
    add_test(NAME uhc_rocket_structure_smoke
             COMMAND uhc_rocket_structure_smoke
             WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../configs)
    set_tests_properties(uhc_rocket_structure_smoke PROPERTIES
        DISABLED $<NOT:$<BOOL:${CUDA_FOUND}>>
        LABELS "cuda;rocket;nanovdb")
endif()

# ==================================================================
#  C API smoke test (verifies all DllImport symbols resolve)
# ==================================================================
add_executable(uhc_api_smoke_test
    FPGA/Bridge/NativeEngineAPI.cpp
    Cuda/tests/test_api_smoke.c
)
set_target_properties(uhc_api_smoke_test PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(uhc_api_smoke_test PRIVATE uhtc_native_accel)

if(CMAKE_CUDA_COMPILER)
    add_test(NAME uhc_api_smoke
             COMMAND uhc_api_smoke_test
             WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
    set_tests_properties(uhc_api_smoke PROPERTIES
        LABELS "native;smoke")
endif()

# ==================================================================
#  Summary
# ==================================================================
message(STATUS "")
message(STATUS "=== UHTC Native Engine (src/Native) ===")
message(STATUS "  CUDA library      : uhtc_native_accel")
message(STATUS "  Bridge header     : FPGA/Bridge/NativeEngineAPI.h")
message(STATUS "  FPGA HLS kernels  : FPGA/hls/laser_controller.cpp")
message(STATUS "  FPGA host driver  : FPGA/drivers/zcu104_driver.cpp")
message(STATUS "  CUDA tests        : uhc_cuda_test_harness  (ctest: uhc_cuda_kernel_tests)")
message(STATUS "  API smoke test    : uhc_api_smoke_test     (ctest: uhc_api_smoke)")
if(VITIS_HLS_EXE)
    message(STATUS "  XRT kernel target : uhtc_xrt_kernels (OBJECT for v++)")
endif()
message(STATUS "========================================")
