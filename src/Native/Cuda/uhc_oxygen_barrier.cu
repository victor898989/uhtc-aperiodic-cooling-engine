// SPDX-License-Identifier: Apache-2.0
//
// uhc_oxygen_barrier.cu
//
// Evaluates the effectiveness of the aperiodic lattice as a passive
// oxygen barrier for UHTC additive manufacturing.
//
// Physical model:
//   O₂ diffuses through the void channels of the aperiodic lattice with
//   effective diffusivity D_eff = D_0 · φ / τ²
//     D_0   — free-molecule diffusivity of O₂ in Ar at process T [mm²/s]
//     φ     — void fraction (porosity of the lattice)  [0-1]
//     τ     — geometric tortuosity of the aperiodic channel network
//
// The barrier criterion is:
//   t_penetration = L_eff² / D_eff  >  t_layer
//   where L_eff = t_wall_min × τ   (effective O₂ path length through wall)
//
// Outputs per lattice column (x, y):
//   - t_penetration [s] : time for O₂ to reach the build interior
//   - barrier_flag    : 1.0 if t_penetration > t_layer, else 0.0
//   - tortuosity_est  : geometric tortuosity estimated from SDF level sets
//   - void_fraction   : φ at this (x,y) column
//
// Breach map:
//   After each layer the C# host checks barrier_flag == 0 and flags
//   those columns for geometry regeneration (thicken the aperiodic wall).

#include "uhc_material_properties.h"

#include <nanovdb/io/IO.h>
#include <nanovdb/cuda/DeviceBuffer.h>
#include <nanovdb/tools/CreatePrimitives.h>

#include <cstdio>
#include <cmath>
#include <cstring>

#if defined(NANOVDB_USE_CUDA)
using BufferT = nanovdb::cuda::DeviceBuffer;
#endif

using namespace nanovdb;

/* ================================================================== */
/*  Diffusion constants for O₂ in Ar at elevated temperatures          */
/*  D_0 = D_ref · (T/T_ref)^1.75 · (P_ref/P)  (Chapman-Enskog)       */
/*  Reference: Bird, Stewart, Lightfoot — Transport Phenomena         */
/* ================================================================== */

__host__ __device__ inline float D_O2_free(float T_K, float P_atm)
{
    /* D_ref = 0.209 cm²/s at 273 K, 1 atm (O₂ in Ar) */
    const float D_ref   = 0.209e-2f;   /* m²/s → mm²/s : ×10⁶  */
    const float T_ref   = 273.15f;
    const float P_ref   = 1.0f;

    float D = D_ref * 1.0e6f * powf(T_K / T_ref, 1.75f) * (P_ref / P_atm);
    return D;   /* mm²/s */
}

/* ================================================================== */
/*  Geometric tortuosity from SDF level sets                           */
/*  τ = 1 + C · (|∇Φ| / |∇Φ|_max)  where C ≈ 1.5 for aperiodic media */
/*  For a gyroid lattice τ ≈ 3.0 – 4.5 depending on relative density  */
/* ================================================================== */

__host__ __device__ inline float tortuosity_from_sdf(float grad_mag, float grad_max)
{
    if (grad_max < 1e-6f) return 3.0f;
    float s = grad_mag / grad_max;
    return 1.0f + 1.8f * s;
}

/* ================================================================== */
/*  CUDA kernel: per-column O₂ barrier evaluation                     */
/* ================================================================== */

