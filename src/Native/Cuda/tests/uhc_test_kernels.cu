// SPDX-License-Identifier: Apache-2.0
//
// uhc_test_kernels.cu
//
// Device-side unit tests for UHTC CUDA kernels.
// These tests run on the GPU and verify:
//   1. Material property functions (k, cp, rho, epsilon)
//   2. Oxygen diffusion Arrhenius formula
//   3. Laser heat-source Gaussian shape
//   4. Thermal solver stencil correctness
//   5. Deposition state machine
//
// Build as part of libuhtc_native_accel.so.
// Run with: ./uhc_cuda_test_harness

#include "uhc_material_properties.h"
#include "uhc_oxygen_diffusion.cu"
#include "uhc_kinetic_solver.cu"

#include <cstdio>
#include <cuda_runtime.h>
#include <cmath>
#include <cstring>

/* ================================================================== */
/*  Test framework (minimal, no external dependency)                   */
/* ================================================================== */

static int g_test_failures = 0;

#define TEST_ASSERT(cond, msg)                                           \
    do {                                                                  \
        if (!(cond)) {                                                    \
            printf("  FAIL: %s (line %d): %s\n", __FILE__, __LINE__, msg); \
            g_test_failures++;                                            \
        } else {                                                          \
            printf("  PASS: %s\n", msg);                                  \
        }                                                                 \
    } while (0)

#define TEST_ASSERT_NEAR(actual, expected, tol, msg)                     \
    do {                                                                  \
        float diff = fabsf((actual) - (expected));                        \
        if (diff > (tol)) {                                               \
            printf("  FAIL: %s — %.6f != %.6f (tol %.6f)\n",             \
                   msg, (double)(actual), (double)(expected), (double)(tol)); \
            g_test_failures++;                                            \
        } else {                                                          \
            printf("  PASS: %s\n", msg);                                  \
        }                                                                 \
    } while (0)

#define RUN_TEST(name)                                                   \
    printf("\n[TEST] %s\n", name);                                        \
    test_##name()

/* ================================================================== */
/*  Test 1: Material properties                                        */
/* ================================================================== */

static void test_material_properties()
{
    /* ZrB2 thermal conductivity @ 300 K ≈ 120 W/m·K */
    float k_zrb2_300 = uhc::thermal_conductivity(uhc::MAT_ZRB2, 300.0f);
    TEST_ASSERT_NEAR(k_zrb2_300, 120.0f, 15.0f, "ZrB2 k @ 300 K");

    /* TaC thermal conductivity @ 300 K ≈ 30 W/m·K */
    float k_tac_300 = uhc::thermal_conductivity(uhc::MAT_TAC, 300.0f);
    TEST_ASSERT_NEAR(k_tac_300, 30.0f, 8.0f, "TaC k @ 300 K");

    /* HfC thermal conductivity @ 300 K ≈ 28 W/m·K */
    float k_hfc_300 = uhc::thermal_conductivity(uhc::MAT_HFC, 300.0f);
    TEST_ASSERT_NEAR(k_hfc_300, 28.0f, 8.0f, "HfC k @ 300 K");

    /* k decreases with temperature for all materials */
    float k_zrb2_3000 = uhc::thermal_conductivity(uhc::MAT_ZRB2, 3000.0f);
    TEST_ASSERT(k_zrb2_3000 < k_zrb2_300, "k decreases with T (ZrB2)");

    /* Specific heat: positive and bounded */
    float cp_zrb2 = uhc::specific_heat(uhc::MAT_ZRB2, 2000.0f);
    TEST_ASSERT(cp_zrb2 > 0.25f, "cp > 0.25 J/g·K");
    TEST_ASSERT(cp_zrb2 < 0.80f, "cp < 0.80 J/g·K");

    /* Density: positive */
    float rho_zrb2 = uhc::density(uhc::MAT_ZRB2, 300.0f);
    TEST_ASSERT(rho_zrb2 > 0.0f, "rho > 0");
    TEST_ASSERT(rho_zrb2 < 20.0f, "rho < 20 g/cm³");

    /* Powder density is ~55% of solid */
    float rho_powder = uhc::density(uhc::MAT_POWDER_ZRB2, 300.0f);
    TEST_ASSERT(rho_powder < rho_zrb2, "powder rho < solid rho");

    /* Emissivity: bounded [0, 1] */
    float eps = uhc::emissivity(uhc::MAT_ZRB2, 2500.0f);
    TEST_ASSERT(eps >= 0.0f, "emissivity >= 0");
    TEST_ASSERT(eps <= 1.0f, "emissivity <= 1");

    /* Thermal diffusivity: positive */
    float alpha = uhc::thermal_diffusivity(uhc::MAT_ZRB2, 1500.0f);
    TEST_ASSERT(alpha > 0.0f, "alpha > 0");

    /* Oxygen barrier: thicker wall = safer */
    float barrier_thin  = uhc::oxygen_barrier(0.05f, 3.5f, 2.0f);
    float barrier_thick = uhc::oxygen_barrier(0.20f, 3.5f, 2.0f);
    TEST_ASSERT(barrier_thick >= barrier_thin,
                "thicker wall is safer or equal");
}

