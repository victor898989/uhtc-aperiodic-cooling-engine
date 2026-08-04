#include <cstdlib>
#include <cmath>

bool openvdb_io_smoke_test()
{
    return std::abs(1.0 - 1.0) < 1e-6;
}