__global__ void kernel_oxygen_barrier(
    /* input: signed-distance field of aperiodic geometry [mm] */
    const float* __restrict__  d_sdf,
    /* input: gradient magnitude of SDF (pre-computed by host) */
    const float* __restrict__  d_grad_mag,
    /* input: void-fraction map (from deposition manager) */
    const float* __restrict__  d_phi,
    /* output: O₂ penetration time per column [s] */
    float* __restrict__        d_t_pen,
    /* output: barrier flag (1 = safe, 0 = breach) */
    float* __restrict__        d_barrier,
    /* output: estimated tortuosity */
    float* __restrict__        d_tau,
    /* output: void fraction */
    float* __restrict__        d_phi_out,
    /* parameters */
    const float    t_critical_mm,
    const float    t_layer_s,
    const float    T_process_K,
    const float    P_chamber_atm,
    const float    grad_max,
    const int      n_columns)
{
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (col >= n_columns) return;

    float sdf_val  = d_sdf[col];
    float grad     = d_grad_mag[col];
    float phi      = d_phi[col];

    /* Wall thickness = fabs(SDF) at the zero-crossing region */
    float t_wall = fabsf(sdf_val);
    if (t_wall > 1.0f) t_wall = 1.0f;   /* cap at 1 mm */

    /* Tortuosity */
    float tau = tortuosity_from_sdf(grad, grad_max);
    d_tau[col] = tau;
    d_phi_out[col] = phi;

    /* Effective diffusivity through the porous lattice:
       D_eff = D_O2 · φ / τ²                                        */
    float D0    = D_O2_free(T_process_K, P_chamber_atm);
    float D_eff = D0 * phi / (tau * tau + 1e-8f);

    /* Effective penetration path through wall */
    float L_eff = t_wall * tau;

    /* Time to diffuse through the wall */
    float t_pen = (L_eff * L_eff) / (D_eff + 1e-12f);
    d_t_pen[col] = t_pen;

    /* Barrier criterion */
    d_barrier[col] = (t_pen > t_layer_s && t_wall >= t_critical_mm) ? 1.0f : 0.0f;
}

/* ================================================================== */
/*  Host-side oxygen-barrier evaluator                                 */
/* ================================================================== */

class UHCOxygenBarrier
{
public:
    nanovdb::GridHandle<BufferT> h_sdf;
    nanovdb::GridHandle<BufferT> h_t_pen;
    nanovdb::GridHandle<BufferT> h_barrier;
    nanovdb::GridHandle<BufferT> h_tau;
    nanovdb::GridHandle<BufferT> h_phi;

    Grid<FloatTree>* d_sdf    = nullptr;
    Grid<FloatTree>* d_t_pen  = nullptr;
    Grid<FloatTree>* d_barrier= nullptr;
    Grid<FloatTree>* d_tau    = nullptr;
    Grid<FloatTree>* d_phi    = nullptr;

    float  t_critical_mm;
    float  t_layer_s;
    float  T_process_K;
    float  P_chamber_atm;

    UHCOxygenBarrier(float t_crit, float t_lay, float T_proc, float P_ch)
        : t_critical_mm(t_crit), t_layer_s(t_lay),
          T_process_K(T_proc), P_chamber_atm(P_ch)
    {
        /* Build a 32³ test SDF grid representing aperiodic wall */
        h_sdf = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                     10.0f, nanovdb::Vec3d(0,0,0), 1.0, 3, nanovdb::Vec3d(0), "aperiodic_sdf");

