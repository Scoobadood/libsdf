//
//  Raycaster.hpp
//  KinFu
//
//  Created by Dave on 2/06/2016.
//  Copyright © 2016 Sindesso. All rights reserved.
//

#ifndef GPURaycaster_hpp
#define GPURaycaster_hpp

#include <Eigen/Core>

#include "libsdf/Raycaster.hpp"
#include "libsdf/TSDFVolume.hpp"
#include "libsdf/DepthImage.hpp"


class GPURaycaster : public Raycaster {
public:
    GPURaycaster( int width=640, int height=480) : Raycaster { width, height } {} ;

    /**
     * Raycast the TSDF and store discovered vertices and normals in the ubput arrays
     * @param volume The volume to cast
     * @param camera The camera
     * @param vertices The vertices discovered
     * @param normals The normals
     */
    virtual void raycast( const TSDFVolume & volume, const Camera & camera,
                          Eigen::Matrix<float, 3, Eigen::Dynamic> & vertices,
                          Eigen::Matrix<float, 3, Eigen::Dynamic> & normals ) const;

    /**
     * Render a depth image from a TSDF
     * @param volume The volume to cast
     * @param camera The camera
     * @return The DepthImage
     */
    DepthImage * render_to_depth_image( const TSDFVolume & volume, const Camera & camera ) const;
};
#endif /* GPURaycaster_hpp */
