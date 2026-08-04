// Advanced ceramic material model for vat photopolymerization
#pragma once

namespace printing {
namespace materials {

struct AdvancedCeramic {
    static constexpr const char* name = "Modified Boron Silicate Ceramic";
    static constexpr const char* standard = "Custom aerospace grade";
    
    // Physical properties (sintered)
    static constexpr double density = 2200.0;        // kg/m³
    static constexpr double melting_point = 1650.0;  // °C
    static constexpr double specific_heat = 750.0;   // J/(kg·K)
    static constexpr double thermal_conductivity = 1.2;  // W/(m·K)
    static constexpr double thermal_expansion = 3.2e-6;  // 1/K
    static constexpr double emissivity = 0.9;
    
    // Mechanical properties (sintered)
    static constexpr double yield_strength = 320.0;  // MPa
    static constexpr double tensile_strength = 380.0; // MPa
    static constexpr double elongation = 0.005;       // 0.5%
    static constexpr double elastic_modulus = 95.0;   // GPa
    static constexpr double poisson_ratio = 0.25;
    
    // Vat polymerization parameters (Lithoz CeraFab S65)
    static constexpr double layer_thickness = 0.05;  // mm
    static constexpr double green_density = 0.55;    // 55% theoretical
    static constexpr double sintering_shrinkage = 0.20; // 20%
    
    // Sintering profile
    static constexpr double binder_removal_temp = 600.0;  // °C
    static constexpr double sintering_temp = 1300.0;      // °C
    static constexpr double sintering_time = 4.0;         // hours
    static constexpr double heating_rate = 2.0;           // °C/min
    static constexpr double cooling_rate = 5.0;           // °C/min
    
    // Thermal simulation
    static constexpr double convection_coefficient = 3.0;  // W/(m²·K)
    
    // Powder characteristics
    static constexpr double ceramic_particle_size = 500.0;  // nm
    static constexpr double ceramic_loading = 60.0;         // vol%
};

}
}
