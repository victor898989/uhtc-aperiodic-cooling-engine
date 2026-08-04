// Pipeline stage implementations
#include "Pipeline.h"
#include <cstring>

namespace printing {
namespace pipeline {

const char* stage_name(PipelineStage stage) {
    switch (stage) {
        case PipelineStage::GEOMETRY_INPUT:  return "Geometry Input";
        case PipelineStage::VOXELIZATION:    return "Voxelization";
        case PipelineStage::THERMAL_SIMULATION: return "Thermal Simulation";
        case PipelineStage::SLICING:         return "Slicing";
        case PipelineStage::PATH_PLANNING:   return "Path Planning";
        case PipelineStage::EXPORT:          return "Export";
        default: return "Unknown";
    }
}

}
}
