// Smoke tests for 3D printing engine
#include <cstdlib>
#include <cmath>
#include <cstdint>

#include "../src/printing/materials/Inconel718.h"
#include "../src/printing/materials/Ti64.h"
#include "../src/printing/materials/UHTC.h"
#include "../src/printing/materials/MonolithicWovenII.h"
#include "../src/printing/materials/AdvancedCeramic.h"

namespace {

bool material_properties_smoke() {
    // Inconel 718
    bool inconel_ok = (Inconel718::density > 0.0) &&
                      (Inconel718::melting_point > 1000.0) &&
                      (Inconel718::laser_power > 0.0);
    
    // Ti64
    bool ti64_ok = (Ti64::density > 0.0) &&
                   (Ti64::melting_point > 1500.0) &&
                   (Ti64::laser_power > 0.0);
    
    // UHTC
    bool uhtc_ok = (UHTC::density > 0.0) &&
                   (UHTC::melting_point > 3000.0) &&
                   (UHTC::thermal_conductivity > 0.0);
    
    // Woven II
    bool woven_ok = (MonolithicWovenII::density > 0.0) &&
                    (MonolithicWovenII::blocking_efficiency > 0.0) &&
                    (MonolithicWovenII::tortuosity > 1.0);
    
    // Ceramic
    bool ceramic_ok = (AdvancedCeramic::density > 0.0) &&
                      (AdvancedCeramic::melting_point > 1000.0);
    
    return inconel_ok && ti64_ok && uhtc_ok && woven_ok && ceramic_ok;
}

}

int main() {
    return material_properties_smoke() ? 0 : 1;
}
