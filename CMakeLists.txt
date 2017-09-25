cmake_minimum_required (VERSION 3.8)

project( sdf 
         VERSION  0.1
         LANGUAGES CXX CUDA)


# Add the binary tree to the search path for inlcude files
include_directories( "include")
include_directories( "${PROJECT_BINARY_DIR}" )

# Write targets to bin directory
set( CMAKE_RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/../bin)
set( CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/../library)

# configure a header file to pass some of the CMake settings
# to the source code
configure_file ( "include/libsdf/sdfConfig.h.in" "sdfConfig.h")

# Configure CUDA
set( CMAKE_CUDA_FLAGS "-g -G -O0")

# Require Eigen
find_package(Eigen3 REQUIRED)
include_directories(${EIGEN3_INCLUDE_DIR})

# Find source files and CUDA files 
file(GLOB SOURCES "src/*.cpp")
file(GLOB CUDA_SOURCES "src/*.cu")

# We're making a library
set( LIB_TYPE STATIC )
add_library( sdf ${LIB_TYPE} ${SOURCES} ${CUDA_SOURCES} )

target_compile_features(sdf PUBLIC cxx_std_11)

set_target_properties(sdf PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
set_target_properties(sdf PROPERTIES CUDA_RESOLVE_DEVICE_SYMBOLS ON)

