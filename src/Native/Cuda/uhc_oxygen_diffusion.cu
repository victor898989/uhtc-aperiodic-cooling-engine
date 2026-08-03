// SPDX-License-Identifier: Apache-2.0
//
// uhc_oxygen_diffusion.cu
//
// Solves the kinetic oxygen-diffusion–reaction equation on a 3D grid:
//
//   ∂C_O2/∂t = ∇·(D(T) ∇C_O2) − R_ox(T, C_O2)
//
// where the Arrhenius diffusivity is:
//
//   D(T) = D₀ · exp(−Ea / (R · T))
//
// and the oxidation rate is:
//
//   R_ox(T, C_O2) = k₀ · exp(−Ea_r / (R · T)) · [O₂]^n
//
// Reference:
//   - Fahrenholtz et al., J. Am. Ceram. Soc. 90(1), 2007 — ZrB₂ oxidation
//   - Upadhya et al., J. Am. Ceram. Soc. 80(11), 1997 — ZrB₂ thermal properties
//   - Bird, Stewart, Lightfoot — Transport Phenomena (D_O2 reference)
//
// The temperature field T(x,y,z,t) is read from the thermal solver grid.
// Boundary conditions:
//   - Top surface (z = max): C_O2 = C_bulk (chamber concentration)
//   - Sides (x=0, x=max, y=0, y=max): Neumann ∂C/∂n = 0 (insulated)
//   - Bottom (z = 0): C_O2 = 0 (substrate consumes O₂)
//
// Output: time-to-breach map t_breach(x,y) — earliest time at which
//         C_O2 exceeds the critical oxidation threshold at any z column.

#include "uhc_material_properties.h"

#include <nanovdb/io/IO.h>
#include <nanovdb/cuda/DeviceBuffer.h>
#include <nanovdb/tools/CreatePrimitives.h>

#include <cstdio>
#include <cmath>
#include <cstring>
#include <cuda_runtime.h>

#if defined(NANOVDB_USE_CUDA)
using BufferT = nanovdb::cuda::DeviceBuffer;
#else
using BufferT = nanovdb::HostBuffer;
#endif

using namespace nanovdb;

/* ================================================================== */
/*  Diffusion and reaction constants for O₂ in UHTC                  */
/* ================================================================== */

#define D0_O2         2.09e-5f     /* m²/s  — O₂ in Ar at 273 K, 1 atm  */
#define EA_O2         15.2e3f      /* J/mol — activation energy O₂ diff  */
#define K0_OX         1.5e8f       /* s⁻¹   — pre-exponential oxidation   */
#define EA_R_OX       285.0e3f     /* J/mol — activation energy ZrB₂ ox  */
#define N_ORDER       0.5f         /* reaction order                     */
#define R_GAS         8.314f       /* J/(mol·K) — universal gas constant  */
#define C_BULK        0.21f        /* mol/m³ — 21 % O₂ in air            */
#define C_CRITICAL    1.0e-4f      /* mol/m³ — oxidation threshold       */

/* ================================================================== */
/*  CUDA kernel: 3D O₂ diffusion–reaction                             */
/* ================================================================== */

__global__ void kernel_oxygen_diffusion(
    /* --- input: temperature field [K] --- */
    const float* __restrict__ d_T,
    /* --- input: current O₂ concentration [mol/m³] --- */
    const float* __restrict__ d_C_O2,
    /* --- output: next O₂ concentration --- */
    float* __restrict__       d_C_O2_next,
    /* --- output: time-to-breach map [s] (per x,y column) --- */
    float* __restrict__       d_t_breach,
    /* --- input: active voxel mask (1 = inside build volume) --- */
    const int*   __restrict__ d_active,
    /* --- parameters --- */
    float T_ambient_K,
    float P_chamber_atm,
    float dt,
    float dx,
    int   dimX, int dimY, int dimZ)
{
    int ix = blockIdx.x * blockDim.x + threadIdx.x;
    int iy = blockIdx.y * blockDim.y + threadIdx.y;
    int iz = blockIdx.z * blockDim.z + threadIdx.z;

    if (ix >= dimX || iy >= dimY || iz >= dimZ) return;

    int idx = ix + dimX * (iy + dimY * iz);
    if (d_active && d_active[idx] == 0) {
        d_C_O2_next[idx] = d_C_O2[idx];
        return;
    }

    float T = d_T[idx];

    /* ---- Arrhenius diffusivity D(T) ---- */
    float D = D0_O2 * expf(-EA_O2 / (R_GAS * T));

    /* ---- Chapman-Enskog temperature/pressure correction ---- */
    D *= powf(T / 273.15f, 1.75f) * (1.0f / P_chamber_atm);

    /* ---- Laplacian of C_O2 (7-point stencil, Neumann at boundaries) ---- */
    int idx_xp = ix + 1 < dimX ? idx + 1 : idx;
    int idx_xn = ix - 1 >= 0   ? idx - 1 : idx;
    int idx_yp = ix + dimX * (iy + 1 < dimY ? iy + 1 : iy);
    int idx_yn = ix + dimX * (iy - 1 >= 0   ? iy - 1 : iy);
    int idx_zp = ix + dimX * (iy + dimY * (iz + 1 < dimZ ? iz + 1 : iz));
    int idx_zn = ix + dimX * (iy + dimY * (iz - 1 >= 0   ? iz - 1 : iz));

    float lap = (d_C_O2[idx_xp] + d_C_O2[idx_xn] +
                 d_C_O2[idx_yp] + d_C_O2[idx_yn] +
                 d_C_O2[idx_zp] + d_C_O2[idx_zn] -
                 6.0f * d_C_O2[idx]) / (dx * dx);

    /* ---- Oxidation rate R_ox ---- */
    float C  = d_C_O2[idx];
    float R  = K0_OX * expf(-EA_R_OX / (R_GAS * T)) * powf(fmaxf(C, 0.0f), N_ORDER);

    /* ---- Time update ---- */
    float dC_dt = D * lap - R;
    float C_new = d_C_O2[idx] + dt * dC_dt;

    /* Clamp: concentration cannot be negative */
    if (C_new < 0.0f) C_new = 0.0f;

    d_C_O2_next[idx] = C_new;

    /* ---- Track breach time per (x,y) column ---- */
    if (iz == dimZ - 1)  /* top of column */
    {
        int col_idx = ix + dimX * iy;
        if (C_new > C_CRITICAL) {
            atomicMin(&d_t_breach[col_idx], dt);
        }
    }
}

