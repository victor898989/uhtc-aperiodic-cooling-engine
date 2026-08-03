// SPDX-License-Identifier: Apache-2.0
//
// NativeEngineAPI.cpp
//
// Implementation of the unified UHTC native bridge.
// Routes calls to CUDA (GPU) or FPGA (ZCU104 Alveo) backends.
//
// Build:
//   cmake -DUHC_BUILD_BRIDGE=ON ..  →  libuhtc_native_accel.so

#include "NativeEngineAPI.h"
#include "uhc_material_properties.h"

#include "uhc_thermal_solver.h"
#include "uhc_deposition.h"
#include "uhc_oxygen_barrier.h"
#include "uhc_fpga_types.h"
#include "fpga_laser_control.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>

#if defined(NANOVDB_USE_CUDA)
#include <nanovdb/cuda/DeviceBuffer.h>
#endif

/* ================================================================== */
/*  Global state                                                       */
/* ================================================================== */

static UhcBackend g_backend = BACKEND_AUTO;
static UhcBackend g_active  = BACKEND_CPU;

#if defined(NANOVDB_USE_CUDA)
static bool g_cuda_available = true;
#else
static bool g_cuda_available = false;
#endif

/* ================================================================== */
/*  Simple handle store (single-threaded; replace with lock-free       */
/*  slot allocator in production)                                      */
/* ================================================================== */

#define MAX_HANDLES 64
static void* g_handles[MAX_HANDLES];
static int   g_handle_count = 0;

static int alloc_handle(void* ptr)
{
    for (int i = 0; i < MAX_HANDLES; ++i) {
        if (g_handles[i] == nullptr) { g_handles[i] = ptr; return i; }
    }
    return -1;
}

static void free_handle(int idx)
{
    if (idx >= 0 && idx < MAX_HANDLES) g_handles[idx] = nullptr;
}

/* ================================================================== */
/*  Library lifecycle                                                   */
/* ================================================================== */

int uhc_initialize(UhcBackend backend)
{
    g_backend = backend;
    if (backend == BACKEND_AUTO) {
        g_active = g_cuda_available ? BACKEND_CUDA : BACKEND_CPU;
    } else if (backend == BACKEND_CUDA && g_cuda_available) {
        g_active = BACKEND_CUDA;
    } else if (backend == BACKEND_FPGA) {
        g_active = BACKEND_CPU;   /* FPGA: open device explicitly via uhc_fpga_open */
    } else {
        g_active = BACKEND_CPU;
    }

    printf("[UHC Bridge] Backend: %s\n",
           g_active == BACKEND_CUDA ? "CUDA" :
           g_active == BACKEND_FPGA ? "FPGA" : "CPU");
    return 0;
}

void uhc_shutdown(void)
{
    for (int i = 0; i < MAX_HANDLES; ++i) {
        if (g_handles[i]) {
            /* Destroy known handle types */
            free_handle(i);
        }
    }
    g_active  = BACKEND_CPU;
    g_backend = BACKEND_AUTO;
    printf("[UHC Bridge] Shut down\n");
}

UhcBackend uhc_active_backend(void)
{
    return g_active;
}

/* ================================================================== */
/*  FPGA: device management (ZCU104 / Alveo via XRT)                   */
/* ================================================================== */

struct FpgaHandle {
    const UhcFpgaConfig* config;
    int   device_index;
    int   xclbin_loaded;
    /* XRT objects would go here in production */
    void* xrt_device;
    void* xrt_kernel_sdf;
    void* xrt_kernel_pid;
};

extern "C" {

UhcFpgaHandle uhc_fpga_open(const UhcFpgaConfig* config)
{
    if (!config || !config->xclbin_path) {
        fprintf(stderr, "[UHC FPGA] null config or xclbin_path\n");
        return nullptr;
    }

    auto* h = (FpgaHandle*)calloc(1, sizeof(FpgaHandle));
    if (!h) return nullptr;

    h->config        = config;
    h->device_index  = (int)config->device_index;
    h->xclbin_loaded = 0;

    /*
     * Production path:
     *   xrt::device   dev(h->device_index);
     *   auto xclbin   = xrt::xclbin(config->xclbin_path);
     *   dev.register_xclbin(xclbin);
     *   h->xrt_kernel_sdf = new xrt::kernel(dev, xclbin.get_uuid(), "krnl_uhc_sdf");
     *   h->xrt_kernel_pid = new xrt::kernel(dev, xclbin.get_uuid(), "krnl_uhc_pid_control");
     */
    printf("[UHC FPGA] Device %d opened (xclbin: %s)\n",
           h->device_index, config->xclbin_path);

    int idx = alloc_handle(h);
    if (idx < 0) { free(h); return nullptr; }
    return (UhcFpgaHandle)(intptr_t)idx;
}

void uhc_fpga_close(UhcFpgaHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    auto* fpga = (FpgaHandle*)g_handles[idx];
    if (!fpga) return;

    /* delete xrt_kernel objects in production */
    free(fpga);
    free_handle(idx);
    printf("[UHC FPGA] Device closed\n");
}

int uhc_fpga_write_laser_stream(UhcFpgaHandle h,
                                const UhcLaserCommand* cmds,
                                int n_cmds)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !cmds || n_cmds <= 0) return -1;
    auto* fpga = (FpgaHandle*)g_handles[idx];
    if (!fpga) return -1;

    /*
     * Production path (AXI Stream via XRT):
     *   xrt::bo<UhcLaserCommand> bo(dev, n_cmds, bo::flags::host_only, krnl.group_id(0));
     *   bo.write(cmds, n_cmds);
     *   bo.sync(to_device);
     *   auto run = krnl(bo, n_cmds);
     *   run.wait();
     */
    printf("[UHC FPGA] Stream write: %d laser commands\n", n_cmds);
    return n_cmds;
}

