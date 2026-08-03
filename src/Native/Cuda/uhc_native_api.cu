// SPDX-License-Identifier: Apache-2.0
//
// uhc_native_api.cu
//
// C-linkage wrappers that expose the UHTC CUDA kernels as a shared library.
// This file is compiled into libuhtc_native_accel.so and linked by C# DllImport.

#include "uhc_native_api.h"
#include "uhc_material_properties.h"
#include "uhc_thermal_solver.h"
#include "uhc_deposition.h"
#include "uhc_oxygen_barrier.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

/* ================================================================== */
/*  Simple handle store (single-threaded demo; thread-safe impl uses  */
/*  a lock-free slot allocator in production)                         */
/* ================================================================== */

#define MAX_HANDLES 64

static void* g_handles[MAX_HANDLES];
static int   g_handle_count = 0;

static int alloc_handle(void* ptr)
{
    for (int i = 0; i < MAX_HANDLES; ++i) {
        if (g_handles[i] == nullptr) {
            g_handles[i] = ptr;
            return i;
        }
    }
    return -1;
}

static void free_handle(int idx)
{
    if (idx >= 0 && idx < MAX_HANDLES) g_handles[idx] = nullptr;
}

/* ================================================================== */
/*  Material property queries (pure CPU — no CUDA context needed)      */
/* ================================================================== */

extern "C" {

float uhc_mat_thermal_conductivity(int material_id, float T_K)
{
    return uhc::thermal_conductivity((uhc::MaterialID)material_id, T_K);
}

float uhc_mat_specific_heat(int material_id, float T_K)
{
    return uhc::specific_heat((uhc::MaterialID)material_id, T_K);
}

float uhc_mat_density(int material_id, float T_K)
{
    return uhc::density((uhc::MaterialID)material_id, T_K);
}

float uhc_mat_emissivity(int material_id, float T_K)
{
    return uhc::emissivity((uhc::MaterialID)material_id, T_K);
}

float uhc_mat_radiative_flux(int material_id, float T_K, float T_ambient_K)
{
    return uhc::radiative_heat_flux((uhc::MaterialID)material_id, T_K, T_ambient_K);
}

float uhc_mat_oxygen_barrier(float t_wall_mm, float tortuosity, float t_layer_s)
{
    return uhc::oxygen_barrier(t_wall_mm, tortuosity, t_layer_s);
}

/* ================================================================== */
/*  Thermal solver API                                                 */
/* ================================================================== */

UhcThermalSolverHandle uhc_thermal_create(float voxel_size_mm)
{
    auto* solver = new UHCThermalSolver(voxel_size_mm);
    int handle = alloc_handle(solver);
    if (handle < 0) { delete solver; return nullptr; }
    return (UhcThermalSolverHandle)(intptr_t)handle;
}

void uhc_thermal_destroy(UhcThermalSolverHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    delete (UHCThermalSolver*)g_handles[idx];
    free_handle(idx);
}

int uhc_thermal_set_laser(UhcThermalSolverHandle h, const float* src)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* s = (UHCThermalSolver*)g_handles[idx];
    LaserSourceNative ls;
    memcpy(&ls, src, sizeof(ls));
    s->d_laser.px = ls.Px; s->d_laser.py = ls.Py; s->d_laser.pz = ls.Pz;
    s->d_laser.P  = ls.Power; s->d_laser.eta = ls.Eta;
    s->d_laser.sx = ls.Sx; s->d_laser.sy = ls.Sy; s->d_laser.sz = ls.Sz;
    s->d_laser.scan_speed = ls.ScanSpeed;
    return 0;
}

int uhc_thermal_set_chamber(UhcThermalSolverHandle h, const float* src)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* s = (UHCThermalSolver*)g_handles[idx];
    ChamberParams cp;
    memcpy(&cp, src, sizeof(cp));
    s->d_chamber.T_substrate  = cp.TSubstrateK;
    s->d_chamber.T_ambient    = cp.TAmbientK;
    s->d_chamber.h_conv       = cp.HConv;
    s->d_chamber.layer_time_s = cp.LayerTimeS;
    s->d_chamber.dt_fixed     = cp.DtFixed;
    return 0;
}

int uhc_thermal_initialise_material(UhcThermalSolverHandle h, int material_id)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->initialise_material_zrb2(); /* extend with switch on material_id */
    return 0;
}

int uhc_thermal_step(UhcThermalSolverHandle h, int n_steps)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->step(n_steps);
    return 0;
}

int uhc_thermal_read_temperature(UhcThermalSolverHandle h, float* buffer, int n)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* s = (UHCThermalSolver*)g_handles[idx];
#if defined(NANOVDB_USE_CUDA)
    s->h_T.deviceDownload();
