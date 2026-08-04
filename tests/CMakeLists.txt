cmake_minimum_required(VERSION 3.18)

add_executable(geometry_smoke_test geometry/geometry_smoke_test.cpp)
add_test(NAME geometry_smoke COMMAND geometry_smoke_test)

add_executable(thermal_smoke_test thermal/thermal_smoke_test.cpp)
add_test(NAME thermal_smoke COMMAND thermal_smoke_test)

if(CMAKE_CUDA_COMPILER)
    add_executable(cuda_smoke_test cuda/cuda_smoke_test.cu)
    set_target_properties(cuda_smoke_test PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
    add_test(NAME cuda_smoke COMMAND cuda_smoke_test)
endif()

add_executable(openvdb_io_smoke_test geometry/openvdb_io_smoke_test.cpp)
add_test(NAME openvdb_io_smoke COMMAND openvdb_io_smoke_test)

if(CMAKE_CUDA_COMPILER)
    add_executable(nanovdb_smoke_test cuda/nanovdb_smoke_test.cu)
    set_target_properties(nanovdb_smoke_test PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
    add_test(NAME nanovdb_smoke COMMAND nanovdb_smoke_test)
endif()

add_executable(nanovdb_mesh_voxels_e2e_test geometry/nanovdb_mesh_voxels_e2e.cpp)
add_test(NAME nanovdb_mesh_voxels_e2e COMMAND nanovdb_mesh_voxels_e2e_test)

if(CMAKE_CUDA_COMPILER)
    add_executable(cuda_e2e_saxpy_test cuda/cuda_e2e_saxpy.cu)
    set_target_properties(cuda_e2e_saxpy_test PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
    add_test(NAME cuda_e2e_saxpy COMMAND cuda_e2e_saxpy_test)
endif()
