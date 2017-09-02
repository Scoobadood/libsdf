#include <iostream>
#include <iomanip>

#include "libsdf/TSDFVolume.hpp"
#include "libsdf/GPURaycaster.hpp"
#include "libsdf/cuda_utilities.hpp"
#include "libsdf/TSDF_utilities.hpp"
#include "libsdf/PngUtilities.hpp"

#include <Eigen/Core>

#include "math_constants.h"

/**
 * Compute a direction vector, in world coordinates, from cam centre
 * through the given pixel.
 * @param origin The camera position in world coordinates
 * @param pix_x The x pixel coordinate
 * @param pix_y The y pixel coordinate
 * @param rot the camera pose rotation matrix
 * @param kinv THe camera intrinsics inverse matrix
 * @return The unit direction vector for the ray in world coordinate space
 */
__device__
float3 compute_ray_direction_at_pixel( const float3& origin, uint16_t pix_x, uint16_t pix_y, const Mat33& rot, const Mat33& kinv ) {

    // Get  point at depth 1mm. This is the direction vector in cam coords
    float3 ray_in_cam_space {
        pix_x * kinv.m11 + pix_y * kinv.m12 + kinv.m13,
        pix_x * kinv.m21 + pix_y * kinv.m22 + kinv.m23,
        pix_x * kinv.m31 + pix_y * kinv.m32 + kinv.m33
    };

    // Convert this vector to world coordinate frame
    // We'd normally add in the camera origin but since we
    // want the direction, we'd deduct the camera origin
    // at the very next step so we'll just do the rotation instead.
    float3 ray_in_world_space = m3_f3_mul( rot, ray_in_cam_space );

    // Convert to unit vector
    f3_normalise( ray_in_world_space);

    return ray_in_world_space;
}

/**
 * Perform trilinear interpolation of the TSDF value at a given point in volume space
 * @param point The point (0,0,0) -> (max_x, max_y, max_z)
 * @param voxel_grid_size The size of the space in voxels
 * @param tsdf_values An array of max_x*max_y*max_z floats being the values in the space
 * @return The interpolated TSDF value
 */
