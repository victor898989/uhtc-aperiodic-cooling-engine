// SPDX-License-Identifier: Apache-2.0
//
// uhc_rocket_structure_api.cu
//
// C API implementation for UHTC rocket / robust-structure voxel engine.
// ========================================================================

#include "uhc_rocket_structure.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>

#if defined(NANOVDB_USE_CUDA)
#include <nanovdb/io/IO.h>
#include <nanovdb/cuda/DeviceBuffer.h>
#include <nanovdb/tools/CreatePrimitives.h>

#include <openvdb/openvdb.h>
#include <openvdb/tools/MeshToVolume.h>
#include <openvdb/tools/VolumeToMesh.h>
#include <openvdb/tools/LevelSetRebuild.h>

using BufferT = nanovdb::cuda::DeviceBuffer;
#else
using BufferT = nanovdb::HostBuffer;
#endif

using namespace nanovdb;

// =====================================================================
// Minimal JSON parser for RocketConfig (no external deps)
// =====================================================================

static const char* jsonSkipWs(const char* p)
{
    while (*p && isspace((unsigned char)*p)) ++p;
    return p;
}

static const char* jsonMatch(const char* p, const char* key)
{
    p = jsonSkipWs(p);
    while (*key && *p && *key == *p) { ++key; ++p; }
    return (*key == '\0') ? p : nullptr;
}

static const char* jsonReadFloat(const char* p, float* out)
{
    p = jsonSkipWs(p);
    if (!p || *p != ':') return nullptr;
    ++p;
    p = jsonSkipWs(p);
    char* end = nullptr;
    *out = strtof(p, &end);
    return end;
}

static const char* jsonReadInt(const char* p, int* out)
{
    p = jsonSkipWs(p);
    if (!p || *p != ':') return nullptr;
    ++p;
    p = jsonSkipWs(p);
    char* end = nullptr;
    *out = (int)strtol(p, &end, 10);
    return end;
}

static int parseRocketConfig(const char* json, RocketConfig* cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->enable_lattice = 1;

    const char* p = json;

    if ((p = jsonReadFloat(p, &cfg->chamber_length_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->chamber_radius_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->nose_length_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->nose_radius_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->wall_thickness_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->lattice_freq_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->lattice_wall_thickness)) == nullptr) return -1;
    if ((p = jsonReadInt(p, &cfg->enable_lattice)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->voxel_size_mm)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->T_ambient_K)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->convection_coeff)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->dt)) == nullptr) return -1;
    if ((p = jsonReadFloat(p, &cfg->Q_combustion_W_mm3)) == nullptr) return -1;

    return 0;
}

// =====================================================================
// Opaque solver handle
// =====================================================================

struct RocketSolverHandle {
    RocketConfig cfg;
#if defined(NANOVDB_USE_CUDA)
    nanovdb::GridHandle<BufferT> h_T;
    nanovdb::GridHandle<BufferT> h_T_next;
    nanovdb::GridHandle<BufferT> h_k;
    nanovdb::GridHandle<BufferT> h_rho;
    nanovdb::GridHandle<BufferT> h_cp;
    nanovdb::GridHandle<BufferT> h_eps;

    nanovdb::Grid<nanovdb::FloatTree>* d_T      = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_T_next = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_k      = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_rho    = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_cp     = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_eps    = nullptr;
#endif
    int dimX, dimY, dimZ;
    float t_elapsed;
};

// =====================================================================
// C API
// =====================================================================

int loadRocketConfig(const char* json_path, RocketConfig* out_cfg)
{
    if (!json_path || !out_cfg) return -1;

    FILE* f = fopen(json_path, "rb");
    if (!f) {
        fprintf(stderr, "[Rocket] Cannot open config: %s\n", json_path);
        return -1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);

    char* buf = (char*)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return -1; }
    fread(buf, 1, (size_t)sz, f);
    buf[sz] = '\0';
    fclose(f);

    int rc = parseRocketConfig(buf, out_cfg);
    free(buf);

    if (rc != 0) {
        fprintf(stderr, "[Rocket] Failed to parse config\n");
        return -1;
    }

    printf("[Rocket] Config loaded: L=%.1f mm R=%.1f mm dx=%.3f mm lattice=%s\n",
           (double)out_cfg->chamber_length_mm,
           (double)out_cfg->chamber_radius_mm,
           (double)out_cfg->voxel_size_mm,
           out_cfg->enable_lattice ? "ON" : "OFF");

    return 0;
}