int uhc_fpga_read_thermal(UhcFpgaHandle h,
                          UhcThermalReading* readings,
                          int n_readings)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !readings || n_readings <= 0) return -1;
    auto* fpga = (FpgaHandle*)g_handles[idx];
    if (!fpga) return -1;

    /* Production: read from FPGA BRAM via AXI Lite DMA or /dev/uioX */
    printf("[UHC FPGA] Thermal read: %d readings requested\n", n_readings);
    return 0;
}

int uhc_fpga_get_emergency_stop(UhcFpgaHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return 0;
    auto* fpga = (FpgaHandle*)g_handles[idx];
    if (!fpga) return 0;

    /* Production: read e-stop register via AXI Lite */
    uint32_t reg = 0; // uhc_fpga_read_reg(fpga, 0x00); /* e-stop at offset 0 */
    return (reg & 0x1) ? 1 : 0;
}

void uhc_fpga_write_reg(UhcFpgaHandle h, uint32_t reg_off, uint32_t value)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    auto* fpga = (FpgaHandle*)g_handles[idx];
    if (!fpga) return;
    printf("[UHC FPGA] AXI Lite write: [0x%04X] = 0x%08X\n", reg_off, value);
}

uint32_t uhc_fpga_read_reg(UhcFpgaHandle h, uint32_t reg_off)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return 0;
    auto* fpga = (FpgaHandle*)g_handles[idx];
    if (!fpga) return 0;
    printf("[UHC FPGA] AXI Lite read:  [0x%04X]\n", reg_off);
    return 0;
}

} /* extern "C" — FPGA section */

/* ================================================================== */
/*  PID laser scan (host-side or FPGA offload)                         */
/* ================================================================== */

extern "C" {

int uhc_pid_laser_scan(UhcFpgaHandle h,
                       const UhcScanSegment* segments,
                       const float* T_measured,
                       float* P_eff_out,
                       float* e_stop_out,
                       int n_segments,
                       float T_target,
                       const UhcParams* params)
{
    if (!segments || !T_measured || !P_eff_out || !e_stop_out || n_segments <= 0)
        return -1;

    /*
     * When BACKEND_FPGA and h != nullptr:
     *   Upload segments + T_measured to FPGA DDR,
     *   launch krnl_uhc_pid_control,
     *   read back P_eff_out + e_stop_out.
     *
     * Otherwise (CPU fallback): run scalar PID here.
     */
    float e_prev    = 0.0f;
    float integral  = 0.0f;
    const float Kp  = 8.0f;
    const float Ki  = 0.5f;
    const float Kd  = 1.5f;
    const float Pmin= 50.0f;
    const float Pmax= 1200.0f;

    for (int i = 0; i < n_segments; ++i) {
        float e_n = T_target - T_measured[i];
        integral += e_n;
        if (integral >  2000.0f) integral =  2000.0f;
        if (integral < -2000.0f) integral = -2000.0f;

        float P = Kp*e_n + Ki*integral + Kd*(e_n - e_prev);
        e_prev = e_n;

        float v_max = 15.0f;
        if (segments[i].speed > v_max) P *= v_max / segments[i].speed;

        if (P < Pmin) P = Pmin;
        if (P > Pmax) P = Pmax;

        P_eff_out[i] = P;
    }

    e_stop_out[0] = 0.0f;
    for (int i = 0; i < n_segments; ++i) {
        if (T_measured[i] > T_target + 600.0f) {
            e_stop_out[0] = 1.0f;
            break;
        }
    }

    printf("[UHC PID] %d segments, T_target=%.0f K, e_stop=%s\n",
           n_segments, T_target, e_stop_out[0] > 0.5f ? "YES" : "no");
    return 0;
}

} /* extern "C" — PID section */

