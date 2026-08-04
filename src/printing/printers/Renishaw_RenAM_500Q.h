// Renishaw RenAM 500Q printer profile
// LPBF - 4 lasers, high precision
#pragma once

namespace printing {
namespace printers {

struct Renishaw_RenAM_500Q {
    static constexpr const char* name = "Renishaw RenAM 500Q";
    static constexpr const char* type = "LPBF";
    
    static constexpr double build_volume_x = 250.0;  // mm
    static constexpr double build_volume_y = 250.0;  // mm
    static constexpr double build_volume_z = 300.0;  // mm
    
    static constexpr int laser_count = 4;
    static constexpr double laser_power_max = 500.0;  // W
    static constexpr double laser_spot_size = 0.07;   // mm
    static constexpr double scan_speed_max = 8000.0;  // mm/s
    
    static constexpr double galvo_scanner_range = 120.0;  // mm
    static constexpr double f_theta_lens_focal_length = 200.0;  // mm
    
    static constexpr double layer_thickness_min = 0.02;  // mm
    static constexpr double layer_thickness_max = 0.08;  // mm
    static constexpr double powder_particle_size = 25.0; // μm
    
    static constexpr double axis_velocity_max = 2000.0;  // mm/s
    static constexpr int control_frequency_hz = 15000;
};

}
}
