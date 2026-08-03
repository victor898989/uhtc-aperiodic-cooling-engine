namespace UhtcAperiodicCoolingEngine.Interop;

using System.Runtime.InteropServices;

internal static class UnsafeNativeMethods
{
    [LibraryImport("uhtc_native_accel", EntryPoint = "evaluate_field_cuda")]
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvCdecl) })]
    public static partial int EvaluateFieldCuda(float* pVoxels, int nCount, float fTimeStep);

    [LibraryImport("uhtc_native_accel", EntryPoint = "dilate_nanovdb")]
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvCdecl) })]
    public static partial int DilateNanoVDB(IntPtr pGrid, int nRadius);

    [LibraryImport("uhtc_native_accel", EntryPoint = "xrt_submit_kernel")]
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvCdecl) })]
    public static partial int XrtSubmitKernel(IntPtr pCmdBuf, uint nSize);
}