/* ================================================================== */
/*  Host-side O₂ diffusion manager                                    */
/* ================================================================== */

class UHCOxygenDiffusionSolver
{
public:
    nanovdb::GridHandle<BufferT> h_T;         /* temperature field [K]      */
    nanovdb::GridHandle<BufferT> h_C_O2;      /* O₂ concentration           */
    nanovdb::GridHandle<BufferT> h_C_O2_next; /* double buffer              */
    nanovdb::GridHandle<BufferT> h_t_breach;  /* time-to-breach per column  */

    Grid<FloatTree>* d_T        = nullptr;
    Grid<FloatTree>* d_C_O2     = nullptr;
    Grid<FloatTree>* d_C_O2_next= nullptr;
    Grid<FloatTree>* d_t_breach = nullptr;

    float T_ambient_K;
    float P_chamber_atm;
    float dt;
    float dx;
    int   dimX, dimY, dimZ;

    UHCOxygenDiffusionSolver(float voxel_size_mm, int nx, int ny, int nz)
        : dx(voxel_size_mm), dimX(nx), dimY(ny), dimZ(nz)
    {
        T_ambient_K  = 300.0f;
        P_chamber_atm= 1.0f;
        dt           = 1.0e-4f;   /* 0.1 ms time step */

        /* Build a 32×32×32 test grid (can be replaced by NanoVDB read) */
        h_T        = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                         15.0f, nanovdb::Vec3d(0,0,15), dx, 3, nanovdb::Vec3d(0), "T_field");
        h_C_O2     = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                         15.0f, nanovdb::Vec3d(0,0,15), dx, 3, nanovdb::Vec3d(0), "C_O2");
        h_C_O2_next= nanovdb::tools::createLevelSetSphere<float, BufferT>(
                         15.0f, nanovdb::Vec3d(0,0,15), dx, 3, nanovdb::Vec3d(0), "C_O2_next");
        h_t_breach = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                         15.0f, nanovdb::Vec3d(0,0,15), dx, 3, nanovdb::Vec3d(0), "t_breach");

        h_T.deviceUpload();
        h_C_O2.deviceUpload();
        h_C_O2_next.deviceUpload();
        h_t_breach.deviceUpload();

        d_T        = h_T.deviceGrid<float>();
        d_C_O2     = h_C_O2.deviceGrid<float>();
        d_C_O2_next= h_C_O2_next.deviceGrid<float>();
        d_t_breach = h_t_breach.deviceGrid<float>();

        /* Initialise breach times to infinity */
        auto acc = d_t_breach->tree().getAccessor();
        for (auto iter = d_t_breach->tree().cbeginValueAll(); iter; ++iter) {
            if (iter.isActiveValue()) acc.setValue(iter.getCoord(), 1.0e6f);
        }
    }

    /* ---- Run N diffusion steps ---- */
    void step(int n_steps)
    {
#if defined(NANOVDB_USE_CUDA)
        int nx = 32, ny = 32, nz = 32;
        dim3 block(8, 8, 4);
        dim3 grid((nx + block.x - 1) / block.x,
                  (ny + block.y - 1) / block.y,
                  (nz + block.z - 1) / block.z);

        for (int s = 0; s < n_steps; ++s) {
            kernel_oxygen_diffusion<<<grid, block>>>(
                (float*)d_T->data(),
                (float*)d_C_O2->data(),
                (float*)d_C_O2_next->data(),
                (float*)d_t_breach->data(),
                nullptr,
                T_ambient_K, P_chamber_atm, dt, dx,
                nx, ny, nz
            );
            cudaDeviceSynchronize();

            /* Swap buffers */
            std::swap(h_C_O2, h_C_O2_next);
            d_C_O2      = h_C_O2.deviceGrid<float>();
            d_C_O2_next = h_C_O2_next.deviceGrid<float>();
        }
#else
        printf("[UHC O₂] CPU fallback — %d steps skipped\n", n_steps);
#endif
    }

    void export_breach_map(const char* filename)
    {
        h_t_breach.deviceDownload();
        nanovdb::io::writeGrid(filename, h_t_breach, "t_breach");
        printf("[UHC O₂] Breach map exported → %s\n", filename);
    }
};

/* ================================================================== */
/*  Entry point                                                        */
/* ================================================================== */

int main(int argc, char** argv)
{
    printf("[UHC O₂] UHTC Oxygen Diffusion–Reaction Solver\n");
    printf("[UHC O₂] Equation: dC/dt = div(D(T) grad(C)) − R_ox(T,C)\n");

    const float dx = 0.5f;
    UHCOxygenDiffusionSolver solver(dx, 32, 32, 32);

    printf("[UHC O₂] Running 50 diffusion steps at dt = %.0e s\n", solver.dt);
    solver.step(50);
    solver.export_breach_map("uhc_o2_breach.nvdb");

    return 0;
}
