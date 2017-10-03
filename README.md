# libSDF
libSDF is a library providing a CUDA based implementation of a signed distance fucntion as described in Curless & Levoy.

It provides methods for merging depth maps and for extracting the resultant 3D mesh or for raycasting it to an image buffer.

The code is not tremendously optimised and there is definitely scope for imporvement.

## Usage
Checkout the repository then 

    $ md build
    $ cmake ..
    $ make

To use, 
    #include "libsdf/TSDFVolume.hpp"
    #include "libsdf/PngWrapper.hpp"

    // Create a volume with 256 voxels in X, Y and Z dimensions, representing a space 2000mm in X, Y and Z dimensions
    TSDFVolume * volume = new TSDFVolume( 256, 256, 256, 2000.f, 2000.f, 2000.f );

    // Move the origin of the volume so that origin of space is centred in the volume
    volume->offset( -1000.f, -1000.f, -1000.f);

    // Use the default Kinect camera intrinics and position camera at origin of space
    Camera * camera = Camera::default_depth_camera( );

    // Acquire a depth buffer ...
    uint8_t *depth_buffer;
    uint32_t wisth, height;
   
    // Integrate depth map into TSDF
    volume->integrate( depth_buffer, width, height, camera );

    // Save the TSDF file
    volume->save_to_file("/home/dave/Desktop/tsdf.dat");

    // Render the volume as a scene and normals
    Eigen::Matrix< float, 3, Eigen::Dynamic> vertices;
    Eigen::Matrix< float, 3, Eigen::Dynamic> normals;

    std::cout << "Raycasting" << std::endl;
    volume->raycast( 512, 424, *camera, vertices, normals );

    std::cout << "Rendering to image " << std::endl;
    Eigen::Vector3f light_source { 0,0,-1000 };
    PngWrapper *p = scene_as_png( 512, 424, vertices, normals, *camera, light_source );
    p->save_to("/home/dave/Desktop/scene.png");
    delete p;

    std::cout << "Rendering normals to image " << std::endl;
    p = normals_as_png( 512, 424, normals );
    std::cout << "Saving PNG" << std::endl;
    p->save_to("/home/dave/Desktop/normals.png");
    delete p;


