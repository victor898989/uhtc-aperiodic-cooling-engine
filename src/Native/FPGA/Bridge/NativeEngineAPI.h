// SPDX-License-Identifier: Apache-2.0
//
// NativeEngineAPI.h
//
// C-linkage bridge for UHTC Aperiodic Cooling Engine.
// This is the single contract imported by C# (UnsafeNativeMethods.cs)
// and implemented by both the CUDA backend and the FPGA HLS backend.
//
// Execution backends:
//   BACKEND_CUDA  — thermal diffusion, oxygen diffusion, deposition
//   BACKEND_FPGA  — ZCU104 real-time laser/galvo control via AXI DTPI/Stream
//   BACKEND_CPU   — scalar fallback
//
// Memory ownership:
//   All spans passed from C# are pinned by the marshaler.
//   The native side must NOT free them.
//   Opaque handles (UhcThermalHandle, etc.) are owned by the native side
//   and must be destroyed with the corresponding _destroy() call.

#ifndef NATIVE_ENGINE_API_H
#define NATIVE_ENGINE_API_H

#include <cstdint>
#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================== */
/*  Backend selector                                                   */
/* ================================================================== */

typedef enum {
    BACKEND_AUTO   = 0,
    BACKEND_CUDA   = 1,
    BACKEND_FPGA   = 2,
    BACKEND_CPU    = 3
} UhcBackend;

/* ================================================================== */
/*  Opaque handles                                                     */
/* ================================================================== */

typedef void* UhcThermalHandle;
typedef void* UhcDepositHandle;
typedef void* UhcO2BarrierHandle;
typedef void* UhcFpgaHandle;

/* ================================================================== */
/*  POD structs — must match C# UnsafeNativeMethods.cs exactly         */
/* ================================================================== */

/**
 * Laser command packet — matches ZCU104 AXI Stream layout.
 *
 * AXI Stream 32-bit word encoding:
 *   Word 0: [31:16] power_W (uint16, 0-2000 W)
 *            [15: 0] galvo_x  (uint16, DAC counts 0-65535)
 *   Word 1: [31:16] galvo_y  (uint16, DAC counts 0-65535)
 *            [15: 0] mod_freq (uint16, modulation frequency, 0-5000 Hz)
 *            [14: 0] mod_phase(uint16, phase offset)
 *   Word 2: [31: 0] reserved (future: polygon corners, jump speed)
 *
 * Total packet: 3 × 32-bit words = 12 bytes per laser sample.
 */
typedef struct {
    uint16_t power_W;      /* laser power [W]                           */
    uint16_t galvo_x;      /* galvo X DAC count (0-65535)               */
    uint16_t galvo_y;      /* galvo Y DAC count (0-65535)               */
    uint16_t mod_freq;     /* modulation frequency [Hz]                 */
    uint16_t mod_phase;    /* phase offset [0-65535 = 0-360°]           */
    uint16_t reserved0;
    uint32_t reserved1;
} UhcLaserCommand;

/**
 * Thermal feedback packet — matches ZCU104 AXI Lite register map.
 *
 * Read from FPGA at 1 kHz via AXI Lite (or DMA from BRAM).
 */
typedef struct {
    float    temperature_K;   /* voxel temperature [K]              */
    float    dT_dt;           /* temperature rise rate [K/s]        */
    uint32_t emergency_stop;  /* 1 = thermal runaway detected       */
    uint32_t timestamp_ms;    /* FPGA tick count [ms]               */
    uint32_t n_samples;       /* samples accumulated this frame     */
    uint32_t reserved0;
    float    reserved1;
} UhcThermalReading;

/**
 * Scan path segment — used by PID controller (FPGA or CUDA).
 */
typedef struct {
    float x;          /* segment start X [mm]  */
    float y;          /* segment start Y [mm]  */
    float speed;      /* scan speed [mm/s]     */
    float power;      /* target laser power [W]*/
} UhcScanSegment;

/**
 * Material + geometry parameters — shared across all backends.
 * Packed to 4-byte alignment for safe memcpy across DLL boundary.
 */
typedef struct {
    int   geometry_type;     /* 0=Gyroid, 1=Lidinoid, 2=SplitVoidGyroid */
    float freq;              /* spatial frequency [1/mm]                  */
    float wall_thickness;    /* SDF wall offset [unitless]                */
    float split;             /* SplitVoidGyroid plane [mm]                */
    float t_critical_mm;     /* O2 barrier min wall [mm]                  */
    float tortuosity;        /* geometric tortuosity factor               */
    float T_melt_K;          /* melt pool target [K]                      */
    float T_ambient_K;       /* build chamber [K]                         */
    float layer_time_s;      /* seconds per layer                         */
    int   material_id;       /* 0=ZrB2, 1=TaC, 2=HfC                     */
    float laser_x;           /* laser focus X [mm]                        */
    float laser_y;           /* laser focus Y [mm]                        */
    float laser_z;           /* laser focus Z [mm]                        */
    float laser_power_W;     /* nominal laser power [W]                   */
    float laser_eta;         /* absorptivity [0-1]                        */
    float scan_speed_mm_s;   /* scan speed [mm/s]                         */
    float ellipse_x;         /* Gaussian σx [mm]                          */
    float ellipse_y;         /* Gaussian σy [mm]                          */
    float ellipse_z;         /* Gaussian σz [mm]                          */
} UhcParams;

