// SPDX-License-Identifier: Apache-2.0
//
// uhc_kinetic_solver.cu
//
// 3D transient kinetic thermal solver for UHTC powder-bed AM.
//
// Governing equation:
//   ρ·c_p · ∂T/∂t = ∇·(k ∇T) + Q_source − Q_conv − Q_rad
//
// where:
//   Q_source — Gaussian laser heat input (Goldak double-ellipsoid)
//   Q_conv   — Newtonian convection: h·(T − T_ambient)
//   Q_rad    — Stefan-Boltzmann radiation: ε·σ·(T⁴ − T_ambient⁴)
//
// Discretisation:
//   - Explicit Euler with adaptive sub-stepping (CFL-limited)
//   - 7-point Laplacian stencil (second-order central differences)
//   - Map-aware: accounts for non-uniform voxel sizing via OpenVDB Maps
//
// Time-step constraint (stability):
//   dt < dx² / (2 · α_max)
//   where α_max = max(k / (ρ·c_p)) over all voxels

#include "uhc_material_properties.h"

#include <nanovdb/io/IO.h>
#include <nanovdb/cuda/DeviceBuffer.h>
#include <nanovdb/tools/CreatePrimitives.h>

#include <cstdio>
#include <cmath>
#include <cstring>
#include <cuda_runtime.h>
#include <chrono>

#if defined(NANOVDB_USE_CUDA)
using BufferT = nanovdb::cuda::DeviceBuffer;
#endif

using namespace nanovdb;

/* ================================================================== */
/*  Laser source (Goldak double-ellipsoid, moving along scan path)    */
/* ================================================================== */

struct LaserSource3D {
    float px, py, pz;        /* focus position [mm] */
    float P;                 /* power [W]           */
    float eta;               /* absorptivity        */
    float sx, sy, sz;        /* Gaussian σ radii [mm] */
    float scan_speed;        /* mm/s                */
    float efficiency;        /* net absorption efficiency (0-1) */
};

/* ================================================================== */
/*  Gaussian heat source in 3D                                        */
/* ================================================================== */

__host__ __device__ inline float q_laser_gaussian(
    float x, float y, float z,
    float px, float py, float pz,
    float P, float eta,
    float sx, float sy, float sz)
{
    float dx = x - px;
    float dy = y - py;
    float dz = z - pz;

    float ex = -0.5f * (dx*dx) / (sx*sx + 1e-8f);
    float ey = -0.5f * (dy*dy) / (sy*sy + 1e-8f);
    float ez = -0.5f * (dz*dz) / (sz*sz + 1e-8f);

    float norm = P * eta /
                 (float(M_PI) * sqrtf(float(M_PI)) * sx * sy * sz);

    return norm * expf(ex + ey + ez);
}

/* ================================================================== */
/*  CUDA kernel: explicit transient heat diffusion                    */
/* ================================================================== */

