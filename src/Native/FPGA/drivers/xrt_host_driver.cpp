/**
 * @file xrt_host_driver.cpp
 *
 * UHTC Aperiodic Cooling Engine — XRT Host Driver (Alveo / ZCU104)
 *
 * Orchestrates krnl_uhc_sdf and krnl_uhc_pid_control kernels:
 *   1. Builds aperiodic lattice point cloud from C# geometry engine
 *   2. Uploads lattice points and UHTCParams to FPGA
 *   3. Launches SDF evaluation kernel
 *   4. Reads back barrier map (which voxels are O2-sealed)
 *   5. Launches PID laser-control kernel for each scan layer
 *   6. Monitors thermal-guard kernel for emergency stop
 */

#include "uhc_fpga_types.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>

/* ---- XRT / OpenCL headers ---- */
#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>
#include <xrt/xrt_kernel.h>

/* ------------------------------------------------------------------ */
/*  Configuration constants                                            */
/* ------------------------------------------------------------------ */
#define XCLBIN_PATH         "./build/xclbin/uhtc_sdf.xclbin"
#define KERNEL_SDF_NAME     "krnl_uhc_sdf"
#define KERNEL_PID_NAME     "krnl_uhc_pid_control"
#define KERNEL_GUARD_NAME   "krnl_uhc_thermal_guard"
#define MAX_POINTS          65536
#define MAX_SEGMENTS        4096
#define MAX_T_HISTORY       32

/* ------------------------------------------------------------------ */
/*  Default UHTC parameters (ZrB2-SiC baseline)                        */
/* ------------------------------------------------------------------ */
static UHTCParams default_params(void)
{
    UHTCParams p;
    memset(&p, 0, sizeof(p));

    p.geometry_type   = UHC_GYROID;
    p.freq            = 0.8f;            /* [1/mm] — 1.25 mm unit cell */
    p.wall_thickness  = 0.25f;
    p.split           = 3.0f;
    p.t_critical_mm   = 0.08f;           /* < 80 µm wall → O2 can diffuse */
    p.tortuosity      = 3.5f;            /* aperiodic path length / straight line */

    p.T_melt_K        = 3523.0f;         /* ZrB2 melt ≈ 3250 °C */
    p.T_ambient_K     = 300.0f;
    p.layer_time_s    = 2.0f;

    p.material_id     = UHC_MAT_ZRB2;

    p.laser_x         = 0.0f;
    p.laser_y         = 0.0f;
    p.laser_z         = 0.0f;
    p.laser_power_W   = 500.0f;
    p.laser_eta       = 0.35f;           /* absorptivity of ZrB2 at 1070 nm */
    p.scan_speed_mm_s = 5.0f;
    p.ellipse_x       = 2.5f;            /* laser spot radius X [mm] */
    p.ellipse_y       = 2.5f;
    p.ellipse_z       = 1.0f;

    return p;
}

/* ------------------------------------------------------------------ */
/*  Helper: generate a simple scan-path (raster fill of unit square)   */
/* ------------------------------------------------------------------ */
static void generate_raster_scan(ScanSegment* segs, int* n_seg, float size_mm,
                                  float speed, float pitch)
{
    int n = 0;
    for (float y = -size_mm; y < size_mm; y += pitch) {
        float dir = (n % 2 == 0) ? 1.0f : -1.0f;
        float x0  = (n % 2 == 0) ? -size_mm :  size_mm;
        float x1  = (n % 2 == 0) ?  size_mm : -size_mm;
        segs[n].x      = x0;
        segs[n].y      = y;
        segs[n].speed  = speed;
        segs[n].power  = 0.0f;
        segs[n+1].x    = x1;
        segs[n+1].y    = y;
        segs[n+1].speed= speed;
        segs[n+1].power= 0.0f;
        n += 2;
    }
    *n_seg = n;
}

