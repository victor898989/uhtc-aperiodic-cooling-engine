// Lithoz CeraFab S65 printer profile
// Ceramic vat photopolymerization (DLS/LCM)
#pragma once

namespace printing {
namespace printers {

struct Lithoz_CeraFab_S65 {
    static constexpr const char* name = "Lithoz CeraFab S65";
    static constexpr const char* type = "Ceramic_Vat";
    
    // Build platform
    static constexpr double build_volume_x = 65.0;  // mm
    static constexpr double build_volume_y = 65.0;  // mm
    static constexpr double build_volume_z = 75.0;  // mm
    
    // Light engine
    static constexpr double light_wavelength = 385.0;  // nm (UV)
    static constexpr double pixel_size = 50.0;         // μm
    static constexpr int resolution_x = 1920;
    static constexpr int resolution_y = 1080;
    
    // Layer
    static constexpr double layer_thickness_min = 0.01;  // mm
    static constexpr double layer_thickness_max = 0.1;   // mm
    
    // Ceramic slurry
    static constexpr double ceramic_loading = 60.0;  // vol%
    static constexpr double particle_size = 500.0;   // nm
    
    static constexpr double axis_velocity_max = 100.0;  // mm/s
    static constexpr int control_frequency_hz = 1000;
};

}
}
