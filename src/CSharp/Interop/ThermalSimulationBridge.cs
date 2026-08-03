// SPDX-License-Identifier: Apache-2.0
//
// ThermalSimulationBridge.cs
//
// Managed C# facade for the UHTC Native Engine.
// Wraps all UnsafeNativeMethods P/Invoke calls into a safe, idiomatic API
// for the C# geometry engine (Engine.Cooling, Engine.Crystallography,
// Engine.ShapeKernel).
//
// Execution flow:
//   1. GeometryEngine generates aperiodic lattice + scan path (C#)
//   2. ThermalSimulationBridge uploads points + params to native layer
//   3. Native engine evaluates SDF, runs thermal/O₂ kernels (CUDA or FPGA)
//   4. Results are read back as Span<T> or Stream<T>
//
// Threading model:
//   - One ThermalSimulationBridge instance per simulation session.
//   - Native handles are NOT thread-safe; do not share across threads.
//   - The bridge implements IDisposable to free native resources.

using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;

namespace UhtcAperiodicCoolingEngine.Interop;

/* ================================================================== */
/*  ThermalSimulationBridge — primary entry point for C# consumers    */
/* ================================================================== */

public sealed class ThermalSimulationBridge : IDisposable
{
    /* ---- Native handles ---- */
    private IntPtr _fpgaHandle    = IntPtr.Zero;
    private IntPtr _thermalHandle = IntPtr.Zero;
    private IntPtr _depositHandle = IntPtr.Zero;
    private IntPtr _o2Handle      = IntPtr.Zero;

    private bool _disposed;

    /* ---- Active backend ---- */
    public UhcBackend ActiveBackend { get; private set; } = UhcBackend.Auto;

    /* ================================================================ */
    /*  Construction / destruction                                      */
    /* ================================================================ */

    public ThermalSimulationBridge(UhcBackend preferredBackend = UhcBackend.Auto)
    {
        int rc = NativeBridge.Initialize(preferredBackend);
        if (rc != 0)
            throw new InvalidOperationException(
                $"Native engine initialisation failed (rc={rc}). "
              + "Check that libuhtc_native_accel.so is on LD_LIBRARY_PATH.");

        ActiveBackend = NativeBridge.ActiveBackend();
    }

