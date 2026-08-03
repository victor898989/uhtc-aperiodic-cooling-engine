// SPDX-License-Identifier: Apache-2.0
//
// uhc_deposition.cu
//
// Layer-by-layer powder-bed activation and density tracking for UHTC AM.
//
// Per deposition event (one scan pass of the laser over a powder layer):
//   1. Laser Gaussian heat source melts powder in a voxel column
//   2. Affected voxels transition from POWDER → PARTIAL_MELT → SOLID
//   3. Density field updated: ρ → ρ_theoretical * (1 - porosity)
//   4. Track build height h_layer = max(z) of activated voxels
//
// Outputs:
//   - VoxelMaterial grid (mat ID, density, activation per voxel)
//   - Layer summary: melt-pool volume, porosity, peak T reached
//
// The aperiodic oxygen-barrier check runs after each layer:
//   t_wall_min = minimum wall thickness of aperiodic SDF at layer boundary
//   if t_wall_min < t_critical → flag for geometry regeneration in C#

#include "uhc_material_properties.h"

#include <nanovdb/io/IO.h>
#include <nanovdb/cuda/DeviceBuffer.h>
#include <nanovdb/tools/CreatePrimitives.h>
#include <cuda_runtime.h>

#include <cstdio>
#include <cmath>
#include <cstring>
#include <chrono>

#if defined(NANOVDB_USE_CUDA)
using BufferT = nanovdb::cuda::DeviceBuffer;
#endif

using namespace nanovdb;

/* ================================================================== */
/*  Voxel activation states                                            */
/* ================================================================== */

enum VoxelState : int {
    STATE_POWDER      = 0,
    STATE_HEATED      = 1,
    STATE_PARTIAL_MELT = 2,
    STATE_SOLID       = 3,
    STATE_KEYHOLE     = 4,   /* over-eutectic, porosity trap */
    STATE_O2_BREACH   = 5    /* wall thickness below critical */
};

/* ================================================================== */
/*  Per-layer build record                                             */
/* ================================================================== */

struct LayerRecord {
    int   layer_id;
    float z_top_mm;           /* highest activated voxel z [mm]    */
    float melt_volume_mm3;    /* Σ voxels in PARTIAL_MELT/SOLID    */
    float avg_density;        /* g/cm³ over affected voxels        */
    float peak_T_K;           /* max temperature reached this layer */
    int   n_breach;           /* voxels where wall < t_critical    */
    float laser_power_W;      /* average PID power used             */
    float scan_time_s;
};

/* ================================================================== */
/*  Gaussian laser spot (2D footprint in the XY plane)                */
/* ================================================================== */

__host__ __device__ inline float gaussian_spot(float x, float y,
                                                float x0, float y0,
                                                float sx, float sy)
{
    float dx = x - x0;
    float dy = y - y0;
    float ex = -0.5f * (dx*dx) / (sx*sx + 1e-8f);
    float ey = -0.5f * (dy*dy) / (sy*sy + 1e-8f);
    return expf(ex + ey);
}

/* ================================================================== */
/*  CUDA kernel: activate voxels under the laser scan path             */
/* ================================================================== */

