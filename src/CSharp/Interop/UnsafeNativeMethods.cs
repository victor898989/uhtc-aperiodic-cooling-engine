// SPDX-License-Identifier: Apache-2.0
//
// UHTC Engine — P/Invoke Interop Layer
//
// Bridges C# geometry engine → C++/CUDA/FPGA native acceleration.
// Single DLL: libuhtc_native_accel.so (Linux) / UhtcNativeEngine.dll (Windows)
//
// Three execution backends:
//   BACKEND_CUDA — thermal diffusion, deposition, oxygen-barrier eval
//   BACKEND_FPGA  — ZCU104 real-time laser/galvo control via AXI DTPI/Stream
//   BACKEND_CPU   — scalar fallback (always available)
//
// All structs below must match NativeEngineAPI.h exactly (field order + size).

using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;

namespace UhtcAperiodicCoolingEngine.Interop;

/* ================================================================== */
/*  Backend enum                                                       */
/* ================================================================== */

public enum UhcBackend : int
{
    Auto   = 0,
    Cuda   = 1,
    Fpga   = 2,
    Cpu    = 3
}

/* ================================================================== */
/*  POD structs — byte-layout must match NativeEngineAPI.h             */
/* ================================================================== */

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcLaserCommand
{
    public ushort PowerW;
    public ushort GalvoX;
    public ushort GalvoY;
    public ushort ModFreq;
    public ushort ModPhase;
    public ushort Reserved0;
    public uint   Reserved1;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcThermalReading
{
    public float  TemperatureK;
    public float  DtDt;
    public uint   EmergencyStop;
    public uint   TimestampMs;
    public uint   NSamples;
    public uint   Reserved0;
    public float  Reserved1;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcScanSegment
{
    public float X;
    public float Y;
    public float Speed;
    public float Power;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcParams
{
    public int   GeometryType;
    public float Freq;
    public float WallThickness;
    public float Split;
    public float TCriticalMm;
    public float Tortuosity;
    public float TMeltK;
    public float TAmbientK;
    public float LayerTimeS;
    public int   MaterialId;
    public float LaserX;
    public float LaserY;
    public float LaserZ;
    public float LaserPowerW;
    public float LaserEta;
    public float ScanSpeedMmS;
    public float EllipseX;
    public float EllipseY;
    public float EllipseZ;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcChamberParams
{
    public float TSubstrateK;
    public float TAmbientK;
    public float HConv;
    public float LayerTimeS;
    public float DtFixed;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcLayerRecord
{
    public int   LayerId;
    public float ZTopMm;
    public float MeltVolumeMm3;
    public float AvgDensity;
    public float PeakTK;
    public int   NBreach;
    public float LaserPowerW;
    public float ScanTimeS;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct UhcFpgaConfig
{
    [MarshalAs(UnmanagedType.LPStr)] public string XclbinPath;
    public uint DeviceIndex;
    public uint AxiLiteAddr;
    public uint StreamTid;
    public float ClockMHz;
    public uint Flags;
}

/* ================================================================== */
/*  NativeBridge — all DllImport declarations                          */
/* ================================================================== */

internal static partial class NativeBridge
{
    private const string NativeLib = "uhtc_native_accel";

    /* ================================================================ */
    /*  Library lifecycle                                               */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_initialize")]
    public static extern int Initialize(UhcBackend backend);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_shutdown")]
    public static extern void Shutdown();

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_active_backend")]
    public static extern UhcBackend ActiveBackend();

    /* ================================================================ */
    /*  FPGA: ZCU104 / Alveo device management                          */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_open")]
    public static extern IntPtr FpgaOpen(in UhcFpgaConfig config);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_close")]
    public static extern void FpgaClose(IntPtr fpgaHandle);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_write_laser_stream")]
    public static extern int FpgaWriteLaserStream(
        IntPtr fpgaHandle,
        [In] ReadOnlySpan<UhcLaserCommand> cmds,
        int nCmds);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_read_thermal")]
    public static extern int FpgaReadThermal(
        IntPtr fpgaHandle,
        [Out] Span<UhcThermalReading> readings,
        int nReadings);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_get_emergency_stop")]
    public static extern int FpgaGetEmergencyStop(IntPtr fpgaHandle);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_write_reg")]
    public static extern void FpgaWriteReg(IntPtr fpgaHandle, uint regOffset, uint value);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_fpga_read_reg")]
    public static extern uint FpgaReadReg(IntPtr fpgaHandle, uint regOffset);

    /* ================================================================ */
    /*  PID laser scan (host CPU or FPGA offload)                       */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_pid_laser_scan")]
    public static extern int PidLaserScan(
        IntPtr fpgaHandle,
        [In] ReadOnlySpan<UhcScanSegment> segments,
        [In] ReadOnlySpan<float> TMeasured,
        [Out] Span<float> PEffOut,
        [Out] Span<float> eStopOut,
        int nSegments,
        float TTarget,
        in UhcParams parameters);

    /* ================================================================ */
    /*  CUDA: thermal diffusion solver                                  */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_create")]
    public static extern IntPtr ThermalCreate(float voxelSizeMm);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_destroy")]
    public static extern void ThermalDestroy(IntPtr thermalHandle);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_set_laser")]
    public static extern int ThermalSetLaser(IntPtr thermalHandle, in LaserSourceNative laser);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_set_chamber")]
    public static extern int ThermalSetChamber(IntPtr thermalHandle, in UhcChamberParams chamber);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_initialise_material")]
    public static extern int ThermalInitialiseMaterial(IntPtr thermalHandle, int materialId);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_step")]
    public static extern int ThermalStep(IntPtr thermalHandle, int nSteps);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_read_temperature")]
    public static extern int ThermalReadTemperature(IntPtr thermalHandle, [Out] Span<float> buffer, int nVoxels);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_thermal_export_nvdb")]
    public static extern int ThermalExportNvdb(IntPtr thermalHandle, [MarshalAs(UnmanagedType.LPStr)] string filename);

    /* ================================================================ */
    /*  CUDA: deposition layer manager                                  */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_deposit_create")]
    public static extern IntPtr DepositCreate(float voxelSizeMm);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_deposit_destroy")]
    public static extern void DepositDestroy(IntPtr depositHandle);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_deposit_layer")]
    public static extern int DepositLayer(
        IntPtr depositHandle,
        [In] ReadOnlySpan<float> pathXy,       /* interleaved x0,y0,x1,y1,... */
        [In] ReadOnlySpan<float> pathPower,
        int nSegments,
        float zLayerMm,
        int materialId,
        float porosity);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_deposit_get_layer_record")]
    public static extern int DepositGetLayerRecord(IntPtr depositHandle, int layerIndex, out UhcLayerRecord record);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_deposit_export_report")]
    public static extern int DepositExportReport(IntPtr depositHandle, [MarshalAs(UnmanagedType.LPStr)] string filename);

    /* ================================================================ */
    /*  CUDA: oxygen-barrier evaluator                                  */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_o2barrier_create")]
    public static extern IntPtr O2BarrierCreate(float tCriticalMm, float tLayerS, float TProcessK, float PChamberAtm);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_o2barrier_destroy")]
    public static extern void O2BarrierDestroy(IntPtr barrierHandle);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_o2barrier_evaluate")]
    public static extern int O2BarrierEvaluate(
        IntPtr barrierHandle,
        [In] ReadOnlySpan<float> sdf,
        [In] ReadOnlySpan<float> gradMag,
        [In] ReadOnlySpan<float> voidFraction,
        [Out] Span<float> tPen,
        [Out] Span<float> barrierFlag,
        [Out] Span<float> tortuosity,
        int nColumns);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_o2barrier_export_csv")]
    public static extern int O2BarrierExportCsv(IntPtr barrierHandle, [MarshalAs(UnmanagedType.LPStr)] string filename);

    /* ================================================================ */
    /*  Material property queries                                       */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_mat_thermal_conductivity")]
    public static extern float MaterialThermalConductivity(int materialId, float T_K);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_mat_specific_heat")]
    public static extern float MaterialSpecificHeat(int materialId, float T_K);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_mat_density")]
    public static extern float MaterialDensity(int materialId, float T_K);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_mat_emissivity")]
    public static extern float MaterialEmissivity(int materialId, float T_K);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_mat_radiative_flux")]
    public static extern float MaterialRadiativeFlux(int materialId, float T_K, float TAmbientK);

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_mat_oxygen_barrier")]
    public static extern float MaterialOxygenBarrier(float tWallMm, float tortuosity, float tLayerS);

    /* ================================================================ */
    /*  UHTC SDF field evaluation                                       */
    /* ================================================================ */

    [DllImport(NativeLib, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "uhc_evaluate_sdf")]
    public static extern int EvaluateSdf(
        [In]  ReadOnlySpan<float> points,
        [Out] Span<float> sdfOut,
        [Out] Span<float> barrierOut,
        [Out] Span<float> kOut,
        [Out] Span<float> laserQOut,
        [Out] Span<float> o2TimeOut,
        int nPoints,
        in UhcParams parameters);
}

/* ================================================================== */
/*  Supporting structs used by the bridge                              */
/* ================================================================== */

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct LaserSourceNative
{
    public float Px;
    public float Py;
    public float Pz;
    public float Power;
    public float Eta;
    public float Sx;
    public float Sy;
    public float Sz;
    public float ScanSpeed;
}
