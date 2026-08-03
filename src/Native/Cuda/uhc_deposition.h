// SPDX-License-Identifier: Apache-2.0
//
// uhc_deposition.h
//
// C++ class declaration for the powder-bed deposition manager.

#ifndef UHC_DEPOSITION_H
#define UHC_DEPOSITION_H

#include <nanovdb/cuda/DeviceBuffer>
#include <string>

namespace nanovdb { template<typename T> class Grid; }

class UHCDepositionManager
{
public:
    struct LayerRecord {
        int   layer_id;
        float z_top_mm;
        float melt_volume_mm3;
        float avg_density;
        float peak_T_K;
        int   n_breach;
        float laser_power_W;
        float scan_time_s;
    };

    UHCDepositionManager(float dx);
    ~UHCDepositionManager() = default;

    void deposit_layer(const float2* d_path, const float* d_power, int n_seg,
                       float z_mm, int mat_id, float porosity);

    void export_layer_report(const char* filename);

    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_state;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_density;
    nanovdb::GridHandle<nanovdb::cuda::DeviceBuffer> h_temp;

    LayerRecord layer_records[256];
    int         n_layers;
};

#endif /* UHC_DEPOSITION_H */