void* rocket_solver_create(const RocketConfig* cfg)
{
    if (!cfg) return nullptr;

    auto* h = (RocketSolverHandle*)calloc(1, sizeof(RocketSolverHandle));
    if (!h) return nullptr;

    memcpy(&h->cfg, cfg, sizeof(RocketConfig));
    h->t_elapsed = 0.0f;

#if defined(NANOVDB_USE_CUDA)
    /* Placeholder: allocate simple levelset sphere for demo */
    try {
        h->h_T      = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                         15.0f, nanovdb::Vec3d(0,0,10), cfg->voxel_size_mm, 3, nanovdb::Vec3d(0), "T_rocket");
        h->h_T_next = nanovdb::tools::createLevelSetSphere<float, BufferT>(
                         15.0f, nanovdb::Vec3d(0,0,10), cfg->voxel_size_mm, 3, nanovdb::Vec3d(0), "T_next");

        h->h_T.deviceUpload();
        h->h_T_next.deviceUpload();

        h->d_T      = h->h_T.deviceGrid<float>();
        h->d_T_next = h->h_T_next.deviceGrid<float>();

        h->dimX = 32; h->dimY = 32; h->dimZ = 32;
    } catch (const std::exception& e) {
        fprintf(stderr, "[Rocket] Grid creation failed: %s\n", e.what());
        free(h);
        return nullptr;
    }
#else
    h->dimX = 32; h->dimY = 32; h->dimZ = 32;
#endif

    printf("[Rocket] Solver created: %dx%dx%d\n", h->dimX, h->dimY, h->dimZ);
    return h;
}

void rocket_solver_step(void* handle)
{
    if (!handle) return;
    auto* h = (RocketSolverHandle*)handle;
#if defined(NANOVDB_USE_CUDA)
    if (!h->d_T || !h->d_T_next) return;

    int nx = h->dimX, ny = h->dimY, nz = h->dimZ;
    dim3 block(8, 8, 4);
    dim3 grid((nx + block.x - 1) / block.x,
              (ny + block.y - 1) / block.y,
              (nz + block.z - 1) / block.z);

    kernel_rocket_thermal_step<<<grid, block>>>(
        (float*)h->d_T_next->data(),
        (float*)h->d_T->data(),
        (float*)h->d_k->data(),
        (float*)h->d_rho->data(),
        (float*)h->d_cp->data(),
        (float*)h->d_eps->data(),
        (float*)h->d_tort->data(),
        (float*)h->d_thk->data(),
        nullptr,
        h->cfg.T_ambient_K,
        h->cfg.convection_coeff,
        h->cfg.voxel_size_mm,
        nx, ny, nz,
        h->cfg.dt,
        h->cfg.Q_combustion_W_mm3
    );
    cudaDeviceSynchronize();

    std::swap(h->h_T, h->h_T_next);
    h->d_T      = h->h_T.deviceGrid<float>();
    h->d_T_next = h->h_T_next.deviceGrid<float>();
    h->t_elapsed += h->cfg.dt;
#endif
}

void rocket_solver_run(void* handle, int n_steps, float report_interval_s)
{
    if (!handle) return;
    auto* h = (RocketSolverHandle*)handle;

    float next_report = report_interval_s;
    for (int s = 0; s < n_steps; ++s) {
        rocket_solver_step(handle);
        if (h->t_elapsed >= next_report) {
#if defined(NANOVDB_USE_CUDA)
            float peak_T = 0.0f;
            const float* pT = (const float*)h->d_T->data();
            size_t n = (size_t)h->dimX * h->dimY * h->dimZ;
            for (size_t i = 0; i < n; ++i)
                if (pT[i] > peak_T) peak_T = pT[i];
            printf("[Rocket] t=%.3fs  T_peak=%.0f K (%.0f °C)\n",
                   (double)h->t_elapsed, (double)peak_T,
                   (double)(peak_T - 273.15f));
#endif
            next_report += report_interval_s;
        }
    }
}

void rocket_solver_export_temperature(void* handle, const char* filename)
{
    if (!handle || !filename) return;
    auto* h = (RocketSolverHandle*)handle;
#if defined(NANOVDB_USE_CUDA)
    h->h_T.deviceDownload();
    nanovdb::io::writeGrid(filename, h->h_T, "T_rocket");
    printf("[Rocket] Exported: %s\n", filename);
#endif
}

void rocket_solver_destroy(void* handle)
{
    if (!handle) return;
    free(handle);
    printf("[Rocket] Solver destroyed\n");
}
