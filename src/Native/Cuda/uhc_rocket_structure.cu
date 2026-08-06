// SPDX-License-Identifier: Apache-2.0
//
// uhc_rocket_structure.cu
//
// NanoVDB/OpenVDB-based voxel engine for large robust UHTC structures
// such as rocket motor chambers, heat exchangers, and re-entry heat shields
// operating above 3000 K.
//
// Architecture:
//   1. SDF-based geometry construction (nose cone, combustion chamber,
//      cooling channels, lattice insulation) on host with OpenVDB/NanoVDB
//   2. Material field assignment per voxel (ZrB2, TaC, HfC, Woven II, modified
//      boron silicate) with temperature-dependent properties
//   3. Device upload to NanoVDB GridHandle<CudaDeviceBuffer>
//   4. CUDA thermal diffusion kernel for T > 3000 K
//   5. Oxygen barrier evaluation per voxel (tortuosity + wall thickness)
//   6. Mesh export via OpenVDB VolumeToMesh for slicer integration
//
// References:
//   - UHTC.material: T_melt ZrB2=3519 K, TaC=4215 K, HfC=4231 K
//   - UG1267 ZCU104 for PL/PS data movement
//   - nanovdb::tools::createLevelSetSphere / meshToLevelSet
//   - PicoGK Voxels API (BoolAdd, RenderLattice, RenderImplicit)
//
// Build:
//   nvcc -std=c++17 -DNANOVDB_USE_CUDA -I./src/Native/Cuda \
//        -I./third_party/nanovdb/include \
//        uhc_rocket_structure.cu -o uhc_rocket_structure
//
// Run:
//   ./uhc_rocket_structure --config configs/rocket_structure_config.json
// ========================================================================

#include "uhc_material_properties.h"
#include "uhc_rocket_structure.h"

#include <nanovdb/io/IO.h>
#include <nanovdb/cuda/DeviceBuffer.h>
#include <nanovdb/tools/CreatePrimitives.h>

#include <openvdb/openvdb.h>
#include <openvdb/tools/MeshToVolume.h>
#include <openvdb/tools/VolumeToMesh.h>
#include <openvdb/tools/LevelSetRebuild.h>
#include <openvdb/tools/LevelSetMeasure.h>
#include <openvdb/tools/Composite.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <string>

#if defined(NANOVDB_USE_CUDA)
using BufferT = nanovdb::cuda::DeviceBuffer;
#else
using BufferT = nanovdb::HostBuffer;
#endif

using namespace nanovdb;

// =====================================================================
// Helpers
// =====================================================================

static std::vector<float> allocateHostField(int n)
{
    return std::vector<float>(static_cast<size_t>(n), 0.0f);
}

// =====================================================================
// Rocket geometry primitives (host-side OpenVDB)
// =====================================================================

struct RocketGeometry
{
    openvdb::FloatGrid::Ptr sdf;       /* combined signed distance [mm] */
    openvdb::FloatGrid::Ptr material;   /* material ID field */
    openvdb::FloatGrid::Ptr tortuosity; /* oxygen barrier tortuosity */
    openvdb::FloatGrid::Ptr thickness;  /* local wall thickness [mm] */
    openvdb::Vec3I            dims;      /* voxel grid dimensions */
    float                     voxelSize; /* [mm] */
    float                     time;      /* elapsed simulation time [s] */
};

static float sdCone(float x, float y, float z,
                    float h, float r_bot, float r_top)
{
    float t = z / fmaxf(h, 1e-6f);
    float r = r_bot + t * (r_top - r_bot);
    float d_horz = sqrtf(x * x + y * y) - r;
    float d_vert = fabsf(z - 0.5f * h) - 0.5f * h;
    return fmaxf(d_horz, d_vert);
}

static float sdCylinder(float x, float y, float z,
                        float r, float h)
{
    float d_horz = sqrtf(x * x + y * y) - r;
    float d_vert = fabsf(z - 0.5f * h) - 0.5f * h;
    return fmaxf(d_horz, d_vert);
}

static float sdTorus(float x, float y, float z,
                     float R, float r)
{
    float q = sqrtf(x * x + y * y) - R;
    return sqrtf(q * q + z * z) - r;
}

static float sdGyroid(float x, float y, float z, float freq, float thickness)
{
    float v = sinf(freq * x) * cosf(freq * y) +
              sinf(freq * y) * cosf(freq * z) +
              sinf(freq * z) * cosf(freq * x);
    return fabsf(v) - thickness;
}

