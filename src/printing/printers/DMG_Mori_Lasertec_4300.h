// DMG Mori Lasertec 4300 printer profile
// DED (Directed Energy Deposition) - hybrid manufacturing
#pragma once

namespace printing {
namespace printers {

struct DMG_Mori_Lasertec_4300 {
    static constexpr const char* name = "DMG Mori Lasertec 4300";
    static constexpr const char* type = "DED";
    
    // Work envelope
    static constexpr double build_volume_x = 500.0;  // mm
    static constexpr double build_volume_y = 500.0;  // mm
    static constexpr double build_volume_z = 430.0;  // mm
    
    // Laser
    static constexpr int laser_count = 1;
    static constexpr double laser_power_max = 4000.0;  // W
    static constexpr double laser_spot_size = 0.5;     // mm
    static constexpr double scan_speed_max = 5000.0;  // mm/s
    
    // Powder nozzle
    static constexpr double powder_feed_rate_max = 50.0;  // g/min
    static constexpr double nozzle_diameter = 2.0;        // mm
    
    // Wire feed option
    static constexpr double wire_feed_rate_max = 5.0;  // m/min
    static constexpr double wire_diameter = 1.2;       // mm
    
    static constexpr double layer_thickness_min = 0.1;  // mm
    static constexpr double layer_thickness_max = 0.5;  // mm
    
    static constexpr double axis_velocity_max = 30000.0;  // mm/s
    static constexpr int control_frequency_hz = 5000;
};

}
}