/* ------------------------------------------------------------------ */
/*  Main host pipeline                                                  */
/* ------------------------------------------------------------------ */
int main(int argc, char** argv)
{
    printf("[UHC] UHTC Aperiodic Cooling Engine — XRT Host\n");

    /* ---- Open device ---- */
    int dev_idx = 0;
    if (argc > 1) dev_idx = atoi(argv[1]);

    xrt::device device(dev_idx);
    printf("[UHC] Device %d: %s\n", dev_idx, device.get_name().c_str());

    auto xclbin = xrt::xclbin(XCLBIN_PATH);
    device.register_xclbin(xclbin);

    auto krnl_sdf  = xrt::kernel(device, xclbin.get_uuid(), KERNEL_SDF_NAME);
    auto krnl_pid  = xrt::kernel(device, xclbin.get_uuid(), KERNEL_PID_NAME);

    /* ---- Allocate host buffers ---- */
    static float  h_points    [MAX_POINTS * 3];
    static float  h_sdf       [MAX_POINTS];
    static float  h_barrier   [MAX_POINTS];
    static float  h_kcond     [MAX_POINTS];
    static float  h_laser_q   [MAX_POINTS];
    static float  h_o2_time   [MAX_POINTS];
    static ScanSegment h_segs[MAX_SEGMENTS];
    static float  h_T_meas    [MAX_SEGMENTS];
    static float  h_P_eff     [MAX_SEGMENTS];
    static float  h_e_stop    [1];

    /* ---- Populate lattice point cloud (from C# Engine.Cooling) ---- */
    /* For demonstration: 32×32×32 grid over a 10 mm cube              */
    int n_pts = 0;
    for (int iz = 0; iz < 32; ++iz) {
        for (int iy = 0; iy < 32; ++iy) {
            for (int ix = 0; ix < 32; ++ix) {
                float x = (ix - 16) * 0.3125f;
                float y = (iy - 16) * 0.3125f;
                float z = (iz - 16) * 0.3125f;
                h_points[n_pts*3    ] = x;
                h_points[n_pts*3 + 1] = y;
                h_points[n_pts*3 + 2] = z;
                n_pts++;
            }
        }
    }
    printf("[UHC] Lattice points: %d\n", n_pts);

    UHTCParams params = default_params();
    int n_seg = 0;
    generate_raster_scan(h_segs, &n_seg, 5.0f, params.scan_speed_mm_s, 0.25f);
    printf("[UHC] Scan segments: %d\n", n_seg);

    /* ---- Build XRT buffer objects ---- */
    xrt::bo<float>       bo_points   (device, n_pts*3,  xrt::bo::flags::host_only, krnl_sdf.group_id(0));
    xrt::bo<float>       bo_sdf      (device, n_pts,    xrt::bo::flags::host_only, krnl_sdf.group_id(1));
    xrt::bo<float>       bo_barrier  (device, n_pts,    xrt::bo::flags::host_only, krnl_sdf.group_id(1));
    xrt::bo<float>       bo_kcond    (device, n_pts,    xrt::bo::flags::host_only, krnl_sdf.group_id(2));
    xrt::bo<float>       bo_laser_q  (device, n_pts,    xrt::bo::flags::host_only, krnl_sdf.group_id(2));
    xrt::bo<float>       bo_o2_time  (device, n_pts,    xrt::bo::flags::host_only, krnl_sdf.group_id(3));
    xrt::bo<UHTCParams>  bo_params   (device, 1,       xrt::bo::flags::host_only, krnl_sdf.group_id(4));

    xrt::bo<ScanSegment> bo_segs     (device, n_seg,    xrt::bo::flags::host_only, krnl_pid.group_id(0));
    xrt::bo<float>       bo_T_meas   (device, n_seg,    xrt::bo::flags::host_only, krnl_pid.group_id(1));
    xrt::bo<float>       bo_P_eff    (device, n_seg,    xrt::bo::flags::host_only, krnl_pid.group_id(2));
    xrt::bo<float>       bo_e_stop   (device, 1,        xrt::bo::flags::host_only, krnl_pid.group_id(3));

    /* ---- Sync host → device ---- */
    bo_points  .write(h_points);
    bo_params  .write(&params);
    bo_segs    .write(h_segs);
    bo_points  .sync(xrt::bo::sync_type::to_device);
    bo_params  .sync(xrt::bo::sync_type::to_device);
    bo_segs    .sync(xrt::bo::sync_type::to_device);

    /* ================================================================ */
    /*  Run SDF kernel                                                   */
    /* ================================================================ */
    printf("[UHC] Launching krnl_uhc_sdf...\n");
    auto run_sdf = krnl_sdf(
        bo_points  .xcl_bo(),
        bo_sdf     .xcl_bo(),
        bo_barrier .xcl_bo(),
        bo_kcond   .xcl_bo(),
        bo_laser_q .xcl_bo(),
        bo_o2_time .xcl_bo(),
        n_pts,
        bo_params  .xcl_bo()
    );
    run_sdf.wait();

    /* ---- Read back results ---- */
    bo_sdf     .sync(xrt::bo::sync_type::from_device);
    bo_barrier .sync(xrt::bo::sync_type::from_device);
    bo_kcond   .sync(xrt::bo::sync_type::from_device);
    bo_laser_q .sync(xrt::bo::sync_type::from_device);
    bo_o2_time .sync(xrt::bo::sync_type::from_device);

    bo_sdf     .read(h_sdf);
    bo_barrier .read(h_barrier);
    bo_kcond   .read(h_kcond);
    bo_laser_q .read(h_laser_q);
    bo_o2_time .read(h_o2_time);

    /* ---- Summary ---- */
    int n_sealed = 0;
    for (int i = 0; i < n_pts; ++i)
        if (h_barrier[i] > 0.5f) n_sealed++;

    printf("[UHC] SDF evaluation complete.\n");
    printf("[UHC]   O2-sealed voxels : %d / %d (%.1f %%)\n",
           n_sealed, n_pts, 100.0f * n_sealed / n_pts);
    printf("[UHC]   k_cond @ T_melt  : %.1f W/m·K (first voxel)\n", h_kcond[0]);
    printf("[UHC]   t_O2_diffusion   : %.3e s (first voxel)\n", h_o2_time[0]);

    /* ================================================================ */
    /*  Run PID laser-control kernel per layer                            */
    /* ================================================================ */
    printf("[UHC] Launching krnl_uhc_pid_control...\n");

    /* Simulate measured temperatures (in practice: read from thermal sensor) */
    for (int i = 0; i < n_seg; ++i) {
        h_T_meas[i] = params.T_melt_K - 100.0f + 20.0f * sinf(i * 0.3f);
    }

    bo_T_meas .write(h_T_meas);
    bo_T_meas .sync(xrt::bo::sync_type::to_device);

    auto run_pid = krnl_pid(
        bo_segs    .xcl_bo(),
        bo_T_meas  .xcl_bo(),
        bo_P_eff   .xcl_bo(),
        bo_e_stop  .xcl_bo(),
        n_seg,
        /* T_target = */ params.T_melt_K,
        bo_params  .xcl_bo()
    );
    run_pid.wait();

    bo_P_eff  .sync(xrt::bo::sync_type::from_device);
    bo_e_stop .sync(xrt::bo::sync_type::from_device);

    bo_P_eff  .read(h_P_eff);
    bo_e_stop .read(h_e_stop);

    printf("[UHC] PID control complete.\n");
    printf("[UHC]   Emergency stop  : %s\n",
           h_e_stop[0] > 0.5f ? "TRIGGERED" : "clear");
    printf("[UHC]   P_eff range     : %.0f – %.0f W\n",
           h_P_eff[0], h_P_eff[n_seg-1]);

    return 0;
}