/**
 * Chamber boundary conditions.
 */
typedef struct {
    float T_substrate_K;
    float T_ambient_K;
    float h_conv;            /* convective HTC [W/m²·K] */
    float layer_time_s;
    float dt_fixed;          /* fixed time step [s]     */
} UhcChamberParams;

/**
 * Layer record — returned after each deposition layer.
 */
typedef struct {
    int   layer_id;
    float z_top_mm;
    float melt_volume_mm3;
    float avg_density;
    float peak_T_K;
    int   n_breach;
    float laser_power_W;
    float scan_time_s;
} UhcLayerRecord;

/**
 * FPGA device configuration for ZCU104.
 */
typedef struct {
    const char* xclbin_path;     /* path to .xclbin on host filesystem  */
    uint32_t    device_index;    /* /dev/xdma* index (0 = xdma0)        */
    uint32_t    axi_lite_addr;   /* AXI Lite base address [hex]          */
    uint32_t    stream_tid;      /* AXI Stream target ID                 */
    float       clock_MHz;       /* PL clock frequency [MHz]             */
    uint32_t    flags;           /* bit0=enable_thermal, bit1=enable_laser */
} UhcFpgaConfig;

/* ================================================================== */
/*  Library lifecycle                                                  */
/* ================================================================== */

/**
 * @brief Initialise the native engine.
 * @param backend preferred backend (BACKEND_AUTO = let the library choose)
 * @return 0 on success, -1 on failure
 */
int uhc_initialize(UhcBackend backend);

/**
 * @brief Shut down the native engine and free all resources.
 */
void uhc_shutdown(void);

/**
 * @brief Query which backend is currently active.
 * @return UhcBackend enum value
 */
UhcBackend uhc_active_backend(void);

/* ================================================================== */
/*  FPGA: device open / close                                          */
/* ================================================================== */

/**
 * @brief Open ZCU104 device, load xclbin, map AXI Lite + AXI Stream.
 * @param config FPGA device configuration
 * @return opaque handle, or nullptr on failure
 */
UhcFpgaHandle uhc_fpga_open(const UhcFpgaConfig* config);

/**
 * @brief Close FPGA device and release all mappings.
 */
void uhc_fpga_close(UhcFpgaHandle h);

/**
 * @brief Write a batch of laser commands to the FPGA AXI Stream.
 * @param h        FPGA handle
 * @param cmds     array of LaserCommand
 * @param n_cmds   number of commands
 * @return number of commands accepted, or -1 on error
 */
int uhc_fpga_write_laser_stream(UhcFpgaHandle h,
                                const UhcLaserCommand* cmds,
                                int n_cmds);

/**
 * @brief Read thermal feedback from FPGA AXI Lite / DMA.
 * @param h        FPGA handle
 * @param readings output buffer (size = n_readings)
 * @param n_readings max number of readings to read
 * @return number of readings actually read, or -1 on error
 */
int uhc_fpga_read_thermal(UhcFpgaHandle h,
                          UhcThermalReading* readings,
                          int n_readings);

/**
 * @brief Read FPGA emergency-stop flag (polled at 1 kHz).
 * @return 1 if e-stop is active, 0 otherwise
 */
int uhc_fpga_get_emergency_stop(UhcFpgaHandle h);

/**
 * @brief Write AXI Lite control register (generic).
 * @param h       FPGA handle
 * @param reg_off byte offset from AXI Lite base
 * @param value   32-bit value to write
 */
void uhc_fpga_write_reg(UhcFpgaHandle h, uint32_t reg_off, uint32_t value);

/**
 * @brief Read AXI Lite control register (generic).
 */
uint32_t uhc_fpga_read_reg(UhcFpgaHandle h, uint32_t reg_off);

/* ================================================================== */
/*  FPGA: PID laser control (runs on ZCU104 PS or via host fallback)  */
/* ================================================================== */

/**
 * @brief Run PID-controlled laser scan for one full layer.
 *
 * The PID runs on the FPGA PS (Cortex-A53) when BACKEND_FPGA is active,
 * or on the host CPU when falling back to BACKEND_CPU.
 *
 * @param h          FPGA handle (can be nullptr for CPU-only)
 * @param segments   scan path segments
 * @param T_measured measured temperatures (one per segment)
 * @param P_eff_out  effective power output per segment
 * @param e_stop_out 1.0 if thermal runaway detected
 * @param n_segments number of segments
 * @param T_target   desired melt-pool temperature [K]
 * @param params     UHTC material/geometry parameters
 * @return 0 on success
 */
int uhc_pid_laser_scan(UhcFpgaHandle h,
                       const UhcScanSegment* segments,
                       const float* T_measured,
                       float* P_eff_out,
                       float* e_stop_out,
                       int n_segments,
                       float T_target,
                       const UhcParams* params);

