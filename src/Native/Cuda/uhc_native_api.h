// SPDX-License-Identifier: Apache-2.0
//
// uhc_native_api.h
//
// C-linkage function declarations for the UHTC native shared library.
// These are the symbols imported by C# via DllImport.
//
// Build with:
//   cmake -DUHC_BUILD_API=ON ..
// Produces: libuhtc_native_accel.so / uhtc_native_accel.dll

#ifndef UHC_NATIVE_API_H
#define UHC_NATIVE_API_H

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Opaque handles ---- */
typedef void* UhcThermalSolverHandle;
typedef void* UhcDepositHandle;
typedef void* UhcO2BarrierHandle;

/* ================================================================== */
/*  Thermal solver API                                                 */
/* ================================================================== */

UhcThermalSolverHandle uhc_thermal_create(float voxel_size_mm);
void                   uhc_thermal_destroy(UhcThermalSolverHandle h);
int                    uhc_thermal_set_laser(UhcThermalSolverHandle h, const float* laser_source /* 9 floats */);
int                    uhc_thermal_set_chamber(UhcThermalSolverHandle h, const float* chamber /* 5 floats */);
int                    uhc_thermal_initialise_material(UhcThermalSolverHandle h, int material_id);
int                    uhc_thermal_step(UhcThermalSolverHandle h, int n_steps);
int                    uhc_thermal_read_temperature(UhcThermalSolverHandle h, float* buffer, int n);
int                    uhc_thermal_export_nvdb(UhcThermalSolverHandle h, const char* filename);

/* ================================================================== */
/*  Deposition manager API                                             */
/* ================================================================== */

UhcDepositHandle uhc_deposit_create(float voxel_size_mm);
void             uhc_deposit_destroy(UhcDepositHandle h);
int              uhc_deposit_layer(UhcDepositHandle h,
                                   const float* path_xy,   /* interleaved x,y */
                                   const float* path_power,
                                   int n_segments,
                                   float z_layer_mm,
                                   int   material_id,
                                   float porosity);
int              uhc_deposit_get_layer_record(UhcDepositHandle h, int layer_index, float* record /* 8 floats */);
int              uhc_deposit_export_report(UhcDepositHandle h, const char* filename);

/* ================================================================== */
/*  Oxygen-barrier evaluator API                                       */
/* ================================================================== */

UhcO2BarrierHandle uhc_o2barrier_create(float t_critical_mm, float t_layer_s,
                                         float T_process_K, float P_chamber_atm);
void               uhc_o2barrier_destroy(UhcO2BarrierHandle h);
int                uhc_o2barrier_evaluate(UhcO2BarrierHandle h,
                                           const float* sdf,
                                           const float* grad_mag,
                                           const float* void_fraction,
                                           float* t_pen,
                                           float* barrier_flag,
                                           float* tortuosity,
                                           int n_columns);
int                uhc_o2barrier_export_csv(UhcO2BarrierHandle h, const char* filename);

/* ================================================================== */
/*  Material property queries                                          */
/* ================================================================== */

float uhc_mat_thermal_conductivity(int material_id, float T_K);
float uhc_mat_specific_heat    (int material_id, float T_K);
float uhc_mat_density          (int material_id, float T_K);
float uhc_mat_emissivity       (int material_id, float T_K);
float uhc_mat_radiative_flux   (int material_id, float T_K, float T_ambient_K);
float uhc_mat_oxygen_barrier   (float t_wall_mm, float tortuosity, float t_layer_s);

#ifdef __cplusplus
}
#endif

#endif /* UHC_NATIVE_API_H */
