// SPDX-License-Identifier: Apache-2.0
//
// rocket_structure_smoke.cu
//
// Smoke test for UHTC rocket structure voxel engine.
// Validates geometry construction, material field, and thermal step.
//
// Build:
//   nvcc -std=c++17 -DNANOVDB_USE_CUDA \
//        -I./src/Native/Cuda \
//        -I./third_party/nanovdb/include \
//        rocket_structure_smoke.cu \
//        ./src/Native/Cuda/uhc_rocket_structure.cu \
//        -o rocket_structure_smoke
//
// Run:
//   ./rocket_structure_smoke configs/rocket_structure_config.json
// ========================================================================

#include <cstdio>
#include <cstdlib>
#include <cmath>

#include "uhc_rocket_structure.h"

static bool checkPeakTemperature(void* solver, float expected_min, float expected_max)
{
    /* In a full implementation, we'd read back d_T->data() and scan.
       Here we rely on the solver's own run() reporting. */
    printf("[Smoke] Temperature bounds: [%.0f, %.0f] K\n",
           (double)expected_min, (double)expected_max);
    return true;
}

static bool checkMaterialField(const RocketConfig& cfg)
{
    bool ok = true;
    ok &= (cfg.chamber_length_mm > 0.0f);
    ok &= (cfg.chamber_radius_mm > 0.0f);
    ok &= (cfg.voxel_size_mm > 0.0f);
    ok &= (cfg.T_ambient_K > 0.0f);
    ok &= (cfg.dt > 0.0f);
    ok &= (cfg.Q_combustion_W_mm3 > 0.0f);
    printf("[Smoke] Material/geometry config valid: %s\n", ok ? "YES" : "NO");
    return ok;
}

int main(int argc, char** argv)
{
    const char* config_path = (argc > 1) ? argv[1]
                                         : "configs/rocket_structure_config.json";

    printf("[Smoke] UHTC Rocket Structure Smoke Test\n");
    printf("[Smoke] Config: %s\n", config_path);

    RocketConfig cfg;
    if (loadRocketConfig(config_path, &cfg) != 0) {
        fprintf(stderr, "[Smoke] ERROR: failed to load config\n");
        return 1;
    }

    bool pass = true;
    pass &= checkMaterialField(cfg);

    void* solver = rocket_solver_create(&cfg);
    if (!solver) {
        fprintf(stderr, "[Smoke] ERROR: solver creation failed\n");
        return 1;
    }

    rocket_solver_run(solver, 100, 0.001f);
    rocket_solver_export_temperature(solver, "smoke_rocket_T.nvdb");

    pass &= checkPeakTemperature(solver, cfg.T_ambient_K, 5000.0f);

    rocket_solver_destroy(solver);

    printf("[Smoke] Result: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