// =====================================================================
// Build rocket SDF
// =====================================================================

static RocketGeometry buildRocketGeometry(const RocketConfig& cfg)
{
    RocketGeometry geo;
    geo.voxelSize = cfg.voxel_size_mm;
    geo.time      = 0.0f;

    const float L = cfg.chamber_length_mm;
    const float R = cfg.chamber_radius_mm;
    const float L_nose = cfg.nose_length_mm;
    const float R_nose = cfg.nose_radius_mm;
    const float R_outer = R + cfg.wall_thickness_mm;
    const float freq = cfg.lattice_freq_mm > 0.0f ? 1.0f / cfg.lattice_freq_mm : 0.0f;
    const float wall = cfg.lattice_wall_thickness;

    /* grid dimensions */
    const int nx = static_cast<int>(ceilf(2.0f * R_outer / geo.voxelSize)) + 1;
    const int ny = static_cast<int>(ceilf(2.0f * R_outer / geo.voxelSize)) + 1;
    const int nz = static_cast<int>(ceilf((L + L_nose) / geo.voxelSize)) + 1;
    geo.dims = openvdb::Vec3I(nx, ny, nz);

    openvdb::math::Transform::Ptr xform =
        openvdb::math::Transform::createLinearTransform(geo.voxelSize);

    geo.sdf       = openvdb::FloatGrid::create(geo.voxelSize * 4.0f);
    geo.material  = openvdb::FloatGrid::create(0.0f);
    geo.tortuosity= openvdb::FloatGrid::create(1.0f);
    geo.thickness = openvdb::FloatGrid::create(0.0f);

    geo.sdf->setTransform(xform);
    geo.material->setTransform(xform);
    geo.tortuosity->setTransform(xform);
    geo.thickness->setTransform(xform);

    geo.sdf->setGridClass(openvdb::GRID_LEVEL_SET);

    auto accSDF  = geo.sdf->getAccessor();
    auto accMat  = geo.material->getAccessor();
    auto accTort = geo.tortuosity->getAccessor();
    auto accThk  = geo.thickness->getAccessor();

    const float cx = 0.5f * (nx - 1) * geo.voxelSize;
    const float cy = 0.5f * (ny - 1) * geo.voxelSize;
    const float cz_nose = 0.0f;

    printf("[Rocket] Grid: %d x %d x %d  voxel=%.3f mm\n",
           nx, ny, nz, (double)geo.voxelSize);

    /* -----------------------------------------------------------------
       Voxelize SDF + assign material + barrier properties
       ----------------------------------------------------------------- */
    for (int iz = 0; iz < nz; ++iz) {
        for (int iy = 0; iy < ny; ++iy) {
            for (int ix = 0; ix < nx; ++ix) {
                const float x = ix * geo.voxelSize - cx;
                const float y = iy * geo.voxelSize - cy;
                const float z = iz * geo.voxelSize + cz_nose;

                openvdb::Coord xyz(ix, iy, iz);

                /* ---- Nose cone ---- */
                float d_nose = sdCone(x, y, z - L_nose * 0.5f,
                                      L_nose, R_nose, 0.0f);

                /* ---- Combustion chamber ---- */
                float d_chamber = sdCylinder(x, y, z - L_nose,
                                             R_outer, L);

                /* ---- Lattice insulation (gyroid) ---- */
                float d_lattice = 1e6f;
                if (freq > 0.0f) {
                    d_lattice = sdGyroid(x, y, z, freq, wall);
                }

                /* ---- Composite SDF ---- */
                float d = fminf(d_nose, d_chamber);
                if (cfg.enable_lattice) {
                    d = fmaxf(d, -d_lattice);  /* subtract lattice from solid */
                }

                /* ---- Material ID ---- */
                float matId = 0.0f; /* ZrB2 */
                if (z < L_nose && d < 0.0f) {
                    matId = 1.0f; /* TaC nose cap */
                } else if (d < 0.0f) {
                    matId = 0.0f; /* ZrB2 chamber */
                }

                /* ---- Tortuosity / barrier ---- */
                float tort = 1.0f;
                float thk  = 0.0f;
                if (d < 0.0f && cfg.enable_lattice) {
                    tort = 3.5f;   /* aperiodic gyroid tortuosity */
                    thk  = cfg.lattice_wall_thickness;
                }

                accSDF.setValue(xyz, d);
                accMat.setValue(xyz, matId);
                accTort.setValue(xyz, tort);
                accThk.setValue(xyz, thk);
            }
        }
    }

    printf("[Rocket] Geometry built: nose=%.1f mm, chamber=%.1f mm, lattice=%s\n",
           (double)L_nose, (double)L, cfg.enable_lattice ? "ON" : "OFF");

    return geo;
}

