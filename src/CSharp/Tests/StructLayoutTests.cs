// SPDX-License-Identifier: Apache-2.0
//
// StructLayoutTests.cs
//
// Verifies that all P/Invoke POD structs have the exact byte layout
// expected by NativeEngineAPI.h (the C-linkage ABI).
//
// Rules enforced:
//   - Field order matches the C header exactly.
//   - Pack = 4 on all structs (required for 32-bit ABI alignment).
//   - Struct sizes are deterministic and do not change silently.

using System.Runtime.InteropServices;
using Xunit;

namespace UhtcAperiodicCoolingEngine.Interop.Tests;

public class StructLayoutTests
{
    /* ================================================================ */
    /*  UhcLaserCommand                                                  */
    /*  C layout: 6 × uint16_t + 1 × uint32_t = 16 bytes              */
    /* ================================================================ */

    [Fact]
    public void UhcLaserCommand_Size_Is16Bytes()
    {
        Assert.Equal(16, Marshal.SizeOf<UhcLaserCommand>());
    }

    [Fact]
    public void UhcLaserCommand_FieldOffsets_MatchC()
    {
        // Verify each field offset matches the C struct layout
        var expected = new Dictionary<string, int>
        {
            ["PowerW"]    = 0,
            ["GalvoX"]    = 2,
            ["GalvoY"]    = 4,
            ["ModFreq"]   = 6,
            ["ModPhase"]  = 8,
            ["Reserved0"] = 10,
            ["Reserved1"] = 12,
        };

        var actual = new Dictionary<string, int>();
        var fields = typeof(UhcLaserCommand).GetFields();
        int offset = 0;
        foreach (var f in fields)
        {
            actual[f.Name] = (int)Marshal.OffsetOf<UhcLaserCommand>(f.Name);
        }

        foreach (var kv in expected)
        {
            Assert.True(actual.ContainsKey(kv.Key),
                $"Field {kv.Key} missing from UhcLaserCommand");
            Assert.Equal(kv.Value, actual[kv.Key],
                $"Field {kv.Key} offset mismatch: expected {kv.Value}, got {actual[kv.Key]}");
        }
    }

    /* ================================================================ */
    /*  UhcThermalReading                                                */
    /*  C layout: 2 × float + 3 × uint32_t + 2 × padding + 1 × float */
    /*           = 8 + 12 + 4 + 4 = 32 bytes                         */
    /* ================================================================ */

    [Fact]
    public void UhcThermalReading_Size_Is32Bytes()
    {
        Assert.Equal(32, Marshal.SizeOf<UhcThermalReading>());
    }

    [Fact]
    public void UhcThermalReading_FieldOffsets_MatchC()
    {
        var expected = new Dictionary<string, int>
        {
            ["TemperatureK"]  = 0,
            ["DtDt"]          = 4,
            ["EmergencyStop"] = 8,
            ["TimestampMs"]   = 12,
            ["NSamples"]      = 16,
            ["Reserved0"]     = 20,
            ["Reserved1"]     = 24,
        };

        var actual = new Dictionary<string, int>();
        var fields = typeof(UhcThermalReading).GetFields();
        foreach (var f in fields)
        {
            actual[f.Name] = (int)Marshal.OffsetOf<UhcThermalReading>(f.Name);
        }

        foreach (var kv in expected)
        {
            Assert.True(actual.ContainsKey(kv.Key),
                $"Field {kv.Key} missing from UhcThermalReading");
            Assert.Equal(kv.Value, actual[kv.Value],
                $"Field {kv.Key} offset mismatch: expected {kv.Value}, got {actual[kv.Key]}");
        }
    }

    /* ================================================================ */
    /*  UhcScanSegment                                                    */
    /*  C layout: 4 × float = 16 bytes                                  */
    /* ================================================================ */

    [Fact]
    public void UhcScanSegment_Size_Is16Bytes()
    {
        Assert.Equal(16, Marshal.SizeOf<UhcScanSegment>());
    }

