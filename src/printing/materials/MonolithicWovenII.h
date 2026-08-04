// Monolithic Woven II material model
// Advanced aerospace composite with periodic aperiodic structure
#pragma once

namespace printing {
namespace materials {

struct MonolithicWovenII {
    static constexpr const char* name = "Monolithic Woven II";
    static constexpr const char* type = "Aperiodic ceramic matrix composite";
    
    // Base matrix (ZrB2/TaC)
    static constexpr double matrix_density = 6100.0;     // kg/m³
    static constexpr double matrix_thermal_conductivity = 80.0;  // W/(m·K)
    static constexpr double matrix_specific_heat = 340.0;  // J/(kg·K)
    
    // Fiber network (tantalum microfibers)
    static constexpr double fiber_density = 16600.0;     // kg/m³
    static constexpr double fiber_thermal_conductivity = 57.0;  // W/(m·K)
    static constexpr double fiber_diameter = 50.0;       // μm
    static constexpr double fiber_volume_fraction = 0.20;
    
    // Effective properties (rule of mixtures + aperiodic correction)
    static constexpr double density = 7500.0;           // kg/m³
    static constexpr double thermal_conductivity = 95.0;  // W/(m·K)
    static constexpr double specific_heat = 360.0;      // J/(kg·K)
    static constexpr double melting_point = 3200.0;     // °C
    static constexpr double thermal_expansion = 4.8e-6; // 1/K
    static constexpr double emissivity = 0.72;
    
    // Mechanical properties
    static constexpr double elastic_modulus = 420.0;    // GPa
    static constexpr double yield_strength = 580.0;     // MPa
    static constexpr double tensile_strength = 650.0;   // MPa
    static constexpr double elongation = 0.03;           // 3%
    static constexpr double poisson_ratio = 0.21;
    
    // Oxygen diffusion barrier
    static constexpr double oxygen_permeability = 1e-12;  // mol/(m·s·Pa)
    static constexpr double tortuosity = 5.2;
    static constexpr double blocking_efficiency = 0.99;
    
    // Aperiodic structure (quasicrystal-inspired)
    static constexpr int dimension = 6;  // 6D projection
    static constexpr double golden_ratio = 1.618033988749895;
    
    // Thermal processing
    static constexpr double processing_temp = 2200.0;  // °C
    static constexpr double cooling_rate = 10.0;       // °C/min
    
    // Printing parameters
    static constexpr double laser_power = 600.0;       // W
    static constexpr double scan_speed = 600.0;        // mm/s
    static constexpr double layer_thickness = 0.015;   // mm
    static constexpr double energy_density = 666.7;    // J/mm³
    
    // Porosity target
    static constexpr double target_porosity = 0.02;    // 2%
    static constexpr double max_porosity = 0.05;       // 5%
};

}
}
