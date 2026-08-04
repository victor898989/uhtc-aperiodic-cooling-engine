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