__device__
float trilinearly_interpolate( const float3 point,
                               const dim3 voxel_grid_size,
                               const float3 voxel_size,
                               const float *tsdf_values ) {

    // Manage boundary points
    float3 max_values {
        voxel_grid_size.x * voxel_size.x,
        voxel_grid_size.y * voxel_size.y,
        voxel_grid_size.z * voxel_size.z
    };
    float3 adjusted_point = point;
    if ( point.x >= max_values.x ) adjusted_point.x = max_values.x - (voxel_size.x / 10.0f);
    if ( point.y >= max_values.y ) adjusted_point.y = max_values.y - (voxel_size.y / 10.0f);
    if ( point.z >= max_values.z ) adjusted_point.z = max_values.z - (voxel_size.z / 10.0f);
    if ( point.x < 0.0f ) adjusted_point.x = 0.0f;
    if ( point.y < 0.0f ) adjusted_point.y = 0.0f;
    if ( point.z < 0.0f ) adjusted_point.z = 0.0f;

    // Get the voxel containing this point
    int3 voxel = voxel_for_point( adjusted_point, voxel_size );

    // Handle voxel out of bounds
    if ( voxel.x < 0 || voxel.y < 0 || voxel.z < 0  || voxel.x >= voxel_grid_size.x || voxel.y >= voxel_grid_size.y || voxel.z >= voxel_grid_size.z) {
        printf( "Point outside of voxel space %f, %f, %f\n", adjusted_point.x, adjusted_point.y, adjusted_point.z );
        return CUDART_NAN_F;
    }

    // Get the centre of the voxel
    float3 v_centre = centre_of_voxel_at( voxel.x, voxel.y, voxel.z, voxel_size );

    // Set up the lower bound for trilinear interpolation
    int3 lower;
    lower.x = (point.x < v_centre.x) ? voxel.x - 1 : voxel.x;
    lower.y = (point.y < v_centre.y) ? voxel.y - 1 : voxel.y;
    lower.z = (point.z < v_centre.z) ? voxel.z - 1 : voxel.z;

    // Handle lower out of bounds
    lower.x = max( lower.x, 0 );
    lower.y = max( lower.y, 0 );
    lower.z = max( lower.z, 0 );

    // Compute u,v,w
    float3 lower_centre = centre_of_voxel_at( lower.x, lower.y, lower.z, voxel_size );
    float3 uvw = f3_sub( point, lower_centre );
    uvw = f3_div_elem( uvw, voxel_size );
    float u = uvw.x;
    float v = uvw.y;
    float w = uvw.z;

    // Lookup c000 - c111
    float c000 = tsdf_value_at( lower.x + 0, lower.y + 0, lower.z + 0, tsdf_values, voxel_grid_size );
    float c001 = tsdf_value_at( lower.x + 0, lower.y + 0, lower.z + 1, tsdf_values, voxel_grid_size );
    float c010 = tsdf_value_at( lower.x + 0, lower.y + 1, lower.z + 0, tsdf_values, voxel_grid_size );
    float c011 = tsdf_value_at( lower.x + 0, lower.y + 1, lower.z + 1, tsdf_values, voxel_grid_size );
    float c100 = tsdf_value_at( lower.x + 1, lower.y + 0, lower.z + 0, tsdf_values, voxel_grid_size );
    float c101 = tsdf_value_at( lower.x + 1, lower.y + 0, lower.z + 1, tsdf_values, voxel_grid_size );
    float c110 = tsdf_value_at( lower.x + 1, lower.y + 1, lower.z + 0, tsdf_values, voxel_grid_size );
    float c111 = tsdf_value_at( lower.x + 1, lower.y + 1, lower.z + 1, tsdf_values, voxel_grid_size );

    float interpolated = c000 * (1 - u) * (1 - v) * (1 - w) +
                         c001 * (1 - u) * (1 - v) *    w  +
                         c010 * (1 - u) *    v  * (1 - w) +
                         c011 * (1 - u) *    v  *    w  +
                         c100 *    u  * (1 - v) * (1 - w) +
                         c101 *    u  * (1 - v) *    w  +
                         c110 *    u  *    v  * (1 - w) +
                         c111 *    u  *    v  *    w;

    return interpolated;
}


/**
 * For a given dimension check whether the ray can intersect the volume
 * If this method returns true, it doesn't mean tha the ray _does_ intersect, just that it could
 * @param space_min The minimum bound of the voxel space in the current dimension
 * @param space_max The maximum bound of the voxel space in the current dimension
 * @param origin The starting point of the ray in the current dimension
 * @param direction The direction of the ray in the current dimension
 * @param near_t The nearest point of intersection of the voxel space which may be updated in this call
 * @param far_t The furthest point of intersection of the voxel space which may be updated in this call
 * @return true if an intersection is still possible otherwise false
 */
__device__ __forceinline__
bool can_intersect_in_dimension( float space_min, float space_max, float origin, float direction, float& near_t, float& far_t) {
    bool can_intersect = true;

    if ( direction == 0 ) {
        // Not moving in this direction so we must be within  bounds in order to have any intersection at all
        if ( origin < space_min || origin > space_max ) {
            can_intersect = false;
        }
    } else {

        // compute intersection distance of the planes
        float distance_to_space_min = ( space_min - origin ) / direction;
        float distance_to_space_max = ( space_max - origin ) / direction;

        // If distance_to_space_min > distance_to_space_max swap (distance_to_space_min, distance_to_space_max) since distance_to_space_min intersection with near plane
        if ( distance_to_space_min > distance_to_space_max ) {
            float temp_t = distance_to_space_min;
            distance_to_space_min = distance_to_space_max;
            distance_to_space_max = temp_t;
        }

        // if distance_to_space_min > t_near set t_near = distance_to_space_min : We want largest t_near
        if ( distance_to_space_min > near_t ) {
            near_t = distance_to_space_min;
        }

        //If distance_to_space_max < t_far set t_far="distance_to_space_max"  want smallest t_far
        if ( distance_to_space_max < far_t ) {
            far_t = distance_to_space_max;
        }

        // If Tnear > Tfar box is missed so return false
        if ( near_t > far_t ) {
            can_intersect =  false;
        } else {
            // If Tfar < 0 box is behind ray return false end
            if ( far_t < 0 ) {
                can_intersect = false;
            }
        }
    }
    return can_intersect;
}