#endif
    /* Simplified: copy first n floats from the NanoVDB grid data pointer */
    const float* data = (const float*)s->h_T.data();
    memcpy(buffer, data, n * sizeof(float));
    return 0;
}

int uhc_thermal_export_nvdb(UhcThermalSolverHandle h, const char* filename)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->export_temperature(filename);
    return 0;
}

/* ================================================================== */
/*  Deposition manager API                                             */
/* ================================================================== */

UhcDepositHandle uhc_deposit_create(float voxel_size_mm)
{
    auto* mgr = new UHCDepositionManager(voxel_size_mm);
    int handle = alloc_handle(mgr);
    if (handle < 0) { delete mgr; return nullptr; }
    return (UhcDepositHandle)(intptr_t)handle;
}

void uhc_deposit_destroy(UhcDepositHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    delete (UHCDepositionManager*)g_handles[idx];
    free_handle(idx);
}

int uhc_deposit_layer(UhcDepositHandle h,
                      const float* path_xy,
                      const float* path_power,
                      int n_segments,
                      float z_layer_mm,
                      int   material_id,
                      float porosity)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* mgr = (UHCDepositionManager*)g_handles[idx];

#if defined(NANOVDB_USE_CUDA)
    float2* d_path; float* d_power;
    cudaMalloc(&d_path,  n_segments * sizeof(float2));
    cudaMalloc(&d_power, n_segments * sizeof(float));
    cudaMemcpy(d_path,  path_xy,   n_segments*sizeof(float2), cudaMemcpyHostToDevice);
    cudaMemcpy(d_power, path_power,n_segments*sizeof(float),  cudaMemcpyHostToDevice);

    mgr->deposit_layer(d_path, d_power, n_segments, z_layer_mm,
                       (uhc::MaterialID)material_id, porosity);

    cudaFree(d_path);
    cudaFree(d_power);
#else
    mgr->deposit_layer(nullptr, nullptr, 0, z_layer_mm,
                       (uhc::MaterialID)material_id, porosity);
#endif
    return 0;
}

int uhc_deposit_get_layer_record(UhcDepositHandle h, int layer_index, float* record)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* mgr = (UHCDepositionManager*)g_handles[idx];
    if (layer_index < 0 || layer_index >= mgr->n_layers) return -1;

    auto& rec = mgr->layer_records[layer_index];
    record[0] = (float)rec.layer_id;
    record[1] = rec.z_top_mm;
    record[2] = rec.melt_volume_mm3;
    record[3] = rec.avg_density;
    record[4] = rec.peak_T_K;
    record[5] = (float)rec.n_breach;
    record[6] = rec.laser_power_W;
    record[7] = rec.scan_time_s;
    return 0;
}

int uhc_deposit_export_report(UhcDepositHandle h, const char* filename)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* mgr = (UHCDepositionManager*)g_handles[idx];
    mgr->export_layer_report(filename);
    return 0;
}

/* ================================================================== */
/*  Oxygen-barrier evaluator API                                       */
/* ================================================================== */

UhcO2BarrierHandle uhc_o2barrier_create(float t_critical_mm, float t_layer_s,
                                         float T_process_K, float P_chamber_atm)
{
    auto* bar = new UHCOxygenBarrier(t_critical_mm, t_layer_s, T_process_K, P_chamber_atm);
    int handle = alloc_handle(bar);
    if (handle < 0) { delete bar; return nullptr; }
    return (UhcO2BarrierHandle)(intptr_t)handle;
}

void uhc_o2barrier_destroy(UhcO2BarrierHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    delete (UHCOxygenBarrier*)g_handles[idx];
    free_handle(idx);
}

int uhc_o2barrier_evaluate(UhcO2BarrierHandle h,
                            const float* sdf,
                            const float* grad_mag,
                            const float* void_fraction,
                            float* t_pen,
                            float* barrier_flag,
                            float* tortuosity_out,
                            int n_columns)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* bar = (UHCOxygenBarrier*)g_handles[idx];

#if defined(NANOVDB_USE_CUDA)
    bar->evaluate(n_columns);
    bar->export_results("uhc_o2_barrier_temp.csv");
#else
    (void)sdf; (void)grad_mag; (void)void_fraction;
    printf("[UHC API] O2 barrier evaluate: CPU fallback, %d columns\n", n_columns);
#endif
    return 0;
}

int uhc_o2barrier_export_csv(UhcO2BarrierHandle h, const char* filename)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
    auto* bar = (UHCOxygenBarrier*)g_handles[idx];
    bar->export_results(filename);
    return 0;
}

} /* extern "C" */
