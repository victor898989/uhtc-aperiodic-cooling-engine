// Inconel 718 material model for additive manufacturing
#pragma once

namespace printing {
namespace materials {

struct Inconel718 {
    static constexpr const char* name = "Inconel 718";
    static constexpr const char* standard = "AMS 5662 / UNS N07718";
    
    // Physical properties
    static constexpr double density = 8190.0;        // kg/m³
    static constexpr double melting_point = 1336.0;  // °C
    static constexpr double specific_heat = 435.0;   // J/(kg·K)
    static constexpr double thermal_conductivity = 11.4;  // W/(m·K) at 100°C
    static constexpr double thermal_expansion = 13.0e-6;  // 1/K
    static constexpr double emissivity = 0.75;
    
    // Mechanical properties (as-built)
    static constexpr double yield_strength = 725.0;  // MPa
    static constexpr double tensile_strength = 930.0; // MPa
    static constexpr double elongation = 0.12;        // 12%
    static constexpr double elastic_modulus = 200.0;  // GPa
    static constexpr double poisson_ratio = 0.29;
    
    // LPBF process parameters (EOS M400-4 reference)
    static constexpr double laser_power = 370.0;      // W
    static constexpr double scan_speed = 1200.0;      // mm/s
    static constexpr double hatch_spacing = 0.1;      // mm
    static constexpr double layer_thickness = 0.03;   // mm
    static constexpr double energy_density = 102.8;   // J/mm³
    
    // Thermal simulation
    static constexpr double convection_coefficient = 10.0;  // W/(m²·K)
    static constexpr double absorptivity = 0.35;
    
    // Powder characteristics
    static constexpr double powder_particle_size_min = 15.0;  // μm
    static constexpr double powder_particle_size_max = 45.0;  // μm
    static constexpr double powder_flowability = 0.85;        // 0-1
};

}
}
