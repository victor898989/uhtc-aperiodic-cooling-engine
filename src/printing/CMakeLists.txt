cmake_minimum_required(VERSION 3.18)

add_library(printing_engine INTERFACE)
target_include_directories(printing_engine INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/printers
    ${CMAKE_CURRENT_SOURCE_DIR}/materials
    ${CMAKE_CURRENT_SOURCE_DIR}/pipeline
    ${CMAKE_CURRENT_SOURCE_DIR}/wov2
)
