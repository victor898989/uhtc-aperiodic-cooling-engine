// Monolithic Woven II - Aperiodic structure generator
// Quasicrystal-inspired geometry for oxygen diffusion blocking
#pragma once

#include <cmath>
#include <cstdint>

namespace printing {
namespace wov2 {

// 6D hypercube projection parameters
struct WovenIIConfig {
    // Quasicrystal parameters
    double golden_ratio;
    double projection_angle;
    int dimension;
    
    // Physical parameters
    double fiber_diameter;        // μm
    double fiber_spacing;         // μm
    double matrix_fill_factor;
    
    // Grid parameters
    int grid_size;
    double voxel_size;            // mm
};

// Generate aperiodic density field from 6D projection
inline float aperiodic_density(float x, float y, float z, const WovenIIConfig& cfg) {
    // 6D projection of 3D coordinates
    double proj[6];
    proj[0] = x * cfg.golden_ratio;
    proj[1] = y * cfg.golden_ratio;
    proj[2] = z * cfg.golden_ratio;
    proj[3] = x + y + z;
    proj[4] = x - y + z;
    proj[5] = x + y - z;
    
    // Sum of sinusoidal projections
    double sum = 0.0;
    for (int i = 0; i < 6; ++i) {
        sum += std::sin(proj[i]);
    }
    
    // Threshold to create solid/void
    float density = (sum > 0.0) ? 1.0f : 0.0f;
    
    // Apply fiber spacing modulation
    float dist = std::sqrt(x*x + y*y + z*z);
    float fiber_mod = 1.0f - std::exp(-dist / (cfg.fiber_spacing * 1e-3f));
    
    return density * fiber_mod;
}

// Calculate oxygen diffusion tortuosity
inline double tortuosity(const WovenIIConfig& cfg) {
    // Higher for more complex aperiodic structures
    double complexity = cfg.dimension * cfg.golden_ratio;
    return 3.0 + complexity * 0.5;
}

// Calculate blocking efficiency
inline double blocking_efficiency(const WovenIIConfig& cfg) {
    double tort = tortuosity(cfg);
    return 1.0 - 1.0 / tort;
}

}
}