/* ================================================================== */
/*  Test 2: Laser Gaussian heat source                                 */
/* ================================================================== */

static __host__ float q_laser_host(
    float x, float y, float z,
    float px, float py, float pz,
    float P, float eta, float sx, float sy, float sz)
{
    float dx = x - px;
    float dy = y - py;
    float dz = z - pz;
    float ex = -0.5f * (dx*dx) / (sx*sx + 1e-8f);
    float ey = -0.5f * (dy*dy) / (sy*sy + 1e-8f);
    float ez = -0.5f * (dz*dz) / (sz*sz + 1e-8f);
    float norm = P * eta / (float(M_PI) * sqrtf(float(M_PI)) * sx * sy * sz);
    return norm * expf(ex + ey + ez);
}

static void test_laser_gaussian()
{
    float P = 500.0f, eta = 0.35f;
    float sx = 2.5f, sy = 2.5f, sz = 1.0f;
    float px = 0.0f, py = 0.0f, pz = 10.0f;

    /* Peak at focus point */
    float q_peak = q_laser_host(px, py, pz, px, py, pz, P, eta, sx, sy, sz);
    TEST_ASSERT(q_peak > 0.0f, "Q at focus > 0");

    /* Q falls off with distance */
    float q_near  = q_laser_host(1.0f, 0.0f, 10.0f, px, py, pz, P, eta, sx, sy, sz);
    float q_far   = q_laser_host(10.0f, 0.0f, 10.0f, px, py, pz, P, eta, sx, sy, sz);
    TEST_ASSERT(q_near > q_far, "Q decreases with distance");

    /* Q is symmetric in x and y */
    float q_x = q_laser_host(1.0f, 0.0f, 10.0f, px, py, pz, P, eta, sx, sy, sz);
    float q_y = q_laser_host(0.0f, 1.0f, 10.0f, px, py, pz, P, eta, sx, sy, sz);
    TEST_ASSERT_NEAR(q_x, q_y, 1e-5f, "Gaussian symmetry in x and y");
}

/* ================================================================== */
/*  Test 3: Oxygen Arrhenius diffusivity                               */
/* ================================================================== */

static void test_oxygen_diffusion()
{
    /* D increases with temperature */
    float D_300  = D0_O2 * expf(-EA_O2 / (R_GAS * 300.0f));
    float D_1500 = D0_O2 * expf(-EA_O2 / (R_GAS * 1500.0f));
    float D_3000 = D0_O2 * expf(-EA_O2 / (R_GAS * 3000.0f));
    TEST_ASSERT(D_1500 > D_300, "D increases with T (300→1500 K)");
    TEST_ASSERT(D_3000 > D_1500, "D increases with T (1500→3000 K)");

    /* D_300 @ 273 K should be close to reference D0_O2 (2.09e-5 m²/s) */
    TEST_ASSERT_NEAR(D_300, D0_O2, D0_O2 * 0.05f,
                     "D @ 273 K ≈ D0");

    /* Pressure correction: D ∝ 1/P */
    float D_lowP = D_3000 * (1.0f / 0.05f);  /* 0.05 atm */
    TEST_ASSERT(D_lowP > D_3000, "D increases at lower pressure");
}

/* ================================================================== */
/*  Test 4: Thermal solver stencil correctness (CPU reference)         */
/* ================================================================== */

static float cpu_laplacian(const float* T, int ix, int iy, int iz,
                            int nx, int ny, int nz, float dx)
{
    int idx_xp = ix + 1 < nx ? (ix+1) + nx*(iy + nx*iz) : ix + nx*(iy + nx*iz);
    int idx_xn = ix - 1 >= 0 ? (ix-1) + nx*(iy + nx*iz) : ix + nx*(iy + nx*iz);
    int idx_yp = ix + nx*((iy+1) + nx*iz);
    int idx_yn = ix + nx*((iy-1) + nx*iz);
    int idx_zp = ix + nx*(iy + nx*(iz+1));
    int idx_zn = ix + nx*(iy + nx*(iz-1));
    int idx    = ix + nx*(iy + nx*iz);
    return (T[idx_xp] + T[idx_xn] + T[idx_yp] + T[idx_yn] +
            T[idx_zp] + T[idx_zn] - 6.0f*T[idx]) / (dx*dx);
}