// =====================================================================
// Material initialisation on device
// =====================================================================

static void initialiseRocketMaterials(RocketGeometry& geo,
                                      float T_ambient_K)
{
#if defined(NANOVDB_USE_CUDA)
    const size_t n = (size_t)geo.dims.x() * geo.dims.y() * geo.dims.z();
    std::vector<float> h_matId(n);
    std::vector<float> h_k(n), h_rho(n), h_cp(n), h_eps(n);

    auto accMat  = geo.material->getConstAccessor();
    auto accTort = geo.tortuosity->getAccessor();
    auto accThk  = geo.thickness->getAccessor();

    for (int iz = 0; iz < geo.dims.z(); ++iz)
    for (int iy = 0; iy < geo.dims.y(); ++iy)
    for (int ix = 0; ix < geo.dims.x(); ++ix) {
        size_t idx = (size_t)iz * geo.dims.x() * geo.dims.y()
                   + (size_t)iy * geo.dims.x()
                   + (size_t)ix;

        float matId = accMat.getValue(openvdb::Coord(ix, iy, iz));
        uhc::MaterialID m = uhc::MAT_ZRB2;
        if (matId >= 1.5f)      m = uhc::MAT_TAC;
        else if (matId >= 0.5f) m = uhc::MAT_ZRB2;
        else                     m = uhc::MAT_POWDER_ZRB2;

        float T = T_ambient_K;
        h_matId[idx] = static_cast<float>(m);
        h_k[idx]     = uhc::thermal_conductivity(m, T);
        h_rho[idx]   = uhc::density(m, T);
        h_cp[idx]    = uhc::specific_heat(m, T);
        h_eps[idx]   = uhc::emissivity(m, T);
    }

    /* TODO: upload to device NanoVDB grids in production build */
    printf("[Rocket] Material field initialised: %zu voxels, T_amb=%.0f K\n",
           (unsigned long long)n, (double)T_ambient_K);
#else
    printf("[Rocket] CPU fallback — material init skipped\n");
#endif
}

// =====================================================================
// CUDA thermal step for rocket chamber (>3000 K capable)
// =====================================================================

__global__ void kernel_rocket_thermal_step(
    float* __restrict__       d_T_new,
    const float* __restrict__ d_T_old,
    const float* __restrict__ d_matId,
    const float* __restrict__ d_tort,
    const float* __restrict__ d_thk,
    const int*   __restrict__ d_active,
    float T_ambient_K,
    float h_conv,
    float dx,
    int   dimX, int dimY, int dimZ,
    float dt,
    float Q_combustion_W_mm3)
{
    int ix = blockIdx.x * blockDim.x + threadIdx.x;
    int iy = blockIdx.y * blockDim.y + threadIdx.y;
    int iz = blockIdx.z * blockDim.z + threadIdx.z;

    if (ix >= dimX || iy >= dimY || iz >= dimZ) return;

    int idx = ix + dimX * (iy + dimY * iz);

    if (d_active && d_active[idx] == 0) {
        d_T_new[idx] = d_T_old[idx];
        return;
    }

    float T = d_T_old[idx];
    float matId = d_matId ? d_matId[idx] : 0.0f;
    uhc::MaterialID m = uhc::MAT_ZRB2;
    if      (matId >= 2.5f) m = uhc::MAT_HFC;
    else if (matId >= 1.5f) m = uhc::MAT_TAC;
    else if (matId >= 0.5f) m = uhc::MAT_ZRB2;
    else                    m = uhc::MAT_POWDER_ZRB2;

    float k    = uhc::thermal_conductivity(m, T);
    float rho  = uhc::density(m, T);
    float cp   = uhc::specific_heat(m, T);
    float eps  = uhc::emissivity(m, T);
    float tort = d_tort ? d_tort[idx] : 1.0f;
    float thk  = d_thk  ? d_thk[idx]  : 0.0f;

    /* 7-point Laplacian */
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

    /* thermal diffusivity [mm²/s] */
    float alpha = uhc::thermal_diffusivity(m, T);

    /* combustion heat source (constant volumetric for demo) */
    float Q_comb = Q_combustion_W_mm3;

    /* top surface: radiation + convection using per-voxel material */
    float Q_conv = 0.0f, Q_rad = 0.0f;
    if (iz == dimZ - 1) {
        Q_conv = h_conv * (T - T_ambient_K);
        Q_rad  = uhc::radiative_heat_flux(m, T, T_ambient_K);
    }

    /* oxygen barrier modulation:
       if lattice wall too thin, increase local heat loss (ablative guard) */
    float barrier_factor = 1.0f;
    if (thk > 0.0f && tort > 1.0f) {
        float safe = uhc::oxygen_barrier(thk, tort, 2.0f);
        barrier_factor = safe ? 1.0f : 1.15f; /* 15% penalty if barrier fails */
    }

    float dT_dt = alpha * 1e-6f * lap
                + barrier_factor * (Q_conv + Q_rad) * 1e-6f / (rho * 1000.0f * cp * 1000.0f)
                + Q_comb / (rho * 1000.0f * cp * 1000.0f);

    float T_new = T + dt * dT_dt;
    T_new = fmaxf(T_new, T_ambient_K);
    T_new = fminf(T_new, 5000.0f);

    d_T_new[idx] = T_new;
}

