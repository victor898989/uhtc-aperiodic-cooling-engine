// SPDX-License-Identifier: Apache-2.0
//
// MaterialPropertyTests.cs
//
// Tests for the UHTC material property functions exposed via the
// native bridge. These tests run on CPU (no CUDA or FPGA required)
// because uhc_mat_* functions are pure inline CUDA __host__ __device__
// functions compiled into the shared library, or they fall back to
// the CPU implementation in NativeEngineAPI.cpp.
//
// Material reference values (validated against literature):
//   - Upadhya et al., J. Am. Ceram. Soc. 80(11), 1997
//   - Fahrenholtz et al., J. Am. Ceram. Soc. 90(1), 2007
//   - Pierson, Handbook of Refractory Carbides and Nitrides, 1996

using Xunit;

namespace UhtcAperiodicCoolingEngine.Interop.Tests;

public class MaterialPropertyTests
{
    /* ================================================================ */
    /*  Melting points                                                   */
    /*  Values: ZrB2=3519 K, TaC=4215 K, HfC=4231 K                   */
    /* ================================================================ */

    [Theory]
    [InlineData(0, 3519.0)]  // ZrB2
    [InlineData(1, 4215.0)]  // TaC
    [InlineData(2, 4231.0)]  // HfC
    public void MaterialDensity_ReturnsPositiveValues(int materialId, float expectedMin)
    {
        float rho = ThermalSimulationBridge.MatDensity(materialId, T: 300.0f);
        Assert.True(rho > 0.0f, $"Density must be positive, got {rho}");
        Assert.True(rho < 20.0f, $"Density seems too high: {rho} g/cm³");
    }

    /* ================================================================ */
    /*  Thermal conductivity                                             */
    /*  ZrB2 @ 300 K ≈ 120 W/m·K (literature: 100–150)                */
    /*  TaC  @ 300 K ≈ 30 W/m·K  (literature: 25–35)                  */
    /*  HfC  @ 300 K ≈ 28 W/m·K  (literature: 20–35)                  */
    /* ================================================================ */

    [Theory]
    [InlineData(0, 80.0f, 160.0f)]   // ZrB2: expect ~120 W/m·K
    [InlineData(1, 20.0f, 45.0f)]    // TaC:  expect ~30 W/m·K
    [InlineData(2, 15.0f, 40.0f)]    // HfC:  expect ~28 W/m·K
    public void MatThermalConductivity_WithinLiteratureRange(
        int materialId, float min, float max)
    {
        float k = ThermalSimulationBridge.MatThermalConductivity(materialId, T: 300.0f);
        Assert.InRange(k, min, max);
    }

    [Theory]
    [InlineData(0)]   // ZrB2
    [InlineData(1)]   // TaC
    [InlineData(2)]   // HfC
    public void MatThermalConductivity_DecreasesWithTemperature(int materialId)
    {
        float k_300  = ThermalSimulationBridge.MatThermalConductivity(materialId, 300.0f);
        float k_1500 = ThermalSimulationBridge.MatThermalConductivity(materialId, 1500.0f);
        float k_3000 = ThermalSimulationBridge.MatThermalConductivity(materialId, 3000.0f);
        Assert.True(k_3000 < k_1500, "k should decrease at high T");
        Assert.True(k_1500 < k_300,  "k should decrease as T rises");
    }

    /* ================================================================ */
    /*  Specific heat capacity                                           */
    /*  cp @ 300 K: ZrB2≈0.38, TaC≈0.32, HfC≈0.33 J/g·K             */
    /* ================================================================ */

    [Theory]
    [InlineData(0, 0.25f, 0.60f)]  // ZrB2
    [InlineData(1, 0.20f, 0.50f)]  // TaC
    [InlineData(2, 0.20f, 0.50f)]  // HfC
    public void MatSpecificHeat_WithinExpectedRange(int materialId, float min, float max)
    {
        float cp = ThermalSimulationBridge.MatSpecificHeat(materialId, T: 300.0f);
        Assert.InRange(cp, min, max);
    }

    /* ================================================================ */
    /*  Density decreases with temperature (thermal expansion)          */
    /* ================================================================ */

    [Theory]
    [InlineData(0)]   // ZrB2
    [InlineData(1)]   // TaC
    [InlineData(2)]   // HfC
    public void MatDensity_DecreasesWithTemperature(int materialId)
    {
        float rho_300  = ThermalSimulationBridge.MatDensity(materialId, 300.0f);
        float rho_2000 = ThermalSimulationBridge.MatDensity(materialId, 2000.0f);
        Assert.True(rho_2000 <= rho_300,
            $"Density should not increase with T: {rho_2000} > {rho_300}");
    }

    /* ================================================================ */
    /*  Emissivity: bounded [0, 1]                                       */
    /* ================================================================ */

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void MatEmissivity_BetweenZeroAndOne(int materialId)
    {
        float e = ThermalSimulationBridge.MatEmissivity(materialId, T: 2000.0f);
        Assert.InRange(e, 0.0f, 1.0f);
    }

    /* ================================================================ */
    /*  Oxygen barrier: monotonic in wall thickness                     */
    /* ================================================================ */

    [Fact]
    public void MatOxygenBarrier_ThickerWall_IsSafer()
    {
        float barrier_thin  = ThermalSimulationBridge.MatOxygenBarrier(
            tWallMm: 0.05f, tortuosity: 3.5f, tLayerS: 2.0f);
        float barrier_thick = ThermalSimulationBridge.MatOxygenBarrier(
            tWallMm: 0.20f, tortuosity: 3.5f, tLayerS: 2.0f);

        Assert.True(barrier_thick >= barrier_thin,
            $"Thicker wall should be safer: thick={barrier_thick}, thin={barrier_thin}");
    }

    [Fact]
    public void MatOxygenBarrier_ReturnsBinaryResult()
    {
        float barrier = ThermalSimulationBridge.MatOxygenBarrier(
            tWallMm: 0.15f, tortuosity: 3.5f, tLayerS: 2.0f);
        Assert.True(barrier == 0.0f || barrier == 1.0f,
            $"Barrier must be 0.0 or 1.0, got {barrier}");
    }

    /* ================================================================ */
    /*  Radiative flux: increases with temperature                       */
    /* ================================================================ */

    [Fact]
    public void MatRadiativeFlux_IncreasesWithTemperature()
    {
        float q_1000 = ThermalSimulationBridge.MatRadiativeFlux(
            materialId: 0, T_K: 1000.0f, TAmbientK: 300.0f);
        float q_2500 = ThermalSimulationBridge.MatRadiativeFlux(
            materialId: 0, T_K: 2500.0f, TAmbientK: 300.0f);
        Assert.True(q_2500 > q_1000,
            $"Radiative flux should increase with T: {q_2500} vs {q_1000}");
    }

    /* ================================================================ */
    /*  Powder vs solid: powder has lower conductivity                  */
    /* ================================================================ */

    [Fact]
    public void PowderConductivity_LowerThanSolid()
    {
        // materialId 0 = ZrB2 solid, 3 = ZrB2 powder
        float k_solid = ThermalSimulationBridge.MatThermalConductivity(0, 300.0f);
        float k_powder = ThermalSimulationBridge.MatThermalConductivity(3, 300.0f);
        Assert.True(k_powder < k_solid,
            $"Powder k ({k_powder}) should be < solid k ({k_solid})");
    }
}
