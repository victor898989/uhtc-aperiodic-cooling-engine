// EOS M400-4 printer profile
// LPBF (Laser Powder Bed Fusion) - 4 lasers
#pragma once

namespace printing {
namespace printers {

struct EOS_M400_4 {
    static constexpr const char* name = "EOS M400-4";
    static constexpr const char* type = "LPBF";
    
    // Build chamber
    static constexpr double build_volume_x = 400.0;  // mm
    static constexpr double build_volume_y = 400.0;  // mm
    static constexpr double build_volume_z = 400.0;  // mm
    
    // Laser system
    static constexpr int laser_count = 4;
    static constexpr double laser_power_max = 400.0;  // W
    static constexpr double laser_spot_size = 0.1;    // mm
    static constexpr double scan_speed_max = 7000.0;  // mm/s
    
    // Optics
    static constexpr double galvo_scanner_range = 150.0;  // mm
    static constexpr double f_theta_lens_focal_length = 254.0;  // mm
    
    // Powder bed
    static constexpr double layer_thickness_min = 0.02;  // mm
    static constexpr double layer_thickness_max = 0.1;   // mm
    static constexpr double powder_particle_size = 30.0; // μm
    
    // Control
    static constexpr double axis_velocity_max = 2000.0;  // mm/s
    static constexpr int control_frequency_hz = 10000;
};

}
}
