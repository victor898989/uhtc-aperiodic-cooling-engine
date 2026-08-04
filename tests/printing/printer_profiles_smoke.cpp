// Smoke test for printer profiles
#include <cstdlib>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "../src/printing/printers/EOS_M400_4.h"
#include "../src/printing/printers/SLM_NXG_XII_600.h"
#include "../src/printing/printers/Renishaw_RenAM_500Q.h"
#include "../src/printing/printers/Arcam_EBM_Q20_Plus.h"
#include "../src/printing/printers/DMG_Mori_Lasertec_4300.h"
#include "../src/printing/printers/Lithoz_CeraFab_S65.h"

namespace {

bool printer_profile_smoke() {
    bool eos_ok = std::strcmp(EOS_M400_4::name, "EOS M400-4") == 0 &&
                  EOS_M400_4::laser_count == 4 &&
                  EOS_M400_4::build_volume_x > 0.0;
    
    bool slm_ok = std::strcmp(SLM_NXG_XII_600::name, "SLM Solutions NXG XII 600") == 0 &&
                  SLM_NXG_XII_600::laser_count == 12 &&
                  SLM_NXG_XII_600::build_volume_x > 0.0;
    
    bool renishaw_ok = std::strcmp(Renishaw_RenAM_500Q::name, "Renishaw RenAM 500Q") == 0 &&
                       Renishaw_RenAM_500Q::laser_count == 4 &&
                       Renishaw_RenAM_500Q::build_volume_x > 0.0;
    
    bool arcam_ok = std::strcmp(Arcam_EBM_Q20_Plus::name, "Arcam EBM Q20+") == 0 &&
                    Arcam_EBM_Q20_Plus::beam_count == 1 &&
                    Arcam_EBM_Q20_Plus::chamber_temperature > 0.0;
    
    bool dmg_ok = std::strcmp(DMG_Mori_Lasertec_4300::name, "DMG Mori Lasertec 4300") == 0 &&
                  DMG_Mori_Lasertec_4300::laser_power_max > 0.0;
    
    bool lithoz_ok = std::strcmp(Lithoz_CeraFab_S65::name, "Lithoz CeraFab S65") == 0 &&
                     Lithoz_CeraFab_S65::build_volume_x > 0.0;
    
    return eos_ok && slm_ok && renishaw_ok && arcam_ok && dmg_ok && lithoz_ok;
}

}

int main() {
    return printer_profile_smoke() ? 0 : 1;
}
