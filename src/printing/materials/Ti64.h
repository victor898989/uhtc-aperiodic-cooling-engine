// Ti-6Al-4V (Ti64) material model for additive manufacturing
#pragma once

namespace printing {
namespace materials {

struct Ti64 {
    static constexpr const char* name = "Ti-6Al-4V";
    static constexpr const char* standard = "ASTM F136 / UNS R56400";
    
    // Physical properties
    static constexpr double density = 4420.0;        // kg/m³
    static constexpr double melting_point = 1660.0;  // °C
    static constexpr double specific_heat = 526.0;   // J/(kg·K)
    static constexpr double thermal_conductivity = 6.7;   // W/(m·K) at 100°C
    static constexpr double thermal_expansion = 8.6e-6;   // 1/K
    static constexpr double emissivity = 0.8;
    
    // Mechanical properties (as-built)
    static constexpr double yield_strength = 825.0;  // MPa
    static constexpr double tensile_strength = 965.0; // MPa
    static constexpr double elongation = 0.10;        // 10%
    static constexpr double elastic_modulus = 114.0;  // GPa
    static constexpr double poisson_ratio = 0.31;
    
    // LPBF process parameters
    static constexpr double laser_power = 280.0;      // W
    static constexpr double scan_speed = 1200.0;      // mm/s
    static constexpr double hatch_spacing = 0.1;      // mm
    static constexpr double layer_thickness = 0.03;   // mm
    static constexpr double energy_density = 77.8;    // J/mm³
    
    // EBM process parameters (Arcam Q20+ reference)
    static constexpr double ebm_beam_power = 1500.0;  // W
    static constexpr double ebm_scan_speed = 5000.0;  // mm/s
    static constexpr double ebm_layer_thickness = 0.07; // mm
    
    // Thermal simulation
    static constexpr double convection_coefficient = 8.0;  // W/(m²·K)
    static constexpr double absorptivity = 0.42;
    
    // Powder characteristics
    static constexpr double powder_particle_size_min = 20.0;  // μm
    static constexpr double powder_particle_size_max = 63.0;  // μm
    static constexpr double powder_flowability = 0.80;
    
    // HIP treatment
    static constexpr double hip_temperature = 950.0;  // °C
    static constexpr double hip_pressure = 100.0;     // MPa
    static constexpr double hip_duration = 4.0;       // hours
};

}
}