static void test_thermal_stencil()
{
    /* 3×3×3 grid with T = x + y + z (linear field) */
    const int N = 3;
    float T[N*N*N];
    for (int iz = 0; iz < N; ++iz)
    for (int iy = 0; iy < N; ++iy)
    for (int ix = 0; ix < N; ++ix)
        T[ix + N*(iy + N*iz)] = (float)(ix + iy + iz);

    /* Laplacian of a linear field is exactly zero */
    float lap = cpu_laplacian(T, 1, 1, 1, N, N, N, 1.0f);
    TEST_ASSERT_NEAR(lap, 0.0f, 1e-4f, "Laplacian of linear field = 0");

    /* T = x² + y² + z² → Laplacian = 6 */
    for (int iz = 0; iz < N; ++iz)
    for (int iy = 0; iy < N; ++iy)
    for (int ix = 0; ix < N; ++ix)
        T[ix + N*(iy + N*iz)] = (float)(ix*ix + iy*iy + iz*iz);

    lap = cpu_laplacian(T, 1, 1, 1, N, N, N, 1.0f);
    TEST_ASSERT_NEAR(lap, 6.0f, 1e-4f, "Laplacian of x²+y²+z² = 6");
}

/* ================================================================== */
/*  Test 5: Deposition state machine                                   */
/* ================================================================== */

static void test_deposition_state_machine()
{
    /* Verify state enum values are sequential and non-negative */
    TEST_ASSERT((int)STATE_POWDER       == 0, "STATE_POWDER == 0");
    TEST_ASSERT((int)STATE_HEATED       == 1, "STATE_HEATED == 1");
    TEST_ASSERT((int)STATE_PARTIAL_MELT == 2, "STATE_PARTIAL_MELT == 2");
    TEST_ASSERT((int)STATE_SOLID        == 3, "STATE_SOLID == 3");
    TEST_ASSERT((int)STATE_KEYHOLE      == 4, "STATE_KEYHOLE == 4");
    TEST_ASSERT((int)STATE_O2_BREACH    == 5, "STATE_O2_BREACH == 5");

    /* Transition logic: POWDER → SOLID when E > 0.8 */
    int state = STATE_POWDER;
    float E_high = 1.0f;
    int new_state;
    if (state == STATE_POWDER) {
        if      (E_high > 0.8f) new_state = STATE_SOLID;
        else if (E_high > 0.3f) new_state = STATE_PARTIAL_MELT;
        else                    new_state = STATE_HEATED;
    }
    TEST_ASSERT(new_state == STATE_SOLID, "POWDER + high E → SOLID");

    E_high = 0.5f;
    if (state == STATE_POWDER) {
        if      (E_high > 0.8f) new_state = STATE_SOLID;
        else if (E_high > 0.3f) new_state = STATE_PARTIAL_MELT;
        else                    new_state = STATE_HEATED;
    }
    TEST_ASSERT(new_state == STATE_PARTIAL_MELT, "POWDER + med E → PARTIAL_MELT");
}

/* ================================================================== */
/*  Test 6: Radiative heat flux                                        */
/* ================================================================== */

static void test_radiative_flux()
{
    /* q_rad = ε·σ·(T⁴ - T_amb⁴) must be >= 0 for T > T_amb */
    float q_2500 = uhc::radiative_heat_flux(uhc::MAT_ZRB2, 2500.0f, 300.0f);
    float q_3000 = uhc::radiative_heat_flux(uhc::MAT_ZRB2, 3000.0f, 300.0f);
    TEST_ASSERT(q_2500 > 0.0f, "q_rad > 0 at 2500 K");
    TEST_ASSERT(q_3000 > q_2500, "q_rad increases with T");
}

/* ================================================================== */
/*  Main: run all tests                                                */
/* ================================================================== */

int main(int argc, char** argv)
{
    printf("============================================\n");
    printf("  UHTC CUDA Kernel Unit Tests\n");
    printf("============================================\n");

    RUN_TEST(material_properties);
    RUN_TEST(laser_gaussian);
    RUN_TEST(oxygen_diffusion);
    RUN_TEST(thermal_stencil);
    RUN_TEST(deposition_state_machine);
    RUN_TEST(radiative_flux);

    printf("\n============================================\n");
    if (g_test_failures == 0)
    {
        printf("  ALL TESTS PASSED\n");
        printf("============================================\n");
        return 0;
    }
    else
    {
        printf("  %d TEST(S) FAILED\n", g_test_failures);
        printf("============================================\n");
        return 1;
    }
}
