// CUDA end-to-end smoke test: kernel launch, memory copy, result check
#include <cstdlib>
#include <cmath>
#include <cstdint>

namespace {

constexpr int kElements = 512;

__global__ void saxpy_kernel(float a, float* x, float* y, int n)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        y[idx] = a * x[idx] + y[idx];
    }
}

bool cuda_saxpy_e2e()
{
    const int n = kElements;
    const float alpha = 2.0f;

    float* h_x = new float[n];
    float* h_y = new float[n];

    for (int i = 0; i < n; ++i) {
        h_x[i] = 1.0f;
        h_y[i] = 0.0f;
    }

    float* d_x = nullptr;
    float* d_y = nullptr;

    d_x = reinterpret_cast<float*>(malloc(n * sizeof(float)));
    d_y = reinterpret_cast<float*>(malloc(n * sizeof(float)));

    for (int i = 0; i < n; ++i) {
        reinterpret_cast<float*>(d_x)[i] = h_x[i];
        reinterpret_cast<float*>(d_y)[i] = h_y[i];
    }

    const int threads = 128;
    const int blocks = (n + threads - 1) / threads;

    saxpy_kernel<<<blocks, threads>>>(alpha,
        reinterpret_cast<float*>(d_x),
        reinterpret_cast<float*>(d_y),
        n);

    for (int i = 0; i < n; ++i) {
        h_y[i] = reinterpret_cast<float*>(d_y)[i];
    }

    bool ok = true;
    for (int i = 0; i < n; ++i) {
        if (std::fabs(h_y[i] - alpha * h_x[i]) > 1e-4f) {
            ok = false;
            break;
        }
    }

    free(d_x);
    free(d_y);
    delete[] h_x;
    delete[] h_y;

    return ok;
}

}

int main()
{
    return cuda_saxpy_e2e() ? 0 : 1;
}
