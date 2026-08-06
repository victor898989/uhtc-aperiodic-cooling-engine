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

add_executable(printing_materials_smoke_test printing/printing_materials_smoke.cpp)
target_include_directories(printing_materials_smoke_test PRIVATE ${CMAKE_SOURCE_DIR}/src/printing)
add_test(NAME printing_materials_smoke COMMAND printing_materials_smoke_test)

add_executable(printer_profiles_smoke_test printing/printer_profiles_smoke.cpp)
target_include_directories(printer_profiles_smoke_test PRIVATE ${CMAKE_SOURCE_DIR}/src/printing)
add_test(NAME printer_profiles_smoke COMMAND printer_profiles_smoke_test)

add_executable(wov2_structure_smoke_test printing/wov2_structure_smoke.cpp)
target_include_directories(wov2_structure_smoke_test PRIVATE ${CMAKE_SOURCE_DIR}/src/printing)
add_test(NAME wov2_structure_smoke COMMAND wov2_structure_smoke_test)

if(CMAKE_CUDA_COMPILER)
    add_executable(rocket_structure_smoke_test cuda/rocket_structure_smoke.cu)
    set_target_properties(rocket_structure_smoke_test PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
    target_include_directories(rocket_structure_smoke_test PRIVATE
        ${CMAKE_SOURCE_DIR}/src/Native/Cuda
        ${CMAKE_SOURCE_DIR}/src/cuda
        ${CMAKE_SOURCE_DIR}/src/io/bin
    )
    target_link_libraries(rocket_structure_smoke_test PRIVATE uhtc_native_accel)
    add_test(NAME rocket_structure_smoke COMMAND rocket_structure_smoke_test
             WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/configs)
    set_tests_properties(rocket_structure_smoke PROPERTIES
        DISABLED $<NOT:$<BOOL:${CUDA_FOUND}}>>
        LABELS "cuda;rocket;nanovdb;uhc")
endif()