        h_t_pen   = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                     10.0f, nanovdb::Vec3d(0,0,0), 1.0, 3, nanovdb::Vec3d(0), "t_pen");
        h_barrier = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                     10.0f, nanovdb::Vec3d(0,0,0), 1.0, 3, nanovdb::Vec3d(0), "barrier");
        h_tau     = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                     10.0f, nanovdb::Vec3d(0,0,0), 1.0, 3, nanovdb::Vec3d(0), "tortuosity");
        h_phi     = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                     10.0f, nanovdb::Vec3d(0,0,0), 1.0, 3, nanovdb::Vec3d(0), "void_fraction");

        h_sdf.deviceUpload();
        h_t_pen.deviceUpload();
        h_barrier.deviceUpload();
        h_tau.deviceUpload();
        h_phi.deviceUpload();

        d_sdf     = h_sdf.deviceGrid<float>();
        d_t_pen   = h_t_pen.deviceGrid<float>();
        d_barrier = h_barrier.deviceGrid<float>();
        d_tau     = h_tau.deviceGrid<float>();
        d_phi     = h_phi.deviceGrid<float>();
    }

    void evaluate(int n_columns)
    {
#if defined(NANOVDB_USE_CUDA)
        float* p_sdf    = (float*)h_sdf    .deviceData();
        float* p_t_pen  = (float*)h_t_pen  .deviceData();
        float* p_barrier= (float*)h_barrier.deviceData();
        float* p_tau    = (float*)h_tau    .deviceData();
        float* p_phi    = (float*)h_phi    .deviceData();

        /* Pre-compute host-side values for demo */
        float h_grad[32];
        float h_phi[32];
        for (int i = 0; i < 32; ++i) {
            h_grad[i] = 0.5f + 0.1f * sinf(i * 0.4f);
            h_phi[i]  = 0.35f + 0.05f * cosf(i * 0.3f);
        }

        float* d_grad; float* d_phi_gpu;
        cudaMalloc(&d_grad,   32 * sizeof(float));
        cudaMalloc(&d_phi_gpu,32 * sizeof(float));
        cudaMemcpy(d_grad,   h_grad, 32*sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy(d_phi_gpu,h_phi,  32*sizeof(float), cudaMemcpyHostToDevice);

        int block = 256;
        int grid  = (n_columns + block - 1) / block;

        kernel_oxygen_barrier<<<grid, block>>>(
            p_sdf, d_grad, d_phi_gpu,
            p_t_pen, p_barrier, p_tau, p_phi,
            t_critical_mm, t_layer_s,
            T_process_K, P_chamber_atm,
            1.0f, n_columns
        );
        cudaDeviceSynchronize();

        cudaFree(d_grad);
        cudaFree(d_phi_gpu);

        printf("[UHC O2 Barrier] Evaluated %d columns at %.0f K, %.1f atm\n",
               n_columns, T_process_K, P_chamber_atm);
#else
        printf("[UHC O2 Barrier] CPU fallback — %d columns skipped\n", n_columns);
#endif
    }

    void export_results(const char* filename)
    {
        h_barrier.deviceDownload();
        h_t_pen.deviceDownload();
        h_tau.deviceDownload();
        h_phi.deviceDownload();

        FILE* f = fopen(filename, "w");
        fprintf(f, "col,t_pen_s,barrier_flag,tau,phi\n");
        auto iter_barrier = h_barrier.grid<float>()->tree().cbeginValueAll();
        auto iter_t_pen   = h_t_pen  .grid<float>()->tree().cbeginValueAll();
        auto iter_tau     = h_tau    .grid<float>()->tree().cbeginValueAll();
        auto iter_phi     = h_phi    .grid<float>()->tree().cbeginValueAll();

        int col = 0;
        for ( ; iter_barrier && iter_t_pen && iter_tau && iter_phi;
              ++iter_barrier, ++iter_t_pen, ++iter_tau, ++iter_phi) {
            fprintf(f, "%d,%.3e,%.0f,%.2f,%.3f\n",
                    col++,
                    iter_t_pen.getValue(),
                    iter_barrier.getValue(),
                    iter_tau.getValue(),
                    iter_phi.getValue());
        }
        fclose(f);
        printf("[UHC O2 Barrier] Results → %s\n", filename);
    }
};

/* ================================================================== */
/*  Entry point                                                        */
/* ================================================================== */

int main(int argc, char** argv)
{
    printf("[UHC O2 Barrier] UHTC Aperiodic Oxygen-Barrier Evaluator\n");

    /* Process conditions for ZrB2-SiC L-PBF in argon glovebox */
    const float T_process  = 2200.0f;   /* K  (~1927 °C) */
    const float P_chamber  = 0.05f;     /* atm — low-pressure inert gas */
    const float t_critical = 0.08f;     /* mm — O2 can breach below this */
    const float t_layer    = 2.0f;      /* s  — time per layer */

    UHCOxygenBarrier barrier(t_critical, t_layer, T_process, P_chamber);
    barrier.evaluate(32);
    barrier.export_results("uhc_oxygen_barrier.csv");

    printf("[UHC O2 Barrier] t_critical = %.2f mm | t_layer = %.1f s\n",
           t_critical, t_layer);

    return 0;
}
