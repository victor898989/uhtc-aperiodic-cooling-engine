// Smoke test for Woven II aperiodic structure generator
#include <cstdlib>
#include <cmath>
#include <cstdint>

#include "../src/printing/wov2/WovenII.h"

namespace {

bool wov2_structure_smoke() {
    printing::wov2::WovenIIConfig cfg;
    cfg.golden_ratio = printing::wov2::MonolithicWovenII::golden_ratio;
    cfg.projection_angle = 0.5;
    cfg.dimension = printing::wov2::MonolithicWovenII::dimension;
    cfg.fiber_diameter = printing::wov2::MonolithicWovenII::fiber_diameter;
    cfg.fiber_spacing = 100.0;
    cfg.matrix_fill_factor = 0.8;
    cfg.grid_size = 32;
    cfg.voxel_size = 0.05;
    
    // Generate a few voxels
    for (int x = 0; x < 4; ++x) {
        for (int y = 0; y < 4; ++y) {
            for (int z = 0; z < 4; ++z) {
                float fx = static_cast<float>(x) * cfg.voxel_size;
                float fy = static_cast<float>(y) * cfg.voxel_size;
                float fz = static_cast<float>(z) * cfg.voxel_size;
                
                float density = printing::wov2::aperiodic_density(fx, fy, fz, cfg);
                bool valid = (density >= 0.0f) && (density <= 1.0f);
                if (!valid) return false;
            }
        }
    }
    
    double tort = printing::wov2::tortuosity(cfg);
    double blocking = printing::wov2::blocking_efficiency(cfg);
    
    return (tort > 1.0) && (blocking > 0.0) && (blocking <= 1.0);
}

}

int main() {
    return wov2_structure_smoke() ? 0 : 1;
}