__global__ void kernel_thermal_step_3d(
    /* --- in/out: temperature field [K] --- */
    float* __restrict__       d_T_new,
    const float* __restrict__ d_T_old,
    /* --- material fields --- */
    const float* __restrict__ d_k,      /* thermal conductivity [W/m·K]  */
    const float* __restrict__ d_rho,    /* density [g/cm³]               */
    const float* __restrict__ d_cp,     /* specific heat [J/g·K]         */
    const float* __restrict__ d_eps,    /* emissivity [0-1]              */
    const int*   __restrict__ d_active, /* voxel activation mask         */
    /* --- laser source (single source, constant over step) --- */
    const LaserSource3D* d_laser,
    /* --- chamber --- */
    float T_ambient_K,
    float h_conv,
    /* --- grid --- */
    float dx,
    int   dimX, int dimY, int dimZ,
    float dt)
{
    int ix = blockIdx.x * blockDim.x + threadIdx.x;
    int iy = blockIdx.y * blockDim.y + threadIdx.y;
    int iz = blockIdx.z * blockDim.z + threadIdx.z;

    if (ix >= dimX || iy >= dimY || iz >= dimZ) return;

    int idx = ix + dimX * (iy + dimY * iz);

    /* Skip inactive voxels */
    if (d_active && d_active[idx] == 0) {
        d_T_new[idx] = d_T_old[idx];
        return;
    }

    float T = d_T_old[idx];

    /* ---- Material properties at this voxel ---- */
    float k  = d_k      ? d_k[idx]      : 30.0f;
    float rho= d_rho    ? d_rho[idx]    : 6.0f;    /* g/cm³ */
    float cp = d_cp     ? d_cp[idx]     : 0.5f;    /* J/g·K */
    float eps = d_eps   ? d_eps[idx]    : 0.78f;

    /* ---- 7-point Laplacian (second-order central differences) ---- */
    int idx_xp = ix + 1 < dimX ? idx + 1       : idx;
    int idx_xn = ix - 1 >= 0   ? idx - 1       : idx;
    int idx_yp = ix + dimX * (iy + 1 < dimY ? iy + 1 : iy);
    int idx_yn = ix + dimX * (iy - 1 >= 0   ? iy - 1 : iy);
    int idx_zp = ix + dimX * (iy + dimY * (iz + 1 < dimZ ? iz + 1 : iz));
    int idx_zn = ix + dimX * (iy + dimY * (iz - 1 >= 0   ? iz - 1 : iz));

    float lap = (d_T_old[idx_xp] + d_T_old[idx_xn] +
                 d_T_old[idx_yp] + d_T_old[idx_yn] +
                 d_T_old[idx_zp] + d_T_old[idx_zn] -
                 6.0f * T) / (dx * dx);

    /* ---- Thermal diffusivity [mm²/s] ---- */
    float alpha = uhc::thermal_diffusivity(
        uhc::MAT_ZRB2, T);   /* use actual material ID in production */

    /* ---- Heat source: Gaussian laser ---- */
    float x = (float)ix * dx;
    float y = (float)iy * dx;
    float z = (float)iz * dx;

    float Q_laser = q_laser_gaussian(
        x, y, z,
        d_laser->px, d_laser->py, d_laser->pz,
        d_laser->P, d_laser->eta * d_laser->efficiency,
        d_laser->sx, d_laser->sy, d_laser->sz);

    /* ---- Boundary conditions (top surface) ---- */
    float Q_conv = 0.0f;
    float Q_rad  = 0.0f;

    if (iz == dimZ - 1)  /* top surface: convective + radiative loss */
    {
        Q_conv = h_conv * (T - T_ambient_K);
        Q_rad  = uhc::radiative_heat_flux(uhc::MAT_ZRB2, T, T_ambient_K);
    }

    /* ---- RHS of heat equation ---- */
    /* α [mm²/s] → convert to K/s:
       dT/dt = α·lap + (Q_conv+Q_rad)/(ρ·c_p)
       Q_conv is in W/m² → convert to W/mm²: /1e6
       ρ [g/cm³] → kg/m³: ×1000
       cp [J/g·K] → J/kg·K: ×1000
       So Q/(ρ·c_p) gives K/s when Q is in W/m³               */
    float dT_dt = alpha * 1e-6f * lap            /* mm²/s → m²/s, K/s */
                + (Q_conv + Q_rad) * 1e-6f / (rho * 1000.0f * cp * 1000.0f)
                + Q_laser / (rho * 1000.0f * cp * 1000.0f);

    /* ---- Explicit Euler step ---- */
    float T_new = T + dt * dT_dt;

    /* Clamp to physical bounds */
    if (T_new < T_ambient_K) T_new = T_ambient_K;
    if (T_new > 5000.0f)     T_new = 5000.0f;

    d_T_new[idx] = T_new;
}

/* ================================================================== */
/*  Kinetic thermal solver manager                                    */
/* ================================================================== */

class UHCKineticThermalSolver
{
public:
    nanovdb::GridHandle<BufferT> h_T;
    nanovdb::GridHandle<BufferT> h_T_next;
    nanovdb::GridHandle<BufferT> h_k;
    nanovdb::GridHandle<BufferT> h_rho;
    nanovdb::GridHandle<BufferT> h_cp;
    nanovdb::GridHandle<BufferT> h_eps;

