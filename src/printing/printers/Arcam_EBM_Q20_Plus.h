// Arcam EBM Q20+ printer profile
// EBM (Electron Beam Melting) - for titanium and refractory metals
#pragma once

namespace printing {
namespace printers {

struct Arcam_EBM_Q20_Plus {
    static constexpr const char* name = "Arcam EBM Q20+";
    static constexpr const char* type = "EBM";
    
    static constexpr double build_volume_x = 200.0;  // mm
    static constexpr double build_volume_y = 200.0;  // mm
    static constexpr double build_volume_z = 380.0;  // mm
    
    // Electron beam
    static constexpr int beam_count = 1;
    static constexpr double beam_power_max = 3000.0;  // W
    static constexpr double beam_spot_size = 0.2;     // mm
    static constexpr double scan_speed_max = 8000.0;  // mm/s
    
    // Chamber
    static constexpr double chamber_temperature = 800.0;  // °C
    static constexpr double vacuum_level = 1e-4;         // mbar
    
    // Powder bed
    static constexpr double layer_thickness_min = 0.05;  // mm
    static constexpr double layer_thickness_max = 0.2;   // mm
    static constexpr double powder_particle_size = 80.0; // μm
    
    static constexpr double axis_velocity_max = 1500.0;  // mm/s
    static constexpr int control_frequency_hz = 10000;
};

}
}