    ~ThermalSimulationBridge()
    {
        DisposeInternal();
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            DisposeInternal();
            GC.SuppressFinalize(this);
        }
    }

    private void DisposeInternal()
    {
        if (_thermalHandle != IntPtr.Zero)
        {
            NativeBridge.ThermalDestroy(_thermalHandle);
            _thermalHandle = IntPtr.Zero;
        }
        if (_depositHandle != IntPtr.Zero)
        {
            NativeBridge.DepositDestroy(_depositHandle);
            _depositHandle = IntPtr.Zero;
        }
        if (_o2Handle != IntPtr.Zero)
        {
            NativeBridge.O2BarrierDestroy(_o2Handle);
            _o2Handle = IntPtr.Zero;
        }
        if (_fpgaHandle != IntPtr.Zero)
        {
            NativeBridge.FpgaClose(_fpgaHandle);
            _fpgaHandle = IntPtr.Zero;
        }
        NativeBridge.Shutdown();
        _disposed = true;
    }

    /* ================================================================ */
    /*  FPGA device management                                          */
    /* ================================================================ */

    /// <summary>
    ///   Opens a ZCU104 (or Alveo) FPGA device.
    ///   Must be called before any FPGA-backed operation.
    /// </summary>
    public void OpenFpgaDevice(UhcFpgaConfig config)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _fpgaHandle = NativeBridge.FpgaOpen(in config);
        if (_fpgaHandle == IntPtr.Zero)
            throw new InvalidOperationException(
                $"FPGA device open failed (xclbin: {config.XclbinPath}). "
              + "Check XRT installation and /dev/uio* permissions.");
    }

    public bool IsFpgaOpen => _fpgaHandle != IntPtr.Zero;

    /// <summary>
    ///   Streams a batch of laser commands to the FPGA AXI4-Stream port.
    /// </summary>
    public int WriteLaserStream(ReadOnlySpan<UhcLaserCommand> commands)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfFpgaNotOpen();
        return NativeBridge.FpgaWriteLaserStream(_fpgaHandle, commands, commands.Length);
    }

    /// <summary>
    ///   Reads thermal feedback from the FPGA AXI Lite / DMA.
    /// </summary>
    public int ReadThermalFeedback(Span<UhcThermalReading> readings)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfFpgaNotOpen();
        return NativeBridge.FpgaReadThermal(_fpgaHandle, readings, readings.Length);
    }

    /// <summary>
    ///   Polls the FPGA emergency-stop flag.
    /// </summary>
    public bool IsEmergencyStopActive
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ThrowIfFpgaNotOpen();
            return NativeBridge.FpgaGetEmergencyStop(_fpgaHandle) != 0;
        }
    }

    public void WriteFpgaRegister(uint registerOffset, uint value)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfFpgaNotOpen();
        NativeBridge.FpgaWriteReg(_fpgaHandle, registerOffset, value);
    }

    public uint ReadFpgaRegister(uint registerOffset)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfFpgaNotOpen();
        return NativeBridge.FpgaReadReg(_fpgaHandle, registerOffset);
    }

    /// <summary>
    ///   Runs a PID-controlled laser scan for one full layer.
    ///   Executes on FPGA if available, otherwise on the CPU.
    /// </summary>
    public void RunPidLaserScan(
        ReadOnlySpan<UhcScanSegment> segments,
        ReadOnlySpan<float> measuredTemperatures,
        Span<float> effectivePowerOutput,
        Span<float> emergencyStopFlag,
        float targetTemperatureK,
        in UhcParams parameters)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (segments.Length != measuredTemperatures.Length)
            throw new ArgumentException("segments and measuredTemperatures must have the same length.");
        if (effectivePowerOutput.Length < segments.Length)
            throw new ArgumentException("effectivePowerOutput must accommodate all segments.");
        if (emergencyStopFlag.Length < 1)
            throw new ArgumentException("emergencyStopFlag must have length >= 1.");

        int rc = NativeBridge.PidLaserScan(
            _fpgaHandle,
            segments,
            measuredTemperatures,
            effectivePowerOutput,
            emergencyStopFlag,
            segments.Length,
            targetTemperatureK,
            in parameters);

        if (rc != 0)
            throw new InvalidOperationException($"PID laser scan failed (rc={rc}).");
    }

    /* ================================================================ */
    /*  CUDA thermal diffusion solver                                   */
    /* ================================================================ */

    /// <summary>
    ///   Creates the CUDA thermal solver handle.
    ///   Throws if CUDA is not available and BACKEND_CUDA was requested.
    /// </summary>
    public IntPtr CreateThermalSolver(float voxelSizeMm)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        IntPtr h = NativeBridge.ThermalCreate(voxelSizeMm);
        if (h == IntPtr.Zero)
            throw new InvalidOperationException(
                "Thermal solver creation failed. "
              + "Ensure CUDA is installed and NANOVDB_USE_CUDA=1 was set at build time.");
        _thermalHandle = h;
        return h;
    }

    public void DestroyThermalSolver()
    {
        if (_thermalHandle != IntPtr.Zero)
        {
            NativeBridge.ThermalDestroy(_thermalHandle);
            _thermalHandle = IntPtr.Zero;
        }
    }

    public void ThermalSetLaser(in LaserSourceNative laser)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_thermalHandle, nameof(_thermalHandle));
        int rc = NativeBridge.ThermalSetLaser(_thermalHandle, in laser);
        if (rc != 0) ThrowNativeError("ThermalSetLaser", rc);
    }

    public void ThermalSetChamber(in UhcChamberParams chamber)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_thermalHandle, nameof(_thermalHandle));
        int rc = NativeBridge.ThermalSetChamber(_thermalHandle, in chamber);
        if (rc != 0) ThrowNativeError("ThermalSetChamber", rc);
    }

    public void ThermalInitialiseMaterial(int materialId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_thermalHandle, nameof(_thermalHandle));
        int rc = NativeBridge.ThermalInitialiseMaterial(_thermalHandle, materialId);
        if (rc != 0) ThrowNativeError("ThermalInitialiseMaterial", rc);
    }

    public void ThermalStep(int nSteps)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_thermalHandle, nameof(_thermalHandle));
        int rc = NativeBridge.ThermalStep(_thermalHandle, nSteps);
        if (rc != 0) ThrowNativeError("ThermalStep", rc);
    }

    /// <summary>
    ///   Reads back the full temperature field into a pre-allocated buffer.
    /// </summary>
    public void ThermalReadTemperature(Span<float> buffer)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_thermalHandle, nameof(_thermalHandle));
        int rc = NativeBridge.ThermalReadTemperature(_thermalHandle, buffer, buffer.Length);
        if (rc != 0) ThrowNativeError("ThermalReadTemperature", rc);
    }

    public void ThermalExportNvdb(string filename)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_thermalHandle, nameof(_thermalHandle));
        int rc = NativeBridge.ThermalExportNvdb(_thermalHandle, filename);
        if (rc != 0) ThrowNativeError("ThermalExportNvdb", rc);
    }

    /* ================================================================ */
    /*  CUDA deposition manager                                         */
    /* ================================================================ */

    public IntPtr CreateDepositManager(float voxelSizeMm)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        IntPtr h = NativeBridge.DepositCreate(voxelSizeMm);
        if (h == IntPtr.Zero)
            throw new InvalidOperationException("Deposit manager creation failed (CUDA unavailable?).");
        _depositHandle = h;
        return h;
    }

    public void DestroyDepositManager()
    {
        if (_depositHandle != IntPtr.Zero)
        {
            NativeBridge.DepositDestroy(_depositHandle);
            _depositHandle = IntPtr.Zero;
        }
    }

    public void DepositLayer(
        ReadOnlySpan<float> pathXy,       /* interleaved x0,y0,x1,y1,... */
        ReadOnlySpan<float> pathPower,
        int nSegments,
        float zLayerMm,
        int materialId,
        float porosity)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_depositHandle, nameof(_depositHandle));
        int rc = NativeBridge.DepositLayer(
            _depositHandle, pathXy, pathPower, nSegments,
            zLayerMm, materialId, porosity);
        if (rc != 0) ThrowNativeError("DepositLayer", rc);
    }

    /// <summary>
    ///   Reads the layer record for a completed deposition layer.
    /// </summary>
    public UhcLayerRecord GetLayerRecord(int layerIndex)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_depositHandle, nameof(_depositHandle));
        int rc = NativeBridge.DepositGetLayerRecord(_depositHandle, layerIndex, out UhcLayerRecord rec);
        if (rc != 0) ThrowNativeError("DepositGetLayerRecord", rc);
        return rec;
    }

    public void DepositExportReport(string filename)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_depositHandle, nameof(_depositHandle));
        int rc = NativeBridge.DepositExportReport(_depositHandle, filename);
        if (rc != 0) ThrowNativeError("DepositExportReport", rc);
    }

    /* ================================================================ */
    /*  CUDA oxygen-barrier evaluator                                   */
    /* ================================================================ */

    public IntPtr CreateO2Barrier(
        float tCriticalMm,
        float tLayerS,
        float TProcessK,
        float PChamberAtm)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        IntPtr h = NativeBridge.O2BarrierCreate(tCriticalMm, tLayerS, TProcessK, PChamberAtm);
        if (h == IntPtr.Zero)
            throw new InvalidOperationException("O₂ barrier creation failed (CUDA unavailable?).");
        _o2Handle = h;
        return h;
    }

    public void DestroyO2Barrier()
    {
        if (_o2Handle != IntPtr.Zero)
        {
            NativeBridge.O2BarrierDestroy(_o2Handle);
            _o2Handle = IntPtr.Zero;
        }
    }

    public void O2BarrierEvaluate(
        ReadOnlySpan<float> sdf,
        ReadOnlySpan<float> gradMag,
        ReadOnlySpan<float> voidFraction,
        Span<float> tPenetration,
        Span<float> barrierFlag,
        Span<float> tortuosity,
        int nColumns)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_o2Handle, nameof(_o2Handle));
        int rc = NativeBridge.O2BarrierEvaluate(
            _o2Handle, sdf, gradMag, voidFraction,
            tPenetration, barrierFlag, tortuosity, nColumns);
        if (rc != 0) ThrowNativeError("O2BarrierEvaluate", rc);
    }

    public void O2BarrierExportCsv(string filename)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ThrowIfHandleInvalid(_o2Handle, nameof(_o2Handle));
        int rc = NativeBridge.O2BarrierExportCsv(_o2Handle, filename);
        if (rc != 0) ThrowNativeError("O2BarrierExportCsv", rc);
    }

    /* ================================================================ */
    /*  SDF evaluation                                                  */
    /* ================================================================ */

    /// <summary>
    ///   Evaluates the aperiodic SDF field for a batch of lattice points.
    ///   Offloads to FPGA when available, otherwise CPU.
    /// </summary>
    public void EvaluateSdf(
        ReadOnlySpan<float> points,       /* packed xyz, 3 floats per point */
        Span<float> sdfOut,
        Span<float> barrierOut,
        Span<float> kOut,
        Span<float> laserQOut,
        Span<float> o2TimeOut,
        in UhcParams parameters)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (points.Length % 3 != 0)
            throw new ArgumentException("points must contain xyz triples (length multiple of 3).");
        if (sdfOut.Length     < points.Length / 3) throw new ArgumentException(nameof(sdfOut));
        if (barrierOut.Length < points.Length / 3) throw new ArgumentException(nameof(barrierOut));
        if (kOut.Length       < points.Length / 3) throw new ArgumentException(nameof(kOut));
        if (laserQOut.Length   < points.Length / 3) throw new ArgumentException(nameof(laserQOut));
        if (o2TimeOut.Length   < points.Length / 3) throw new ArgumentException(nameof(o2TimeOut));

        int rc = NativeBridge.EvaluateSdf(
            points, sdfOut, barrierOut, kOut, laserQOut, o2TimeOut,
            points.Length / 3, in parameters);
        if (rc != 0) ThrowNativeError("EvaluateSdf", rc);
    }

    /* ================================================================ */
    /*  Material queries (CPU-safe, no native handle needed)            */
    /* ================================================================ */

    public static float MatThermalConductivity(int materialId, float T_K)
        => NativeBridge.MaterialThermalConductivity(materialId, T_K);

    public static float MatSpecificHeat(int materialId, float T_K)
        => NativeBridge.MaterialSpecificHeat(materialId, T_K);

    public static float MatDensity(int materialId, float T_K)
        => NativeBridge.MaterialDensity(materialId, T_K);

    public static float MatEmissivity(int materialId, float T_K)
        => NativeBridge.MaterialEmissivity(materialId, T_K);

    public static float MatRadiativeFlux(int materialId, float T_K, float TAmbientK)
        => NativeBridge.MaterialRadiativeFlux(materialId, T_K, TAmbientK);

    public static float MatOxygenBarrier(float tWallMm, float tortuosity, float tLayerS)
        => NativeBridge.MaterialOxygenBarrier(tWallMm, tortuosity, tLayerS);

    /* ================================================================ */
    /*  Helpers                                                         */
    /* ================================================================ */

    [DoesNotReturn]
    private static void ThrowNativeError(string function, int rc)
        => throw new InvalidOperationException($"{function} returned error code {rc}.");

    [DoesNotReturn]
    private void ThrowIfFpgaNotOpen()
    {
        if (!IsFpgaOpen)
            throw new InvalidOperationException(
                "FPGA device is not open. Call OpenFpgaDevice() first.");
    }

    [DoesNotReturn]
    private void ThrowIfHandleInvalid(IntPtr handle, string name)
    {
        if (handle == IntPtr.Zero)
            throw new InvalidOperationException(
                $"{name} is invalid. The native handle was not created or was destroyed.");
    }
}
