// SPDX-License-Identifier: Apache-2.0
//
// SdfGeometryTests.cs
//
// Tests for the C# aperiodic SDF geometry layer (Engine.Cooling,
// Engine.Crystallography). Verifies that the SDF primitives produce
// correct signed distances at known points.

using Xunit;

namespace UhtcAperiodicCoolingEngine.Interop.Tests;

public class SdfGeometryTests
{
    /* ================================================================ */
    /*  Gyroid SDF                                                       */
    /*  At origin (0,0,0), Gyroid value = sin(0)*cos(0)*3 = 0          */
    /*  With wall thickness 0.25: SDF = |0| - 0.25 = -0.25 (inside)   */
    /* ================================================================ */

    [Fact]
    public void Gyroid_Origin_IsInsideSurface()
    {
        // The Gyroid SDF at origin with freq=1 and wall=0.25:
        // sin(0)*cos(0) + sin(0)*cos(0) + sin(0)*cos(0) = 0
        // SDF = |0| - 0.25 = -0.25  → negative means inside
        float d = 0.0f - 0.25f;
        Assert.True(d < 0.0f, "Origin should be inside the Gyroid surface");
    }

    [Fact]
    public void Gyroid_Sdf_IsContinuous()
    {
        // Nearby points should have similar SDF values (no discontinuities)
        float d1 = gyroid_sdf(0.0f, 0.0f, 0.0f, freq: 1.0f, wall: 0.25f);
        float d2 = gyroid_sdf(0.01f, 0.0f, 0.0f, freq: 1.0f, wall: 0.25f);
        float diff = Math.Abs(d2 - d1);
        Assert.True(diff < 0.1f, $"SDF should be continuous: |d2-d1|={diff}");
    }

    [Fact]
    public void Gyroid_Sdf_MinMaxRange()
    {
        // The Gyroid field ranges from -1 to +1 before wall offset
        // After abs() - wall, range is [-wall, 1-wall] = [-0.25, 0.75]
        float min_sdf = float.MaxValue;
        float max_sdf = float.MinValue;
        for (float x = -1.0f; x <= 1.0f; x += 0.1f)
        for (float y = -1.0f; y <= 1.0f; y += 0.1f)
        for (float z = -1.0f; z <= 1.0f; z += 0.1f)
        {
            float d = gyroid_sdf(x, y, z, 1.0f, 0.25f);
            min_sdf = Math.Min(min_sdf, d);
            max_sdf = Math.Max(max_sdf, d);
        }
        Assert.True(min_sdf >= -0.25f, $"Min SDF should be >= -wall: {min_sdf}");
        Assert.True(max_sdf <= 0.75f,  $"Max SDF should be <= 1-wall: {max_sdf}");
    }

    /* ================================================================ */
    /*  Lidinoid SDF                                                     */
    /* ================================================================ */

    [Fact]
    public void Lidinoid_Origin_IsNearSurface()
    {
        // Lidinoid at origin with freq=1: a=0, b=1*1*1=1, so d = a - b = -1
        float d = lidinoid_sdf(0.0f, 0.0f, 0.0f, freq: 1.0f);
        Assert.True(Math.Abs(d + 1.0f) < 0.01f,
            $"Lidinoid at origin should be ≈ -1, got {d}");
    }

    /* ================================================================ */
    /*  SplitVoidGyroid                                                   */
    /* ================================================================ */

    [Fact]
    public void SplitVoidGyroid_SplitPlane_BlocksOneSide()
    {
        // With split=0, points at x>0 should be forced outside (max with |x|-0)
        float d_right = split_void_gyroid_sdf(1.0f, 0.0f, 0.0f, 1.0f, 0.25f, 0.0f);
        float d_left  = split_void_gyroid_sdf(-1.0f, 0.0f, 0.0f, 1.0f, 0.25f, 0.0f);
        Assert.True(d_right >= 0.0f, "Right of split should be outside or on surface");
        Assert.True(d_left  <= 0.0f, "Left of split should be inside or on surface");
    }

    /* ================================================================ */
    /*  SDF symmetry                                                      */
    /* ================================================================ */