// =====================================================================
// Rocket thermal solver manager
// =====================================================================

class UHCRocketThermalSolver
{
public:
    RocketGeometry      geometry;
    nanovdb::GridHandle<BufferT> h_T;
    nanovdb::GridHandle<BufferT> h_T_next;
    nanovdb::GridHandle<BufferT> h_mat;
    nanovdb::GridHandle<BufferT> h_tort_grid;
    nanovdb::GridHandle<BufferT> h_thk_grid;

    Grid<FloatTree>* d_T      = nullptr;
    Grid<FloatTree>* d_T_next = nullptr;
    Grid<FloatTree>* d_matId  = nullptr;
    Grid<FloatTree>* d_tort   = nullptr;
    Grid<FloatTree>* d_thk    = nullptr;

    float T_ambient_K;
    float h_conv;
    float dt;
    float dx;
    int   dimX, dimY, dimZ;
    float t_elapsed;
    float Q_combustion;

    UHCRocketThermalSolver(const RocketConfig& cfg)
        : T_ambient_K(cfg.T_ambient_K)
        , h_conv(cfg.convection_coeff)
        , dt(cfg.dt)
        , dx(cfg.voxel_size_mm)
        , Q_combustion(cfg.Q_combustion_W_mm3)
    {
        geometry = buildRocketGeometry(cfg);
        dimX = geometry.dims.x();
        dimY = geometry.dims.y();
        dimZ = geometry.dims.z();

        initialiseRocketMaterials(geometry, T_ambient_K);

#if defined(NANOVDB_USE_CUDA)
        size_t n = (size_t)dimX * dimY * dimZ;
        std::vector<float> h_T_arr(n, T_ambient_K);
        std::vector<float> h_matId(n);
        std::vector<float> h_tort(n, 1.0f);
        std::vector<float> h_thk(n, 0.0f);

        auto accMat  = geometry.material->getConstAccessor();
        auto accTort = geometry.tortuosity->getConstAccessor();
        auto accThk  = geometry.thickness->getConstAccessor();

        for (int iz = 0; iz < dimZ; ++iz)
        for (int iy = 0; iy < dimY; ++iy)
        for (int ix = 0; ix < dimX; ++ix) {
            size_t idx = (size_t)iz * dimX * dimY + (size_t)iy * dimX + (size_t)ix;
            float matId = accMat.getValue(openvdb::Coord(ix, iy, iz));
            h_matId[idx] = matId;
            h_tort[idx]  = accTort.getValue(openvdb::Coord(ix, iy, iz));
            h_thk[idx]   = accThk.getValue(openvdb::Coord(ix, iy, iz));
        }

        h_T      = nanovdb::tools::createNanoGrid(*geometry.sdf);
        h_T_next = nanovdb::tools::createNanoGrid(*geometry.sdf);
        h_mat      = nanovdb::tools::createNanoGrid(*geometry.material);
        h_tort_grid= nanovdb::tools::createNanoGrid(*geometry.tortuosity);
        h_thk_grid = nanovdb::tools::createNanoGrid(*geometry.thickness);

        h_T.deviceUpload(); h_T_next.deviceUpload();
        h_mat.deviceUpload(); h_tort_grid.deviceUpload(); h_thk_grid.deviceUpload();

        d_T      = h_T.deviceGrid<float>();
        d_T_next = h_T_next.deviceGrid<float>();
        d_matId  = h_mat.deviceGrid<float>();
        d_tort   = h_tort_grid.deviceGrid<float>();
        d_thk    = h_thk_grid.deviceGrid<float>();

        cudaMemcpy((float*)d_T->data(), h_T_arr.data(), n * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_T_next->data(), h_T_arr.data(), n * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_matId->data(), h_matId.data(), n * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_tort->data(), h_tort.data(), n * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy((float*)d_thk->data(), h_thk.data(), n * sizeof(float), cudaMemcpyHostToDevice);

        printf("[Rocket] Device upload: %zu voxels, 5 grids (T, T_next, matId, tort, thk)\n",
               (unsigned long long)n);
#else
        printf("[Rocket] CPU fallback — step will be skipped\n");
#endif
    }

    void step()
    {
#if defined(NANOVDB_USE_CUDA)
        dim3 block(8, 8, 4);
        dim3 grid((dimX + block.x - 1) / block.x,
                  (dimY + block.y - 1) / block.y,
                  (dimZ + block.z - 1) / block.z);

        kernel_rocket_thermal_step<<<grid, block>>>(
            (float*)d_T_next->data(),
            (float*)d_T->data(),
            (float*)d_matId->data(),
            (float*)d_tort->data(),
            (float*)d_thk->data(),
            nullptr,
            T_ambient_K, h_conv,
            dx, dimX, dimY, dimZ, dt,
            Q_combustion
        );
        cudaDeviceSynchronize();

        std::swap(h_T, h_T_next);
        d_T      = h_T.deviceGrid<float>();
        d_T_next = h_T_next.deviceGrid<float>();
        t_elapsed += dt;
#else
        (void)dt;
#endif
    }

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
                printf("[Rocket] t=%.3fs  T_peak=%.0f K (%.0f °C)\n",
                       (double)t_elapsed, (double)peak_T,
                       (double)(peak_T - 273.15f));
#endif
                next_report += report_every_s;
            }
        }
    }

    void exportTemperature(const char* filename)
    {
#if defined(NANOVDB_USE_CUDA)
        h_T.deviceDownload();
        nanovdb::io::writeGrid(filename, h_T, "T_rocket");
        printf("[Rocket] T_field exported -> %s  (t=%.3fs)\n",
               filename, (double)t_elapsed);
#else
        (void)filename;
#endif
    }

    void exportMesh(const char* filename)
    {
        openvdb::tools::volumeToMesh(*geometry.sdf,
                                     std::vector<openvdb::Vec3s>(),
                                     std::vector<openvdb::Vec3I>(),
                                     std::vector<openvdb::Vec4I>(),
                                     0.0f, 0.0, false);
        /* OpenVDB mesh export via io::writeGrid */
        printf("[Rocket] Mesh export placeholder -> %s\n", filename);
    }
};

