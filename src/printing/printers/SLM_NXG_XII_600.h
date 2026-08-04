// SLM Solutions NXG XII 600 printer profile
// LPBF - 12 lasers, high production
#pragma once

namespace printing {
namespace printers {

struct SLM_NXG_XII_600 {
    static constexpr const char* name = "SLM Solutions NXG XII 600";
    static constexpr const char* type = "LPBF";
    
    // Build chamber
    static constexpr double build_volume_x = 600.0;  // mm
    static constexpr double build_volume_y = 600.0;  // mm
    static constexpr double build_volume_z = 600.0;  // mm
    
    // Laser system
    static constexpr int laser_count = 12;
    static constexpr double laser_power_max = 1000.0;  // W
    static constexpr double laser_spot_size = 0.08;    // mm
    static constexpr double scan_speed_max = 10000.0;  // mm/s
    
    // Optics
    static constexpr double galvo_scanner_range = 200.0;  // mm
    static constexpr double f_theta_lens_focal_length = 400.0;  // mm
    
    // Powder bed
    static constexpr double layer_thickness_min = 0.02;  // mm
    static constexpr double layer_thickness_max = 0.075;  // mm
    static constexpr double powder_particle_size = 25.0;  // μm
    
    // Control
    static constexpr double axis_velocity_max = 3000.0;  // mm/s
    static constexpr int control_frequency_hz = 20000;
};

}
}
