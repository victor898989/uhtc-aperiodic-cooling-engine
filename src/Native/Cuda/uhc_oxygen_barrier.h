// SPDX-License-Identifier: Apache-2.0
//
// uhc_oxygen_barrier.h
//
// C++ class declaration for the aperiodic oxygen-barrier evaluator.

#ifndef UHC_OXYGEN_BARRIER_H
#define UHC_OXYGEN_BARRIER_H

#include <nanovdb/cuda/DeviceBuffer>
#include <string>

namespace nanovdb { template<typename T> class Grid; }

class UHCOxygenBarrier
{
public:
    UHCOxygenBarrier(float t_crit, float t_lay, float T_proc, float P_ch);
    ~UHCOxygenBarrier() = default;

    void evaluate(int n_columns);
    void export_results(const char* filename);

    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_sdf;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_t_pen;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_barrier;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_tau;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_phi;

    nanovdb::Grid<nanovdb::FloatTree>* d_sdf     = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_t_pen   = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_barrier = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_tau     = nullptr;
    nanovdb::Grid<nanovdb::FloatTree>* d_phi     = nullptr;

    float t_critical_mm;
    float t_layer_s;
    float T_process_K;
    float P_chamber_atm;
};

#endif /* UHC_OXYGEN_BARRIER_H */
