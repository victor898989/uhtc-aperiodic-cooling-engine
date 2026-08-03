// SPDX-License-Identifier: Apache-2.0
//
// test_api_smoke.c
//
// Smoke test for the C-linkage API exported by libuhtc_native_accel.so.
// Verifies that all DllImport symbols resolve and return sensible values.
// This file is compiled into uhc_api_smoke_test and linked against
// uhtc_native_accel.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "NativeEngineAPI.h"

static int failures = 0;

#define CHECK(cond, msg)                                                  \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "  FAIL: %s\n", msg);                          \
            failures++;                                                    \
        } else {                                                           \
            printf("  PASS: %s\n", msg);                                   \
        }                                                                  \
    } while (0)

int main(int argc, char** argv)
{
    (void)argc; (void)argv;

    printf("=== UHC API Smoke Test ===\n");

    /* ---- Library lifecycle ---- */
    int rc = uhc_initialize(BACKEND_AUTO);
    CHECK(rc == 0, "uhc_initialize(AUTO) returns 0");
    CHECK(uhc_active_backend() == BACKEND_CPU || uhc_active_backend() == BACKEND_CUDA,
          "uhc_active_backend() returns valid enum");

    /* ---- Material queries ---- */
    float k  = uhc_mat_thermal_conductivity(0, 300.0f);
    CHECK(k > 50.0f && k < 200.0f, "k_ZrB2(300K) in [50, 200] W/m·K");

    float cp = uhc_mat_specific_heat(0, 300.0f);
    CHECK(cp > 0.2f && cp < 0.8f, "cp_ZrB2(300K) in [0.2, 0.8] J/g·K");

    float rho = uhc_mat_density(0, 300.0f);
    CHECK(rho > 4.0f && rho < 8.0f, "rho_ZrB2(300K) in [4, 8] g/cm³");

    float eps = uhc_mat_emissivity(0, 2000.0f);
    CHECK(eps >= 0.0f && eps <= 1.0f, "eps_ZrB2(2000K) in [0, 1]");

    float flux = uhc_mat_radiative_flux(0, 2500.0f, 300.0f);
    CHECK(flux > 0.0f, "radiative_flux_ZrB2(2500K) > 0");

    float barrier = uhc_mat_oxygen_barrier(0.15f, 3.5f, 2.0f);
    CHECK(barrier == 0.0f || barrier == 1.0f, "oxygen_barrier returns 0 or 1");

    /* ---- SDF evaluation (CPU fallback) ---- */
    float points[9] = { 0.0f, 0.0f, 0.0f,  1.0f, 0.0f, 0.0f,  0.0f, 1.0f, 0.0f };
    float sdf[3], barrier_out[3], k_out[3], lq[3], o2[3];
    UhcParams params;
    memset(&params, 0, sizeof(params));
    params.geometry_type  = 0;
    params.freq           = 1.0f;
    params.wall_thickness = 0.25f;
    params.t_critical_mm  = 0.08f;
    params.tortuosity     = 3.5f;
    params.T_melt_K       = 3523.0f;
    params.material_id    = 0;
    params.laser_power_W  = 500.0f;
    params.laser_eta      = 0.35f;
    params.scan_speed_mm_s= 5.0f;
    params.ellipse_x      = 2.5f;
    params.ellipse_y      = 2.5f;
    params.ellipse_z      = 1.0f;

    rc = uhc_evaluate_sdf(points, sdf, barrier_out, k_out, lq, o2, 3, &params);
    CHECK(rc == 0, "uhc_evaluate_sdf(3 points) returns 0");
    CHECK(sdf[0] < 0.0f, "SDF at origin is negative (inside surface)");

    /* ---- PID laser scan ---- */
    UhcScanSegment segs[2];
    segs[0].x = 0.0f; segs[0].y = 0.0f; segs[0].speed = 5.0f; segs[0].power = 500.0f;
    segs[1].x = 1.0f; segs[1].y = 0.0f; segs[1].speed = 5.0f; segs[1].power = 500.0f;
    float T_meas[2] = { 3400.0f, 3400.0f };
    float P_eff[2], e_stop[1];

    rc = uhc_pid_laser_scan(nullptr, segs, T_meas, P_eff, e_stop, 2, 3523.0f, &params);
    CHECK(rc == 0, "uhc_pid_laser_scan returns 0");
    CHECK(P_eff[0] > 0.0f, "PID output power > 0");
    CHECK(e_stop[0] == 0.0f, "no emergency stop for T < T_target+600K");

    /* ---- Shutdown ---- */
    uhc_shutdown();
    CHECK(1, "uhc_shutdown() executed");

    /* ---- Summary ---- */
    printf("\n=== Results ===\n");
    if (failures == 0)
    {
        printf("  ALL CHECKS PASSED\n");
        return 0;
    }
    else
    {
        printf("  %d CHECK(S) FAILED\n", failures);
        return 1;
    }
}