// =====================================================================
// CLI entry point
// =====================================================================

int main(int argc, char** argv)
{
    printf("[Rocket] UHTC Rocket Chamber Voxel Engine\n");
    printf("[Rocket] Target temperature: >3000 K\n");

    RocketConfig cfg = loadRocketConfig(
        argc > 1 ? argv[1] : "configs/rocket_structure_config.json");

    printf("[Rocket] Voxel=%.3f mm  Grid=%dx%dx%d  Combustion=%.1f W/mm³\n",
           (double)cfg.voxel_size_mm,
           (int)static_cast<int>(ceilf(2.0f * (cfg.chamber_radius_mm + cfg.wall_thickness_mm) / cfg.voxel_size_mm)) + 1,
           (int)static_cast<int>(ceilf(2.0f * (cfg.chamber_radius_mm + cfg.wall_thickness_mm) / cfg.voxel_size_mm)) + 1,
           (int)static_cast<int>(ceilf((cfg.chamber_length_mm + cfg.nose_length_mm) / cfg.voxel_size_mm)) + 1,
           (double)cfg.Q_combustion_W_mm3);

    UHCRocketThermalSolver solver(cfg);
    solver.run(500, 0.001f);
    solver.exportTemperature("rocket_T_final.nvdb");
    solver.exportMesh("rocket_surface.vdb");

    return 0;
}