/**
 * Compute the intersections of the ray from origin in direction through the cube specified by space_min and space_max
 * There are three cases:
 * origin is inside the cube near_t =0, far_t is distance to exit and we return true
 * origin is outside of cube and ray misses it near_t and far_t are undefined, return value is false
 * origin is outside of cube and ray penetrates. near_t and far_t are defined (should have the same sign) and return value is true
 * @param origin The source of the ray in world coordinates
 * @param direction a Vector representing the direction of the ray in world coordinates
 * @param space_min The lower, leftmost, frontmost vertex of the voxel space in world coordinates
 * @param space_mac The upper, rightmost, rearmost vertex of the voxel space in world coordinates
 * @param near_t Populated with the nearpoint if return is true
 * @param far_t populated with the far point if return is true
 * @return true if the ray pierces the volme
 */
__device__
bool  compute_near_and_far_t( const float3 & origin, const float3 & direction, const float3 & space_min, const float3 & space_max, float & near_t, float & far_t ) {
    bool intersects = false;

    // Handle start_point in space
    if ( origin.x >= space_min.x && origin.x <= space_max.x && origin.y >= space_min.y && origin.y <= space_max.y && origin.z >= space_min.z && origin.z <= space_max.z ) {
        // Near_t is zero as origin is inside the space
        near_t = 0;

        float x_t = CUDART_NAN_F;
        float y_t = CUDART_NAN_F;
        float z_t = CUDART_NAN_F;
        if ( direction.x > 0 ) {
            x_t = (space_max.x - origin.x) / direction.x;
        } else if ( direction.x < 0 ) {
            x_t = ( space_min.x - origin.x) / direction.x;
        }

        if ( direction.y > 0 ) {
            y_t = (space_max.y - origin.y) / direction.y;
        } else if ( direction.y < 0 ) {
            y_t = ( space_min.y - origin.y) / direction.y;
        }

        if ( direction.z > 0 ) {
            z_t = (space_max.z - origin.z) / direction.z;
        } else if ( direction.z < 0 ) {
            z_t = ( space_min.z - origin.z) / direction.z;
        }

        if ( x_t < y_t ) {
            if ( x_t < z_t ) far_t = x_t;
            else far_t = z_t;
        } else {
            if ( y_t < z_t ) far_t = y_t;
            else far_t = z_t;
        }
        intersects = true;
    } else {
        // Outside of the voxel space just now
        near_t = -CUDART_INF_F;
        far_t  =  CUDART_INF_F;

        // Consider X
        if ( (can_intersect_in_dimension( space_min.x, space_max.x, origin.x, direction.x, near_t, far_t ) ) &&
                (can_intersect_in_dimension( space_min.y, space_max.y, origin.y, direction.y, near_t, far_t ) ) &&
                (can_intersect_in_dimension( space_min.z, space_max.z, origin.z, direction.z, near_t, far_t ) ) ) {
            intersects = true;
        }
    }

    // If we got here then

    return intersects;
}
/**
 * Walk a ray from the camera onto the TSDF determining where (if at all) it
 * intersects the ISO surface defined by the TSDF
 * @param origin The position of the camera in world coordinates
 * @param rot The camera pose rotation matrix in world terms
 * @param kinv The camera's intrinsic matrix inverse
 * @param space_min The lowest X,Y,Z in world coordinates occupied by the voxel space
 * @param space_max The highest  X,Y,Z in world coordinates occupied by the voxel space
 * @param voxel_grid_size Dimension of the voxel space in each direction in voxels
 * @param voxel_size Dimensions of each voxel
 * @param tsdf_values A pointer to the TSDF distance values with Z,Y,X coords major
 * @param vertex The 3D world coordinate of the vertex intersected by this ray if it exists or {NaN, NaN, NaN}
 */