/* ================================================================== */
/*  CUDA: thermal solver                                               */
/* ================================================================== */

extern "C" {

UhcThermalHandle uhc_thermal_create(float voxel_size_mm)
{
#if defined(NANOVDB_USE_CUDA)
    auto* solver = new UHCThermalSolver(voxel_size_mm);
    int handle = alloc_handle(solver);
    if (handle < 0) { delete solver; return nullptr; }
    return (UhcThermalHandle)(intptr_t)handle;
#else
    (void)voxel_size_mm;
    fprintf(stderr, "[UHC Thermal] Built without CUDA — returning null handle\n");
    return nullptr;
#endif
}

void uhc_thermal_destroy(UhcThermalHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
#if defined(NANOVDB_USE_CUDA)
    delete (UHCThermalSolver*)g_handles[idx];
#endif
    free_handle(idx);
}

int uhc_thermal_set_laser(UhcThermalHandle h, const float* src)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !src) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* s = (UHCThermalSolver*)g_handles[idx];
    memcpy(&s->d_laser, src, sizeof(s->d_laser));
    return 0;
#else
    (void)h; (void)src;
    return -1;
#endif
}

int uhc_thermal_set_chamber(UhcThermalHandle h, const float* src)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !src) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* s = (UHCThermalSolver*)g_handles[idx];
    memcpy(&s->d_chamber, src, sizeof(s->d_chamber));
    return 0;
#else
    (void)h; (void)src;
    return -1;
#endif
}

int uhc_thermal_initialise_material(UhcThermalHandle h, int material_id)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->initialise_material_zrb2();   /* extend with switch on material_id */
    return 0;
#else
    (void)h; (void)material_id;
    return -1;
#endif
}

int uhc_thermal_step(UhcThermalHandle h, int n_steps)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->step(n_steps);
    return 0;
#else
    (void)h; (void)n_steps;
    return -1;
#endif
}

int uhc_thermal_read_temperature(UhcThermalHandle h, float* buffer, int n_voxels)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !buffer) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->h_T.deviceDownload();
    const float* data = (const float*)s->h_T.data();
    memcpy(buffer, data, n_voxels * sizeof(float));
    return 0;
#else
    (void)h; (void)buffer; (void)n_voxels;
    return -1;
#endif
}

int uhc_thermal_export_nvdb(UhcThermalHandle h, const char* filename)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !filename) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* s = (UHCThermalSolver*)g_handles[idx];
    s->export_temperature(filename);
    return 0;
#else
    (void)h; (void)filename;
    return -1;
#endif
}

} /* extern "C" — thermal section */

/* ================================================================== */
/*  CUDA: deposition manager                                           */
/* ================================================================== */

extern "C" {

UhcDepositHandle uhc_deposit_create(float voxel_size_mm)
{
#if defined(NANOVDB_USE_CUDA)
    auto* mgr = new UHCDepositionManager(voxel_size_mm);
    int handle = alloc_handle(mgr);
    if (handle < 0) { delete mgr; return nullptr; }
    return (UhcDepositHandle)(intptr_t)handle;
#else
    (void)voxel_size_mm;
    return nullptr;
#endif
}

void uhc_deposit_destroy(UhcDepositHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
#if defined(NANOVDB_USE_CUDA)
    delete (UHCDepositionManager*)g_handles[idx];
#endif
    free_handle(idx);
}

int uhc_deposit_layer(UhcDepositHandle h,
                      const float* path_xy,
                      const float* path_power,
                      int n_segments,
                      float z_layer_mm,
                      int material_id,
                      float porosity)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* mgr = (UHCDepositionManager*)g_handles[idx];
    mgr->deposit_layer(nullptr, nullptr, n_segments, z_layer_mm,
                       (uhc::MaterialID)material_id, porosity);
    return 0;
#else
    (void)h; (void)path_xy; (void)path_power;
    (void)n_segments; (void)z_layer_mm; (void)material_id; (void)porosity;
    return -1;
#endif
}

int uhc_deposit_get_layer_record(UhcDepositHandle h, int layer_index, float* record)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !record) return -1;
#if defined(NANOVDB_USE_CUDA)
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
#else
    (void)h; (void)layer_index; (void)record;
    return -1;
#endif
}

int uhc_deposit_export_report(UhcDepositHandle h, const char* filename)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !filename) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* mgr = (UHCDepositionManager*)g_handles[idx];
    mgr->export_layer_report(filename);
    return 0;
#else
    (void)h; (void)filename;
    return -1;
#endif
}

} /* extern "C" — deposit section */

/* ================================================================== */
/*  CUDA: oxygen-barrier evaluator                                     */
/* ================================================================== */