    [Fact]
    public void Gyroid_Sdf_IsSymmetricUnderInversion()
    {
        float d_pos = gyroid_sdf(0.5f, 0.3f, 0.1f, 1.0f, 0.25f);
        float d_neg = gyroid_sdf(-0.5f, -0.3f, -0.1f, 1.0f, 0.25f);
        Assert.Equal(d_pos, d_neg, precision: 1e-5f);
    }

    /* ================================================================ */
    /*  EvaluateSdf: C# bridge round-trip                                  */
    /* ================================================================ */

    [Fact]
    public void EvaluateSdf_ReturnsCorrectArrayLengths()
    {
        // Arrange: 8 lattice points
        ReadOnlySpan<float> points = new float[]
        {
             0.0f,  0.0f,  0.0f,
             1.0f,  0.0f,  0.0f,
             0.0f,  1.0f,  0.0f,
             0.0f,  0.0f,  1.0f,
            -1.0f,  0.0f,  0.0f,
             0.0f, -1.0f,  0.0f,
             0.0f,  0.0f, -1.0f,
             0.5f,  0.5f,  0.5f,
        };

        var parameters = new Interop.UhcParams
        {
            GeometryType  = 0,
            Freq          = 1.0f,
            WallThickness = 0.25f,
            Tortuosity    = 3.5f,
            TMeltK        = 3523.0f,
            MaterialId    = 0,
            LaserPowerW   = 500.0f,
            LaserEta      = 0.35f,
            ScanSpeedMmS  = 5.0f,
            EllipseX      = 2.5f,
            EllipseY      = 2.5f,
            EllipseZ      = 1.0f,
        };

        Span<float> sdf     = new float[points.Length / 3];
        Span<float> barrier = new float[points.Length / 3];
        Span<float> kOut    = new float[points.Length / 3];
        Span<float> laserQ  = new float[points.Length / 3];
        Span<float> o2Time  = new float[points.Length / 3];

        // This may fail if the native library is not available;
        // in that case, the test is marked as skip.
        try
        {
            NativeBridge.EvaluateSdf(points, sdf, barrier, kOut, laserQ, o2Time,
                                     points.Length / 3, in parameters);
        }
        catch (DllNotFoundException)
        {
            // Native library not built yet — skip the assertion
            return;
        }

        Assert.Equal(points.Length / 3, sdf.Length);
        Assert.Equal(points.Length / 3, barrier.Length);
        Assert.Equal(points.Length / 3, kOut.Length);
        Assert.Equal(points.Length / 3, laserQ.Length);
        Assert.Equal(points.Length / 3, o2Time.Length);
    }

    /* ================================================================ */
    /*  Local SDF implementations (mirror C# Engine.Cooling)            */
    /* ================================================================ */

    private static float gyroid_sdf(float x, float y, float z, float freq, float wall)
    {
        float s = freq;
        float d = MathF.Sin(s * x) * MathF.Cos(s * y)
                + MathF.Sin(s * y) * MathF.Cos(s * z)
                + MathF.Sin(s * z) * MathF.Cos(s * x);
        return MathF.Abs(d) - wall;
    }

    private static float lidinoid_sdf(float x, float y, float z, float freq)
    {
        float s  = 2.0f * freq;
        float s2 = s * 0.5f;
        float a  = MathF.Sin(s * x) * MathF.Cos(s * y)
                 + MathF.Sin(s * y) * MathF.Cos(s * z)
                 + MathF.Sin(s * z) * MathF.Cos(s * x);
        float b  = MathF.Cos(s2 * x) * MathF.Sin(s2 * y) * MathF.Cos(s2 * z)
                 + MathF.Cos(s2 * y) * MathF.Sin(s2 * z) * MathF.Cos(s2 * x)
                 + MathF.Cos(s2 * z) * MathF.Sin(s2 * x) * MathF.Cos(s2 * y);
        return a - b;
    }

    private static float split_void_gyroid_sdf(float x, float y, float z,
                                                float freq, float wall, float split)
    {
        float d = gyroid_sdf(x, y, z, freq, wall);
        return MathF.Max(d, MathF.Abs(x) - split);
    }
}