__global__
void process_ray(   const float3        origin,
                    const Mat33         rot,
                    const Mat33         kinv,
                    uint16_t            max_x,
                    uint16_t            max_y,
                    const float         trunc_distance,
                    const float3        space_min,
                    const float3        space_max,
                    const dim3          voxel_grid_size,
                    const float3        voxel_size,
                    const float         * tsdf_values,
                    float3              * vertices) {

    int imx = threadIdx.x + blockIdx.x * blockDim.x;
    int imy = threadIdx.y + blockIdx.y * blockDim.y;

    // Terminate early if the index is out of bounds
    if ( imx >= max_x || imy >= max_y ) {
        return;
    }

    size_t idx = imy * max_x + imx;

    // Compute the ray direction for this pixel in world coordinates
    // which is R K-1 (x,y,1)T
    float3 direction      = compute_ray_direction_at_pixel( origin, imx, imy, rot, kinv );

    // Compute near and far intersections of the TSDF volume by this ray
    // near and far T are valules of the parameter origin + t*(direction.unit) at which the
    // ray from the camera through the point intersects the voxel space.
    // near_t may be zero if origin is inside the voxel space
    // far_t must be > near_t
    float near_t, far_t;
    bool intersects = compute_near_and_far_t( origin, direction, space_min, space_max, near_t, far_t );

    // Only do this if the ray intersects space
    float3 intersection_point { CUDART_NAN_F, CUDART_NAN_F, CUDART_NAN_F};

    if ( intersects ) {
        // Compute the start point in grid coords
        float3 start_point = f3_sub( f3_add( origin, f3_mul_scalar( near_t, direction ) ), space_min);

        bool done = false;

        // Initialise TSDF to trun distance
        float tsdf = trunc_distance;
        float previous_tsdf = 0;


        // Set up current point to iterate
        float t = 0;
        float max_t = far_t - near_t;

        // Iterate until
        //   We leave the voxel space (fail)
        //   We transit from +ve to -ve tsdf (intersect)
        //   We transit from -ve to +ve (fail)
        int count = 0;
        float step_size = trunc_distance * 0.05;
        while ( !done  ) {
            float3 current_point = f3_add( start_point, f3_mul_scalar( t, direction ) );

            // Save last TSDF (to check against crossing surface)
            previous_tsdf = tsdf;

            // Extract the tsdf
            float tsdf = trilinearly_interpolate( current_point, voxel_grid_size, voxel_size, tsdf_values );
            // If tsdf is negative then we're behind the surface else we're on it
            if ( tsdf <= 0 ) {
                // If we stepped past the iso surface, work out when
                if ( tsdf < 0 ) {
                    // We just advanced by step_size so step back
                    t = t - step_size;

                    // Linearly interpolate the crossing point
                    t = t + (previous_tsdf / (previous_tsdf - tsdf )) * step_size;
                }

                // Compute the point of intersection
                current_point = f3_add( start_point, f3_mul_scalar( t, direction ) );

                // Put into world coordinates
                intersection_point = f3_add( space_min, current_point );
                done = true;
            }

            // tsdf is +ve, if previous tsdf was negative then we hit a backface and we're done
            else if ( previous_tsdf < 0 ) {
                done = true;
            }

            // previous tsdf was +ve and so is this one. We've not crossed the surface
            // so keep stepping
            else {
                t = t + step_size;

                // Until we step out of the volume
                if ( t >= max_t ) {
                    done = true;
                }
            }

            // Catch failures - this code shouldn';'t be invoked.
            if ( count++ > 4400 ) {
                printf( "Timed out @(%d,%d) with t:%f tsdf:%f\n", imx, imy, t, tsdf  );

                done = true;
            }
        }
    }
    vertices[idx] = intersection_point;
}


__host__
float3 float3_from_eigen_vector( const Eigen::Vector3f & vector ) {
    float3 f { vector[0], vector[1], vector[2]};
    return f;
}

