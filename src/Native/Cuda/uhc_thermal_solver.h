// SPDX-License-Identifier: Apache-2.0
//
// uhc_thermal_solver.h
//
// C++ class declaration for the thermal diffusion solver.
// Forward declaration only — full implementation lives in uhc_thermal_solver.cu.

#ifndef UHC_THERMAL_SOLVER_H
#define UHC_THERMAL_SOLVER_H

#include "uhc_material_properties.h"
#include <nanovdb/cuda/DeviceBuffer.h>
#include <string>

namespace nanovdb { template<typename T> class Grid; }

class UHCThermalSolver
{
public:
    UHCThermalSolver(float voxel_size_mm);
    ~UHCThermalSolver() = default;

    void initialise_material_zrb2();
    void step(int n_steps);
    void export_temperature(const char* filename);

    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_T;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_k;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_rho;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_cp;

    nanovdb::Grid<nanovdb::FloatTree>* d_T   = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_k   = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_rho = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_cp  = nullptr;

    struct LaserSource {
        float px, py, pz;
        float P, eta;
        float sx, sy, sz;
        float scan_speed;
    };
    struct ChamberParams {
        float T_substrate, T_ambient, h_conv;
        float layer_time_s, dt_fixed;
    };

    LaserSource   d_laser;
    ChamberParams d_chamber;
    float         dx;
    int           n_active;
};

#endif /* UHC_THERMAL_SOLVER_H */