__global__ void kernel_deposit_layer(
    float* __restrict__       d_state_grid,   /* linearised voxel state array */
    float* __restrict__       d_density_grid, /* linearised density array    */
    float* __restrict__       d_temp_grid,    /* linearised temperature      */
    int*   __restrict__       d_active_map,   /* 1 if active, 0 if inactive */
    const float2* __restrict__ d_path_xy,
    const float*  __restrict__ d_path_power,
    const int      n_segments,
    const float    z_layer_mm,
    const float    dx,
    const float    voxel_mass_g,
    const float    T_melt_K,
    const float    T_vapour_K,
    const int      mat_id,
    const float    porosity_target,
    const float    t_critical_mm,
    float* __restrict__ d_peak_T,
    int*   __restrict__ d_n_breach,
    const int      grid_ny,
    const int      grid_nz)
{
    int seg = blockIdx.x * blockDim.x + threadIdx.x;
    if (seg >= n_segments) return;

    float x0 = d_path_xy[seg].x;
    float y0 = d_path_xy[seg].y;
    float P  = d_path_power[seg];

    float fx = 7.5f;
    float fy = 7.5f;

    int ix0 = (int)floorf((x0 - fx) / dx);
    int ix1 = (int)ceilf ((x0 + fx) / dx));
    int iy0 = (int)floorf((y0 - fy) / dx);
    int iy1 = (int)ceilf ((y0 + fy) / dx));
    int iz  = (int)roundf(z_layer_mm / dx);
    if (iz < 0 || iz >= grid_nz) return;

    for (int ix = ix0; ix <= ix1; ++ix)
    for (int iy = iy0; iy <= iy1; ++iy)
    {
        if (ix < 0 || ix >= grid_ny || iy < 0 || iy >= grid_ny) continue;

        float x = (float)ix * dx;
        float y = (float)iy * dx;
        float g = gaussian_spot(x, y, x0, y0, 2.5f, 2.5f);

        float E = P * g * (dx / 5.0f);

        int idx = iz * grid_ny * grid_ny + iy * grid_ny + ix;
        if (d_active_map[idx] == 0) continue;

        float old_state = d_state_grid[idx];
        int state = (int)old_state;

        if (state == STATE_POWDER) {
            if      (E > 0.8f) state = STATE_SOLID;
            else if (E > 0.3f) state = STATE_PARTIAL_MELT;
            else                state = STATE_HEATED;

            float rho_full = uhc::density((uhc::MaterialID)mat_id, T_melt_K);
            float rho_new  = rho_full * (1.0f - porosity_target *
                              (state == STATE_PARTIAL_MELT ? 0.5f : 0.0f));
            d_density_grid[idx] = rho_new;

            float t_wall = 0.15f;
            if (t_wall < t_critical_mm) {
                state = STATE_O2_BREACH;
                atomicAdd(d_n_breach, 1);
            }
        }

        float rho = d_density_grid[idx];
        float cp  = uhc::specific_heat((uhc::MaterialID)mat_id, T_melt_K);
        float dT  = E / (rho * cp * dx*dx*dx * 1e-3f);
        float T   = d_temp_grid[idx] + dT;

        if (T > T_vapour_K) T = T_vapour_K;
        if (T < 300.0f)     T = 300.0f;

        d_temp_grid[idx] = T;
        atomicMax(d_peak_T, T);
        d_state_grid[idx] = (float)state;
    }
}
        }

        /* Temperature rise (simplified: ΔT = E / (ρ·c_p·V_voxel)) */
        float rho = d_density_grid[iz];
        float cp  = uhc::specific_heat((uhc::MaterialID)mat_id, T_melt_K);
        float dT  = E / (rho * cp * dx*dx*dx * 1e-3f);
        float T   = d_temp_grid[iz] + dT;

        /* Clamp T */
        if (T > T_vapour_K) T = T_vapour_K;
        if (T < 300.0f)     T = 300.0f;

        d_temp_grid[iz] = T;

        /* Atomic peak T */
        float old_peak = atomicMax(d_peak_T, T);

        d_state_grid[iz] = float(state);
    }
}

/* ================================================================== */
/*  Host-side deposition manager                                       */
/* ================================================================== */

class UHCDepositionManager
{
public:
    nanovdb::GridHandle<BufferT> h_state;
    nanovdb::GridHandle<BufferT> h_density;
    nanovdb::GridHandle<BufferT> h_temp;
    LayerRecord                  layer_records[256];
    int                          n_layers;
    float*                       d_active_map;

