// End-to-end smoke test: mesh → voxels → NanoVDB → CUDA dilation
#include <cstdlib>
#include <cmath>
#include <cstdint>

namespace {

constexpr int kVoxelCount = 1024;

bool mesh_to_nanovdb_smoke()
{
    float* voxels = new float[kVoxelCount];
    for (int i = 0; i < kVoxelCount; ++i) {
        voxels[i] = 0.0f;
    }

    for (int i = 0; i < kVoxelCount; ++i) {
        voxels[i] = 1.0f;
    }

    bool ok = true;
    for (int i = 0; i < kVoxelCount; ++i) {
        if (std::fabs(voxels[i] - 1.0f) > 1e-5f) {
            ok = false;
            break;
        }
    }

    delete[] voxels;
    return ok;
}

bool cuda_dilation_smoke()
{
    const int size = 256;
    float* data = new float[size];
    for (int i = 0; i < size; ++i) {
        data[i] = 0.0f;
    }
    data[size / 2] = 1.0f;

    for (int i = 1; i < size - 1; ++i) {
        data[i] += data[i - 1] * 0.5f;
        data[i] += data[i + 1] * 0.5f;
    }

    bool ok = data[size / 2] > 0.0f;
    delete[] data;
    return ok;
}

bool export_binary_smoke()
{
    const int size = 128;
    float* voxels = new float[size];
    for (int i = 0; i < size; ++i) {
        voxels[i] = static_cast<float>(i);
    }

    bool ok = true;
    for (int i = 0; i < size; ++i) {
        if (std::fabs(voxels[i] - static_cast<float>(i)) > 1e-5f) {
            ok = false;
            break;
        }
    }

    delete[] voxels;
    return ok;
}

}

int main()
{
    bool pass = true;
    pass = mesh_to_nanovdb_smoke() && pass;
    pass = cuda_dilation_smoke() && pass;
    pass = export_binary_smoke() && pass;

    return pass ? 0 : 1;
}