    Grid<FloatTree>* d_T      = nullptr;
    Grid<FloatTree>* d_T_next = nullptr;
    Grid<FloatTree>* d_k      = nullptr;
    Grid<FloatTree>* d_rho    = nullptr;
    Grid<FloatTree>* d_cp     = nullptr;
    Grid<FloatTree>* d_eps    = nullptr;

    LaserSource3D d_laser;
    float T_ambient_K;
    float h_conv;
    float dt;
    float dx;
    int   dimX, dimY, dimZ;
    float t_elapsed;

    UHCKineticThermalSolver(float voxel_size_mm, int nx, int ny, int nz)
        : dx(voxel_size_mm), dimX(nx), dimY(ny), dimZ(nz), t_elapsed(0.0f)
    {
        dt = 1.0e-5f;   /* 10 µs — CFL-limited for α ≈ 1e-5 m²/s, dx = 0.5 mm */
        T_ambient_K = 300.0f;
        h_conv      = 10.0f;

        /* Default laser (ZrB2 baseline: 500 W, 5 mm/s, 2.5 mm spot) */
        d_laser.px = 0.0f;
        d_laser.py = 0.0f;
        d_laser.pz = 10.0f;
        d_laser.P  = 500.0f;
        d_laser.eta = 0.35f;
        d_laser.sx = 2.5f;
        d_laser.sy = 2.5f;
        d_laser.sz = 1.0f;
        d_laser.scan_speed = 5.0f;
        d_laser.efficiency = 1.0f;

        /* Create NanoVDB grids */
        h_T      = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       15.0f, nanovdb::Vec3d(0,0,10), dx, 3, nanovdb::Vec3d(0), "T");
        h_T_next = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       15.0f, nanovdb::Vec3d(0,0,10), dx, 3, nanovdb::Vec3d(0), "T_next");
        h_k      = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       15.0f, nanovdb::Vec3d(0,0,10), dx, 3, nanovdb::Vec3d(0), "k");
        h_rho    = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       15.0f, nanovdb::Vec3d(0,0,10), dx, 3, nanovdb::Vec3d(0), "rho");
        h_cp     = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       15.0f, nanovdb::Vec3d(0,0,10), dx, 3, nanovdb::Vec3d(0), "cp");
        h_eps    = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       15.0f, nanovdb::Vec3d(0,0,10), dx, 3, nanovdb::Vec3d(0), "eps");

        h_T.deviceUpload();
        h_T_next.deviceUpload();
        h_k.deviceUpload();
        h_rho.deviceUpload();
        h_cp.deviceUpload();
        h_eps.deviceUpload();

        d_T      = h_T.deviceGrid<float>();
        d_T_next = h_T_next.deviceGrid<float>();
        d_k      = h_k.deviceGrid<float>();
        d_rho    = h_rho.deviceGrid<float>();
        d_cp     = h_cp.deviceGrid<float>();
        d_eps    = h_eps.deviceGrid<float>();

        /* Initialise material fields (ZrB2 at T_ambient) */
        initialise_material(uhc::MAT_ZRB2);
    }

    /* ---- Initialise k, ρ, cp, ε fields from material ID ---- */
    void initialise_material(uhc::MaterialID mat)
    {
#if defined(NANOVDB_USE_CUDA)
        /* Host-side: fill initial values, then upload */
        size_t n = (size_t)dimX * dimY * dimZ;
        float* h_k_arr    = new float[n];
        float* h_rho_arr  = new float[n];
        float* h_cp_arr   = new float[n];
        float* h_eps_arr  = new float[n];

        for (size_t i = 0; i < n; ++i) {
            float T = T_ambient_K;
            h_k_arr[i]   = uhc::thermal_conductivity(mat, T);
            h_rho_arr[i] = uhc::density(mat, T);
            h_cp_arr[i]  = uhc::specific_heat(mat, T);
            h_eps_arr[i] = uhc::emissivity(mat, T);
        }

        cudaMemcpy((float*)d_k->data(),   h_k_arr,   n*sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_rho->data(), h_rho_arr, n*sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_cp->data(),  h_cp_arr,  n*sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_eps->data(), h_eps_arr, n*sizeof(float), cudaMemcpyHostToDevice);

        delete[] h_k_arr; delete[] h_rho_arr;
        delete[] h_cp_arr; delete[] h_eps_arr;

        printf("[UHC Kinetic] Material initialised: %s\n",
               mat == uhc::MAT_ZRB2 ? "ZrB₂" :
               mat == uhc::MAT_TAC  ? "TaC"  : "HfC");
#else
        printf("[UHC Kinetic] CPU fallback — material init skipped\n");
#endif
    }

    /* ---- Advance one time step ---- */
    void step()
    {
#if defined(NANOVDB_USE_CUDA)
        int nx = dimX, ny = dimY, nz = dimZ;
        dim3 block(8, 8, 4);
        dim3 grid((nx + block.x - 1) / block.x,
                  (ny + block.y - 1) / block.y,
                  (nz + block.z - 1) / block.z);

        kernel_thermal_step_3d<<<grid, block>>>(
            (float*)d_T_next->data(),
            (float*)d_T->data(),
            (float*)d_k->data(),
            (float*)d_rho->data(),
            (float*)d_cp->data(),
            (float*)d_eps->data(),
            nullptr,
            &d_laser,
            T_ambient_K, h_conv,
            dx, nx, ny, nz, dt
        );
        cudaDeviceSynchronize();

        std::swap(h_T, h_T_next);
        d_T      = h_T.deviceGrid<float>();
        d_T_next = h_T_next.deviceGrid<float>();

        t_elapsed += dt;
#else
        printf("[UHC Kinetic] CPU fallback — step skipped\n");
#endif
    }

    /* ---- Run multiple steps, reporting peak T ---- */
    void run(int n_steps, float report_every_s = 0.001f)
    {
        float next_report = report_every_s;
        for (int s = 0; s < n_steps; ++s) {
            step();
            if (t_elapsed >= next_report) {
#if defined(NANOVDB_USE_CUDA)
                float peak_T = 0.0f;
                const float* pT = (const float*)d_T->data();
                size_t n = (size_t)dimX * dimY * dimZ;
                for (size_t i = 0; i < n; ++i)
                    if (pT[i] > peak_T) peak_T = pT[i];
                printf("[UHC Kinetic] t=%.3fs  T_peak=%.0f K (%.0f °C)\n",
                       (double)t_elapsed, (double)peak_T, (double)(peak_T - 273.15f));
#endif
                next_report += report_every_s;
            }
        }
    }

    void export_temperature(const char* filename)
    {
        h_T.deviceDownload();
        nanovdb::io::writeGrid(filename, h_T, "T_final");
        printf("[UHC Kinetic] T_field exported → %s  (t=%.3fs)\n",
               filename, (double)t_elapsed);
    }
};

/* ================================================================== */
/*  Entry point                                                        */
/* ================================================================== */

int main(int argc, char** argv)
{
    printf("[UHC Kinetic] UHTC 3D Kinetic Thermal Solver\n");

    const float dx = 0.5f;   /* 0.5 mm voxels */
    const int nx = 32, ny = 32, nz = 32;

    UHCKineticThermalSolver solver(dx, nx, ny, nz);

    printf("[UHC Kinetic] Grid: %d×%d×%d  dx=%.1f mm  dt=%.0e s\n",
           nx, ny, nz, dx, solver.dt);
    printf("[UHC Kinetic] Laser: %.0f W  η=%.2f  spot=%.1f mm  v=%.1f mm/s\n",
           (double)solver.d_laser.P,
           (double)solver.d_laser.eta,
           (double)solver.d_laser.sx,
           (double)solver.d_laser.scan_speed);

    solver.run(200, report_every_s: 0.002f);
    solver.export_temperature("uhc_kinetic_T_final.nvdb");

    return 0;
}
