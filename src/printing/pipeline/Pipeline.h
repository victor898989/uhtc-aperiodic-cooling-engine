// 3D Printing Pipeline - Core stages
// From geometry input to printer-ready output
#pragma once

namespace printing {
namespace pipeline {

enum class PipelineStage {
    GEOMETRY_INPUT,
    VOXELIZATION,
    THERMAL_SIMULATION,
    SLICING,
    PATH_PLANNING,
    EXPORT
};

const char* stage_name(PipelineStage stage);

struct PipelineConfig {
    double voxel_size;              // mm
    int grid_resolution_x;
    int grid_resolution_y;
    int grid_resolution_z;
    double layer_thickness;         // mm
    int slice_count;
    double laser_power;             // W
    double scan_speed;              // mm/s
    double hatch_spacing;           // mm
};

}
}