/**
 * Compute normals to the vertex data provided
 * @param width The with of the output matrix
 * @param height The height of the output matrix
 * @param vertices The input vertex array - unchanged by ths
 * @param normals the oputput normals array to be populated
 */
__global__
void compute_normals( uint16_t width, uint16_t height, const float3 * vertices, float3 * normals ) {
    int imx = threadIdx.x + blockIdx.x * blockDim.x;
    int imy = threadIdx.y + blockIdx.y * blockDim.y;

    // Terminate eearly if the index is out of bounds
    if ( imx >= width || imy >= height ) {
        return;
    }

    size_t idx = (imy * width + imx);

    if ( imy == height - 1 ) {
        normals[idx].x = 0;
        normals[idx].y = 0;
        normals[idx].z = 0;
    } else {
        if ( imx == width - 1) {
            normals[idx].x = 0;
            normals[idx].y = 0;
            normals[idx].z = 0;
        } else {
            float3 v2 { vertices[idx + 1].x - vertices[idx].x, vertices[idx + 1].y - vertices[idx].y, vertices[idx + 1].z - vertices[idx].z};
            float3 v1 { vertices[idx + width].x - vertices[idx].x, vertices[idx + width].y - vertices[idx].y, vertices[idx + width].z - vertices[idx].z};

            float nx = v1.y * v2.z - v1.z * v2.y;
            float ny = v1.z * v2.x - v1.x * v2.z;
            float nz = v1.x * v2.y - v1.y * v2.x;
            float l = sqrt( nx * nx + ny * ny + nz * nz);
            normals[idx].x = nx / l;
            normals[idx].y = ny / l;
            normals[idx].z = nz / l;
        }
    }
}

/**
 * Compute the vertex map
 */
__host__
float3 * get_vertices(  const TSDFVolume&  volume,
                        const Camera&      camera,
                        uint16_t           width,
                        uint16_t           height ) {


    // Setup camera origin
    float3 origin = float3_from_eigen_vector( camera.position() );

    // Set up voxel grid size
    dim3 voxel_grid_size = volume.size();
    float3 voxel_size = volume.voxel_size();

    // Set up rotation matrices for pose and Kinv
    // Eigen stores data in column major format.
    const float *pose = camera.pose().data();
    Mat33 rot {
        pose[0], pose[1], pose[2],
        pose[4], pose[5], pose[6],
        pose[8], pose[9], pose[10]
    };

    const float *cam_kinv = camera.kinv().data();
    Mat33 kinv {
        cam_kinv[0], cam_kinv[1], cam_kinv[2],
        cam_kinv[3], cam_kinv[4], cam_kinv[5],
        cam_kinv[6], cam_kinv[7], cam_kinv[8]
    };

    // Set up world coords for min and max extremes of the voxel space
    float3 space_min = volume.offset();
    float3 space_max = volume.offset() + volume.physical_size( );


    cudaError_t err;

    // Get reference to TSDF distance data
    const float * d_tsdf_values = volume.distance_data();

    // Allocate storage for vertices on device
    size_t data_size = width * height * sizeof( float3 );
    float3 * d_vertices;
    err = cudaMalloc( &d_vertices, data_size );
    check_cuda_error( "Vertices alloc failed ", err);

    // Execute the kernel
    dim3 block( 32, 32 );
    dim3 grid ( divUp( width, block.x ), divUp( height, block.y ) );
    process_ray <<< grid, block>>>( origin, rot, kinv, width, height, volume.truncation_distance(), space_min, space_max, voxel_grid_size, voxel_size, d_tsdf_values, d_vertices );
    err = cudaDeviceSynchronize( );
    check_cuda_error( "process_ray failed " , err);

    return d_vertices;
}


/**
 * Compute the normals given the vertices and dimensions
 * @param width The width of the vertex data
 * @param height The height of the vertex data
 * @d_vertices Pointer to vertex data (on device)
 * @return An array of normals
 */