/* ================================================================== */
/*  CUDA: thermal diffusion solver                                     */
/* ================================================================== */

/**
 * @brief Create a thermal solver instance on the GPU (or CPU fallback).
 */
UhcThermalHandle uhc_thermal_create(float voxel_size_mm);

/**
 * @brief Destroy a thermal solver instance.
 */
void uhc_thermal_destroy(UhcThermalHandle h);

/**
 * @brief Set laser source parameters for the thermal solver.
 */
int uhc_thermal_set_laser(UhcThermalHandle h, const float* laser /* 9 floats */);

/**
 * @brief Set chamber boundary conditions.
 */
int uhc_thermal_set_chamber(UhcThermalHandle h, const float* chamber /* 5 floats */);

/**
 * @brief Initialise material fields for the given material ID.
 */
int uhc_thermal_initialise_material(UhcThermalHandle h, int material_id);

/**
 * @brief Advance the thermal solver by n_steps time steps.
 */
int uhc_thermal_step(UhcThermalHandle h, int n_steps);

/**
 * @brief Read back the temperature field to a flat float buffer.
 * @param buffer host buffer (must be pre-allocated, size = n_voxels)
 */
int uhc_thermal_read_temperature(UhcThermalHandle h, float* buffer, int n_voxels);

/**
 * @brief Export the temperature field as a NanoVDB file.
 */
int uhc_thermal_export_nvdb(UhcThermalHandle h, const char* filename);

/* ================================================================== */
/*  CUDA: deposition layer manager                                     */
/* ================================================================== */

UhcDepositHandle uhc_deposit_create(float voxel_size_mm);
void             uhc_deposit_destroy(UhcDepositHandle h);

/**
 * @brief Run one deposition layer.
 * @param path_xy    interleaved x,y coordinates (2 floats per segment)
 * @param path_power laser power per segment
 * @param n_segments number of segments in the path
 * @param z_layer_mm layer height [mm]
 * @param material_id material ID
 * @param porosity   target porosity [0-1]
 */
int uhc_deposit_layer(UhcDepositHandle h,
                      const float* path_xy,
                      const float* path_power,
                      int n_segments,
                      float z_layer_mm,
                      int material_id,
                      float porosity);

/**
 * @brief Read back the layer record for a completed layer.
 * @param record 8 floats: layer_id, z_top, melt_vol, avg_density, peak_T, n_breach, power, time
 */
int uhc_deposit_get_layer_record(UhcDepositHandle h, int layer_index, float* record);

int uhc_deposit_export_report(UhcDepositHandle h, const char* filename);

/* ================================================================== */
/*  CUDA: oxygen-barrier evaluator                                     */
/* ================================================================== */

UhcO2BarrierHandle uhc_o2barrier_create(float t_critical_mm, float t_layer_s,
                                         float T_process_K, float P_chamber_atm);
void               uhc_o2barrier_destroy(UhcO2BarrierHandle h);

int uhc_o2barrier_evaluate(UhcO2BarrierHandle h,
                            const float* sdf,
                            const float* grad_mag,
                            const float* void_fraction,
                            float* t_pen,
                            float* barrier_flag,
                            float* tortuosity,
                            int n_columns);

int uhc_o2barrier_export_csv(UhcO2BarrierHandle h, const char* filename);

/* ================================================================== */
/*  Material property queries (CPU-safe, used by all backends)         */
/* ================================================================== */

float uhc_mat_thermal_conductivity(int material_id, float T_K);
float uhc_mat_specific_heat    (int material_id, float T_K);
float uhc_mat_density          (int material_id, float T_K);
float uhc_mat_emissivity       (int material_id, float T_K);
float uhc_mat_radiative_flux   (int material_id, float T_K, float T_ambient_K);
float uhc_mat_oxygen_barrier   (float t_wall_mm, float tortuosity, float t_layer_s);

/* ================================================================== */
/*  UHTC SDF evaluation (FPGA-accelerated when available)              */
/* ================================================================== */

/**
 * @brief Evaluate aperiodic SDF field for a batch of lattice points.
 *
 * When BACKEND_FPGA is active this offloads to krnl_uhc_sdf on Alveo/ZCU104.
 * Otherwise runs on CPU.
 *
 * @param points    packed xyz (3 floats per point)
 * @param sdf_out   output SDF values [mm]
 * @param barrier_out 1.0 if O2-sealed, 0.0 if breach
 * @param k_out     thermal conductivity at T_melt [W/m·K]
 * @param laser_q   laser power density [W/mm³]
 * @param o2_time   O2 diffusion time through wall [s]
 * @param n_points  number of points
 * @param params    UHTC parameters
 */
int uhc_evaluate_sdf(const float* points,
                     float* sdf_out,
                     float* barrier_out,
                     float* k_out,
                     float* laser_q,
                     float* o2_time,
                     int n_points,
                     const UhcParams* params);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_ENGINE_API_H */
