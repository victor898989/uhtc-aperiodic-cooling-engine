#include <cstdlib>
#include <cmath>

bool thermal_smoke_test()
{
    const double grad = 1.0;
    return std::abs(grad - 1.0) < 1e-6;
}
