cmake_minimum_required (VERSION 2.6)

project( sdf )
set (sdf_VERSION_MAJOR 1)
set (sdf_VERSION_MINOR 0)

# Add the binary tree to the search path for inlcude files
include_directories( "src")
include_directories( "${PROJECT_BINARY_DIR}" )

# Write targets to bin directory
set( CMAKE_RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/../bin)
set( CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/../library)

# Needs CUDA
find_package( CUDA REQUIRED )

# Pass options to NVCC
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS}; -std=c++11 )
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS}; -O3 -gencode arch=compute_52,code=sm_52)
set(CUDA_SEPARABLE_COMPILATION ON)
set(CUDA_PROPAGATE_HOST_FLAGS OFF)
set(CUDA_VERBOSE_BUILD ON)

# Require Eigen
find_package(Eigen3 REQUIRED)
include_directories(${EIGEN3_INCLUDE_DIR})


# configure a header file to pass some of the CMake settings
# to the source code
configure_file ( "src/sdfConfig.h.in" "sdfConfig.h")

# Add the binary tree to the search path for inlcude files
file(GLOB SOURCES "src/*.cpp")
file(GLOB CUDA_SOURCES "src/*.cu")


cuda_compile(CU_O ${CUDA_SOURCES})

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++11")

set( LIB_TYPE STATIC )
cuda_add_library(sdf ${LIB_TYPE} ${SOURCES} ${CU_O}) 
