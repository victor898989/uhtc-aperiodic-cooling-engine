// UHTC (Ultra-High Temperature Ceramic) material model
// ZrB2/TaC matrix with tantalum microfibers
#pragma once

namespace printing {
namespace materials {

struct UHTC {
    static constexpr const char* name = "UHTC (ZrB2/TaC)";
    static constexpr const char* standard = "Custom aerospace grade";
    
    // Matrix properties
    static constexpr double density = 6100.0;        // kg/m³
    static constexpr double melting_point = 3245.0;  // °C
    static constexpr double specific_heat = 340.0;   // J/(kg·K)
    static constexpr double thermal_conductivity = 80.0;  // W/(m·K)
    static constexpr double thermal_expansion = 5.5e-6;   // 1/K
    static constexpr double emissivity = 0.75;
    
    // Mechanical properties (sintered)
    static constexpr double yield_strength = 450.0;  // MPa
    static constexpr double tensile_strength = 520.0; // MPa
    static constexpr double elongation = 0.02;        // 2%
    static constexpr double elastic_modulus = 380.0;  // GPa
    static constexpr double poisson_ratio = 0.18;
    
    // Fiber reinforcement (tantalum microfibers)
    static constexpr double fiber_diameter = 50.0;    // μm
    static constexpr double fiber_length = 500.0;     // μm
    static constexpr double fiber_volume_fraction = 0.15;
    static constexpr double fiber_thermal_conductivity = 57.0;  // W/(m·K)
    
    // LPBF process parameters (if applicable)
    static constexpr double laser_power = 500.0;      // W
    static constexpr double scan_speed = 800.0;       // mm/s
    static constexpr double layer_thickness = 0.02;   // mm
    static constexpr double energy_density = 312.5;   // J/mm³
    
    // Thermal simulation
    static constexpr double convection_coefficient = 5.0;  // W/(m²·K)
    static constexpr double absorptivity = 0.6;
    
    // Oxidation protection
    static constexpr double oxidation_threshold_temp = 1800.0;  // °C
    static constexpr double modified_boron_silicate_thickness = 100.0;  // μm
};

}
}