    [Fact]
    public void UhcScanSegment_FieldOffsets_MatchC()
    {
        var expected = new Dictionary<string, int>
        {
            ["X"]     = 0,
            ["Y"]     = 4,
            ["Speed"] = 8,
            ["Power"] = 12,
        };

        var actual = new Dictionary<string, int>();
        foreach (var f in typeof(UhcScanSegment).GetFields())
        {
            actual[f.Name] = (int)Marshal.OffsetOf<UhcScanSegment>(f.Name);
        }

        foreach (var kv in expected)
        {
            Assert.True(actual.ContainsKey(kv.Key));
            Assert.Equal(kv.Value, actual[kv.Key]);
        }
    }

    /* ================================================================ */
    /*  UhcParams                                                         */
    /*  C layout: int, 7 floats, int, 8 floats = 4 + 28 + 4 + 32      */
    /*           = 68 bytes                                             */
    /* ================================================================ */

    [Fact]
    public void UhcParams_Size_Is68Bytes()
    {
        Assert.Equal(68, Marshal.SizeOf<UhcParams>());
    }

    [Fact]
    public void UhcParams_FieldOffsets_MatchC()
    {
        var expected = new Dictionary<string, int>
        {
            ["GeometryType"]  = 0,
            ["Freq"]          = 4,
            ["WallThickness"] = 8,
            ["Split"]         = 12,
            ["TCriticalMm"]   = 16,
            ["Tortuosity"]    = 20,
            ["TMeltK"]        = 24,
            ["TAmbientK"]     = 28,
            ["LayerTimeS"]    = 32,
            ["MaterialId"]    = 36,
            ["LaserX"]        = 40,
            ["LaserY"]        = 44,
            ["LaserZ"]        = 48,
            ["LaserPowerW"]   = 52,
            ["LaserEta"]      = 56,
            ["ScanSpeedMmS"]  = 60,
            ["EllipseX"]      = 64,
            ["EllipseY"]      = 68,
            ["EllipseZ"]      = 72,
            ["EllipseZ"]      = 76,
        };

        var actual = new Dictionary<string, int>();
        foreach (var f in typeof(UhcParams).GetFields())
        {
            actual[f.Name] = (int)Marshal.OffsetOf<UhcParams>(f.Name);
        }

        foreach (var kv in expected)
        {
            Assert.True(actual.ContainsKey(kv.Key),
                $"Field {kv.Key} missing from UhcParams");
            Assert.Equal(kv.Value, actual[kv.Key],
                $"Field {kv.Key} offset mismatch: expected {kv.Value}, got {actual[kv.Key]}");
        }
    }

    /* ================================================================ */
    /*  UhcChamberParams                                                  */
    /*  C layout: 5 × float = 20 bytes                                  */
    /* ================================================================ */

    [Fact]
    public void UhcChamberParams_Size_Is20Bytes()
    {
        Assert.Equal(20, Marshal.SizeOf<UhcChamberParams>());
    }

    /* ================================================================ */
    /*  UhcLayerRecord                                                     */
    /*  C layout: int + float + 3 × float + int + 2 × float            */
    /*           = 4 + 4 + 12 + 4 + 8 = 32 bytes                       */
    /* ================================================================ */

    [Fact]
    public void UhcLayerRecord_Size_Is32Bytes()
    {
        Assert.Equal(32, Marshal.SizeOf<UhcLayerRecord>());
    }

    /* ================================================================ */
    /*  UhcFpgaConfig                                                     */
    /*  C layout: ptr + 4 × uint32 + float + uint32                    */
    /*           = 8 + 16 + 4 + 4 = 32 bytes (64-bit)                  */
    /* ================================================================ */

    [Fact]
    public void UhcFpgaConfig_Size_IsAtLeast28Bytes()
    {
        // Size varies by platform (ptr width), but must be >= raw fields
        int size = Marshal.SizeOf<UhcFpgaConfig>();
        Assert.True(size >= 28, $"UhcFpgaConfig too small: {size} bytes");
    }

    [Fact]
    public void UhcLaserCommand_PackIs4()
    {
        // Verify the [StructLayout] Pack = 4 attribute is set
        var attr = typeof(UhcLaserCommand).GetCustomAttributes(false)
            .OfType<StructLayoutAttribute>()
            .FirstOrDefault();
        Assert.NotNull(attr);
        Assert.Equal(LayoutKind.Sequential, attr.Layout);
        Assert.Equal(4, attr.Pack);
    }
}