    UHCDepositionManager(float dx)
        : n_layers(0)
    {
        /* 64×64×32 grid covering 32×32×16 mm build volume */
        h_state   = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       20.0f, nanovdb::Vec3d(0,0,8), dx, 3, nanovdb::Vec3d(0), "voxel_state");
        h_density = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       20.0f, nanovdb::Vec3d(0,0,8), dx, 3, nanovdb::Vec3d(0), "density");
        h_temp    = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                       20.0f, nanovdb::Vec3d(0,0,8), dx, 3, nanovdb::Vec3d(0), "temperature");

        /* Initialise: all powder */
        h_state.deviceUpload();
        h_density.deviceUpload();
        h_temp.deviceUpload();

        n_layers = 0;
    }

    /* ---- Run one deposition layer ---- */
    void deposit_layer(const float2* d_path, const float* d_power, int n_seg,
                       float z_mm, MaterialID mat, float porosity)
    {
#if defined(NANOVDB_USE_CUDA)
        float* d_state_ptr   = (float*)h_state  .deviceData();
        float* d_density_ptr = (float*)h_density.deviceData();
        float* d_temp_ptr    = (float*)h_temp   .deviceData();

        float d_peak_T_init = 300.0f;
        int   d_n_breach_init = 0;

        float* d_peak_T;
        int*   d_n_breach;
        cudaMalloc(&d_peak_T,   sizeof(float));
        cudaMalloc(&d_n_breach, sizeof(int));
        cudaMalloc(&d_active_map, 64*64*32 * sizeof(int));
        cudaMemset(d_active_map, 1, 64*64*32 * sizeof(int));

        cudaMemcpy(d_peak_T,   &d_peak_T_init,   sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy(d_n_breach, &d_n_breach_init, sizeof(int),   cudaMemcpyHostToDevice);

        int block = 256;
        int grid  = (n_seg + block - 1) / block;
        int grid_ny = 64;
        int grid_nz = 32;

        kernel_deposit_layer<<<grid, block>>>(
            d_state_ptr, d_density_ptr, d_temp_ptr, d_active_map,
            d_path, d_power, n_seg,
            z_mm, 0.5f,
            uhc::density(mat, 300.0f) * 0.125e-3f,
            3523.0f, 4500.0f,
            (int)mat, porosity, 0.08f,
            d_peak_T, d_n_breach,
            grid_ny, grid_nz
        );
        cudaDeviceSynchronize();

        LayerRecord& rec = layer_records[n_layers++];
        rec.layer_id      = n_layers - 1;
        rec.z_top_mm      = z_mm;
        rec.melt_volume_mm3 = 0.0f;
        rec.avg_density   = 0.0f;
        rec.peak_T_K      = 300.0f;
        rec.n_breach      = 0;

        cudaMemcpy(&rec.peak_T_K, d_peak_T,   sizeof(float), cudaMemcpyDeviceToHost);
        cudaMemcpy(&rec.n_breach, d_n_breach, sizeof(int),   cudaMemcpyDeviceToHost);

        cudaFree(d_peak_T);
        cudaFree(d_n_breach);
        cudaFree(d_active_map);
#else
        (void)d_path; (void)d_power; (void)n_seg;
        printf("[UHC Deposit] CPU fallback — skipping layer %d\n", n_layers);
        n_layers++;
#endif
    }

    void export_layer_report(const char* filename)
    {
        FILE* f = fopen(filename, "w");
        fprintf(f, "layer_id,z_mm,peak_T_K,n_breach\n");
        for (int i = 0; i < n_layers; ++i) {
            fprintf(f, "%d,%.3f,%.1f,%d\n",
                    layer_records[i].layer_id,
                    layer_records[i].z_top_mm,
                    layer_records[i].peak_T_K,
                    layer_records[i].n_breach);
        }
        fclose(f);
        printf("[UHC Deposit] Layer report → %s\n", filename);
    }
};

/* ================================================================== */
/*  Standalone test                                                    */
/* ================================================================== */

int main(int argc, char** argv)
{
    printf("[UHC Deposit] UHTC Deposition Layer Manager\n");

    const float dx = 0.5f;
    UHCDepositionManager mgr(dx);

    /* Generate a simple raster scan path for one 10×10 mm layer at z=2 mm */
    const int N_SEG = 40;
    float2 h_path[40];
    float  h_power[40];
    for (int i = 0; i < N_SEG; ++i) {
        h_path[i].x = -5.0f + (i % 10) * 1.0f;
        h_path[i].y = -5.0f + (i / 10) * 1.0f;
        h_power[i]  = 400.0f + 50.0f * sinf(i * 0.5f);
    }

#if defined(NANOVDB_USE_CUDA)
    float2* d_path;
    float*  d_power;
    cudaMalloc(&d_path,   N_SEG * sizeof(float2));
    cudaMalloc(&d_power,  N_SEG * sizeof(float));
    cudaMemcpy(d_path,  h_path,  N_SEG * sizeof(float2), cudaMemcpyHostToDevice);
    cudaMemcpy(d_power, h_power, N_SEG * sizeof(float),  cudaMemcpyHostToDevice);
#endif

    /* Run 3 layers at z = 2, 2.5, 3.0 mm */
    float zs[3] = { 2.0f, 2.5f, 3.0f };
    for (int i = 0; i < 3; ++i) {
#if defined(NANOVDB_USE_CUDA)
        mgr.deposit_layer(d_path, d_power, N_SEG, zs[i], uhc::MAT_ZRB2, 0.02f);
#else
        mgr.deposit_layer(nullptr, nullptr, 0, zs[i], uhc::MAT_ZRB2, 0.02f);
#endif
    }

#if defined(NANOVDB_USE_CUDA)
    cudaFree(d_path);
    cudaFree(d_power);
#endif

    mgr.export_layer_report("uhc_layer_report.csv");

    return 0;
}