float3 * compute_normals( uint16_t width, uint16_t height, float3 * d_vertices ) {
    float3 * d_normals;

    cudaError_t err;

    err = cudaMalloc( &d_normals,  width * height * sizeof( float3 ) );
    check_cuda_error( "Normals alloc failed ", err);

    dim3 block( 32, 32 );
    dim3 grid ( divUp( width, block.x ), divUp( height, block.y ) );
    compute_normals <<< grid, block>>>(width, height, d_vertices, d_normals);
    check_cuda_error( "compute_normals failed ", err);

    return d_normals;
}

/**
 * Raycast the TSDF and store discovered vertices and normals in the ubput arrays
 * @param volume The volume to cast
 * @param camera The camera
 * @param vertices The vertices discovered
 * @param normals The normals
 */
void GPURaycaster::raycast( const TSDFVolume & volume,
                            const Camera & camera,
                            Eigen::Matrix<float, 3, Eigen::Dynamic> & vertices,
                            Eigen::Matrix<float, 3, Eigen::Dynamic> &normals ) const {
    using namespace Eigen;

    // Compute vertices
    float3 * d_vertices = get_vertices( volume, camera, m_width, m_height );

    // Compute normals
    float3 * d_normals = compute_normals( m_width, m_height, d_vertices );


    // Copy vertex data back
    cudaError_t err;

    vertices.resize( 3, m_width * m_height);
    float  *h_vertices = vertices.data();
    err = cudaMemcpy( h_vertices, d_vertices, m_width * m_height * 3 * sizeof( float ), cudaMemcpyDeviceToHost);
    check_cuda_error( "Vertices Memcpy failed ", err);
    cudaFree( d_vertices );

    // Copy normal data back
    normals.resize( 3, m_width * m_height );
    float  *h_normals = normals.data();
    err = cudaMemcpy( h_normals, d_normals, m_width * m_height * 3 * sizeof( float ), cudaMemcpyDeviceToHost);
    check_cuda_error( "Normals Memcpy failed ", err);
    cudaFree( d_normals );
}

/**
 * Render a depth image from a TSDF
 * @param volume The volume to cast
 * @param camera The camera
 * @return The DepthImage
 */
DepthImage * GPURaycaster::render_to_depth_image( const TSDFVolume & volume, const Camera & camera ) const {
    using namespace Eigen;

    std::cout << "Rendering depth map" << std::endl;

    DepthImage * d = nullptr;

    // Compute vertices on device
    float3 * d_vertices = get_vertices( volume, camera, m_width, m_height );

    std::cout << "  got vertices on device" << std::endl;
    // Copy device vertices ionto host
    float3 * h_vertices = new float3[m_width * m_height];
    if ( h_vertices ) {
        cudaMemcpy( h_vertices, d_vertices, m_width * m_height * sizeof( float3), cudaMemcpyDeviceToHost);


        // Stash just the Z coords to a depth map
        uint16_t * depth_data = new uint16_t[ m_width * m_height ];
        if ( depth_data ) {

            // Convert to and return a DepthImage
            for ( int i = 0; i < m_width * m_height; i++ ) {
                float3 world_point = h_vertices[i];
                Eigen::Vector3f cam_point = camera.world_to_camera( Eigen::Vector3f{ world_point.x, world_point.y, world_point.z } );
                depth_data[i] = (uint16_t)roundf(cam_point.z());
            }

            std::cout << "  making depthimage" << std::endl;
            d = new DepthImage( m_width, m_height, depth_data);

            // DEBUG
            // TODO: Remove me
            std::cout << "  saving mesh depth image: REMOVE ME" << std::endl;
            save_png_to_file( "/home/dave/Desktop/mesh_depth_file.png", 640, 480, depth_data );


            delete[] depth_data;
        } else {
            std::cout << "Couldn't allocate depth data storage" << std::endl;
        }

        delete[] h_vertices;

    } else {
        std::cout << "Couldn't allocate host memory for vertices" << std::endl;
    }

    cudaFree( d_vertices );
    std::cout << "  done" << std::endl;
    return d;
}