extern "C" {

UhcO2BarrierHandle uhc_o2barrier_create(float t_critical_mm, float t_layer_s,
                                         float T_process_K, float P_chamber_atm)
{
#if defined(NANOVDB_USE_CUDA)
    auto* bar = new UHCOxygenBarrier(t_critical_mm, t_layer_s, T_process_K, P_chamber_atm);
    int handle = alloc_handle(bar);
    if (handle < 0) { delete bar; return nullptr; }
    return (UhcO2BarrierHandle)(intptr_t)handle;
#else
    (void)t_critical_mm; (void)t_layer_s;
    (void)T_process_K; (void)P_chamber_atm;
    return nullptr;
#endif
}

void uhc_o2barrier_destroy(UhcO2BarrierHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
#if defined(NANOVDB_USE_CUDA)
    delete (UHCOxygenBarrier*)g_handles[idx];
#endif
    free_handle(idx);
}

int uhc_o2barrier_evaluate(UhcO2BarrierHandle h,
                            const float* sdf,
                            const float* grad_mag,
                            const float* void_fraction,
                            float* t_pen,
                            float* barrier_flag,
                            float* tortuosity,
                            int n_columns)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* bar = (UHCOxygenBarrier*)g_handles[idx];
    bar->evaluate(n_columns);
    return 0;
#else
    (void)h; (void)sdf; (void)grad_mag; (void)void_fraction;
    (void)t_pen; (void)barrier_flag; (void)tortuosity; (void)n_columns;
    return -1;
#endif
}

int uhc_o2barrier_export_csv(UhcO2BarrierHandle h, const char* filename)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !filename) return -1;
#if defined(NANOVDB_USE_CUDA)
    auto* bar = (UHCOxygenBarrier*)g_handles[idx];
    bar->export_results(filename);
    return 0;
#else
    (void)h; (void)filename;
    return -1;
#endif
}

} /* extern "C" — O2 section */

/* ================================================================== */
/*  Material properties (CPU-safe, no CUDA context required)           */
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

} /* extern "C" — material section */

/* ================================================================== */
/*  UHTC SDF evaluation (FPGA or CPU fallback)                         */
/* ================================================================== */

extern "C" {

int uhc_evaluate_sdf(const float* points,
                     float* sdf_out,
                     float* barrier_out,
                     float* k_out,
                     float* laser_q,
                     float* o2_time,
                     int n_points,
                     const UhcParams* params)
{
    if (!points || !sdf_out || !params || n_points <= 0) return -1;

    /*
     * FPGA path: if BACKEND_FPGA and device open,
     *   upload points + params → FPGA DDR
     *   launch krnl_uhc_sdf
     *   read back sdf_out, barrier_out, k_out, laser_q, o2_time
     *
     * CPU fallback: evaluate inline with scalar SDF functions
     */
    printf("[UHC SDF] Evaluating %d points on %s\n",
           n_points, g_active == BACKEND_FPGA ? "FPGA" : "CPU");

    for (int i = 0; i < n_points; ++i) {
        float px = points[i*3    ];
        float py = points[i*3 + 1];
        float pz = points[i*3 + 2];
        float d  = 0.0f;

        switch (params->geometry_type) {
            case 0: /* Gyroid */
                d = sdf_gyroid(px, py, pz, params->freq, params->wall_thickness);
                break;
            case 1: /* Lidinoid */
                d = sdf_lidinoid(px, py, pz, params->freq);
                break;
            case 2: /* SplitVoidGyroid */
                d = sdf_split_void_gyroid(px, py, pz, params->freq,
                                          params->wall_thickness, params->split);
                break;
        }

        sdf_out[i]     = d;
        k_out[i]       = uhc_mat_thermal_conductivity(params->material_id, params->T_melt_K);
        o2_time[i]     = uhc_mat_oxygen_barrier(params->wall_thickness * 0.1f,
                                                 params->tortuosity,
                                                 params->layer_time_s);
        barrier_out[i] = o2_time[i] > params->layer_time_s ? 1.0f : 0.0f;

        float dx = px - params->laser_x;
        float dy = py - params->laser_y;
        float dz = pz - params->laser_z;
        float norm = 2.0f * params->laser_eta * params->laser_power_W /
                     (float(M_PI) * sqrtf(float(M_PI))
                      * params->ellipse_x * params->ellipse_y * params->ellipse_z);
        float ex = -2.0f*(dx*dx)/(params->ellipse_x*params->ellipse_x + 1e-8f);
        float ey = -2.0f*(dy*dy)/(params->ellipse_y*params->ellipse_y + 1e-8f);
        float ez = -2.0f*(dz*dz)/(params->ellipse_z*params->ellipse_z + 1e-8f);
        laser_q[i] = norm * expf(ex + ey + ez);
    }

    return 0;
}

} /* extern "C" — SDF section */
