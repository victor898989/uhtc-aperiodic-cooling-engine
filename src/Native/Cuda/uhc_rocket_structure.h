// SPDX-License-Identifier: Apache-2.0
//
// uhc_rocket_structure.h
//
// Configuration and API for UHTC rocket / robust-structure voxel engine.
//
// ========================================================================

#ifndef UHC_ROCKET_STRUCTURE_H
#define UHC_ROCKET_STRUCTURE_H

#include <cstdint>
#include <cstddef>

#ifdef __cplusplus
extern "C" {
#endif

/* ===================================================================== */
/*  RocketConfig                                                          */
/* ===================================================================== */

typedef struct {
    /* ---- geometry ---- */
    float chamber_length_mm;    /* length of cylindrical chamber [mm] */
    float chamber_radius_mm;    /* inner radius of chamber [mm] */
    float nose_length_mm;       /* ogive nose cone length [mm] */
    float nose_radius_mm;       /* nose cone base radius [mm] */
    float wall_thickness_mm;    /* chamber wall thickness [mm] */

    /* ---- lattice insulation ---- */
    float lattice_freq_mm;      /* gyroid spatial frequency [1/mm] (0=off) */
    float lattice_wall_thickness; /* gyroid wall offset (0.05-0.5 typical) */
    int   enable_lattice;       /* 1 = enable aperiodic lattice barrier */

    /* ---- voxel grid ---- */
    float voxel_size_mm;        /* voxel edge length [mm] */

    /* ---- thermal ---- */
    float T_ambient_K;          /* build chamber / ambient [K] */
    float convection_coeff;     /* h_conv [W/(m²·K)] */
    float dt;                   /* time step [s] */
    float Q_combustion_W_mm3;   /* volumetric combustion heat [W/mm³] */
} RocketConfig;

/* ===================================================================== */
/*  C API (callable from C# / Python)                                     */
/* ===================================================================== */

/**
 * Load RocketConfig from JSON file.
 * Returns 0 on success, -1 on error.
 */
int loadRocketConfig(const char* json_path, RocketConfig* out_cfg);

/**
 * Create rocket thermal solver instance.
 * Returns opaque handle, or NULL on failure.
 */
void* rocket_solver_create(const RocketConfig* cfg);

/**
 * Advance solver by one time step.
 */
void rocket_solver_step(void* handle);

/**
 * Run N steps, reporting peak T every report_interval_s.
 */
void rocket_solver_run(void* handle, int n_steps, float report_interval_s);

/**
 * Export final temperature field to NanoVDB file.
 */
void rocket_solver_export_temperature(void* handle, const char* filename);

/**
 * Destroy solver instance and free device memory.
 */
void rocket_solver_destroy(void* handle);

#ifdef __cplusplus
}
#endif

#endif /* UHC_ROCKET_STRUCTURE_H */
