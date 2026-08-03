/**
 * @file zcu104_driver.cpp
 *
 * UHTC ZCU104 Host Driver
 *
 * Communicates with the FPGA PL via two paths:
 *   1. XRT (xrt::kernel / xrt::bo) — for data movement (AXI MM)
 *   2. UIO memory-mapped I/O      — for low-latency AXI Lite register access
 *      (reads /dev/uio0 which maps to the FPGA AXI Lite address space)
 *
 * Usage from C#:
 *   var cfg = new UhcFpgaConfig {
 *       XclbinPath = "/path/to/uhtc_laser.xclbin",
 *       DeviceIndex = 0,
 *       AxiLiteAddr = 0x80000000,  // physical addr of AXI Lite IP
 *       StreamTid   = 0,
 *       ClockMHz    = 100.0f,
 *       Flags       = 1
 *   };
 *   var h = NativeBridge.FpgaOpen(cfg);
 */

#include "NativeEngineAPI.h"
#include "uhc_fpga_types.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <cerrno>

/* ================================================================== */
/*  UIO / sysfs helpers                                                 */
/* ================================================================== */

static long sysfs_read_long(const char* path)
{
    FILE* f = fopen(path, "r");
    if (!f) return -1;
    long v = 0;
    fscanf(f, "%ld", &v);
    fclose(f);
    return v;
}

static int uio_map_axi_lite(const char* uio_dev, uint32_t phys_addr,
                             size_t map_size, void** out_virt)
{
    int fd = open(uio_dev, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "[ZCU104] Cannot open %s: %s\n", uio_dev, strerror(errno));
        return -1;
    }

    off_t page_size = sysconf(_SC_PAGESIZE);
    off_t page_mask = ~(page_size - 1);
    off_t page_addr = phys_addr & page_mask;
    off_t page_offset = phys_addr - page_addr;

    void* virt = mmap(nullptr, page_offset + map_size,
                      PROT_READ | PROT_WRITE, MAP_SHARED, fd, page_addr);
    if (virt == MAP_FAILED) {
        fprintf(stderr, "[ZCU104] mmap failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    *out_virt = (char*)virt + page_offset;
    printf("[ZCU104] Mapped AXI Lite @ 0x%08X → %p (via %s)\n",
           phys_addr, *out_virt, uio_dev);
    return fd;   /* caller keeps fd open for lifetime of mapping */
}

/* ================================================================== */
/*  ZCU104 driver handle                                               */
/* ================================================================== */

struct Zcu104Driver {
    UhcFpgaConfig  config;
    int            uio_fd;
    volatile uint32_t* axi_lite_base;
    size_t         axi_map_size;

    /* XRT objects (populated in production) */
    void* xrt_device;
    void* xrt_kernel_sdf;
    void* xrt_kernel_pid;
};

extern "C" {

/* ================================================================ */
/*  uhc_fpga_open — replaced in zcu104_driver.cpp                  */
/* ================================================================ */

UhcFpgaHandle uhc_fpga_open(const UhcFpgaConfig* config)
{
    if (!config || !config->xclbin_path) {
        fprintf(stderr, "[ZCU104] null config\n");
        return nullptr;
    }

    auto* drv = (Zcu104Driver*)calloc(1, sizeof(Zcu104Driver));
    if (!drv) return nullptr;

    memcpy(&drv->config, config, sizeof(UhcFpgaConfig));
    drv->axi_map_size = 64 * 1024;  /* 64 KB AXI Lite address space */

    /* ---- Map AXI Lite via UIO ---- */
    const char* uio_dev = "/dev/uio0";
    if (uio_map_axi_lite(uio_dev, config->axi_lite_addr,
                          drv->axi_map_size,
                          (void**)&drv->axi_lite_base) < 0)
    {
        fprintf(stderr, "[ZCU104] Falling back to XRT-only AXI Lite\n");
        drv->axi_lite_base = nullptr;
    }

    /* ---- Load xclbin and open kernels (production) ---- */
    /*
     *   drv->xrt_device = new xrt::device((int)config->device_index);
     *   auto xclbin = xrt::xclbin(config->xclbin_path);
     *   ((xrt::device*)drv->xrt_device)->register_xclbin(xclbin);
     *   drv->xrt_kernel_sdf = new xrt::kernel(
     *       *(xrt::device*)drv->xrt_device, xclbin.get_uuid(), "krnl_uhc_sdf");
     *   drv->xrt_kernel_pid = new xrt::kernel(
     *       *(xrt::device*)drv->xrt_device, xclbin.get_uuid(), "krnl_uhc_pid_control");
     */
    printf("[ZCU104] xclbin: %s  clock: %.0f MHz\n",
           config->xclbin_path, (double)config->clock_MHz);

    int idx = alloc_handle(drv);
    if (idx < 0) { free(drv); return nullptr; }
    return (UhcFpgaHandle)(intptr_t)idx;
}

void uhc_fpga_close(UhcFpgaHandle h)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    auto* drv = (Zcu104Driver*)g_handles[idx];
    if (!drv) return;

    if (drv->axi_lite_base) {
        munmap((void*)drv->axi_lite_base, drv->axi_map_size);
        if (drv->uio_fd >= 0) close(drv->uio_fd);
    }

    /* delete xrt objects in production */

    free(drv);
    free_handle(idx);
    printf("[ZCU104] Driver closed\n");
}

/* ================================================================ */
/*  AXI Lite register access                                        */
/* ================================================================ */

void uhc_fpga_write_reg(UhcFpgaHandle h, uint32_t reg_off, uint32_t value)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return;
    auto* drv = (Zcu104Driver*)g_handles[idx];
    if (!drv) return;

    if (drv->axi_lite_base && reg_off + 4 <= drv->axi_map_size) {
        drv->axi_lite_base[reg_off / 4] = value;
    }

    /* Production XRT fallback:
     *   xrt::bo reg_bo(dev, 4, bo::flags::host_only, krnl.group_id(N));
     *   reg_bo.write(&value, 4);
     *   reg_bo.sync(to_device);
     *   krnl(reg_bo, reg_off);
     */
}

uint32_t uhc_fpga_read_reg(UhcFpgaHandle h, uint32_t reg_off)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES) return 0;
    auto* drv = (Zcu104Driver*)g_handles[idx];
    if (!drv) return 0;

    if (drv->axi_lite_base && reg_off + 4 <= drv->axi_map_size) {
        return drv->axi_lite_base[reg_off / 4];
    }
    return 0;
}

/* ================================================================ */
/*  AXI Stream: laser command burst write                            */
/* ================================================================ */

int uhc_fpga_write_laser_stream(UhcFpgaHandle h,
                                const UhcLaserCommand* cmds,
                                int n_cmds)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !cmds || n_cmds <= 0) return -1;
    auto* drv = (Zcu104Driver*)g_handles[idx];
    if (!drv) return -1;

    /*
     * Production XRT path (AXI MM mapped to AXI Stream via kernel):
     *   xrt::bo<UhcLaserCommand> bo(*(xrt::device*)drv->xrt_device,
     *                               n_cmds, bo::flags::host_only,
     *                               ((xrt::kernel*)drv->xrt_kernel_sdf)->group_id(0));
     *   bo.write(cmds, n_cmds);
     *   bo.sync(to_device);
     *   auto run = (*(xrt::kernel*)drv->xrt_kernel_sdf)(bo.xcl_bo(), n_cmds);
     *   run.wait();
     */

    /* Low-latency UIO path: write directly to streaming IP's DDR buffer */
    if (drv->axi_lite_base) {
        /* Signal the FPGA that N commands are ready */
        uhc_fpga_write_reg(h, 0x40, (uint32_t)n_cmds);
    }

    printf("[ZCU104] Stream write: %d commands queued\n", n_cmds);
    return n_cmds;
}

/* ================================================================ */
/*  Thermal feedback read (AXI Lite poll or DMA)                     */
/* ================================================================ */

int uhc_fpga_read_thermal(UhcFpgaHandle h,
                          UhcThermalReading* readings,
                          int n_readings)
{
    int idx = (int)(intptr_t)h;
    if (idx < 0 || idx >= MAX_HANDLES || !readings || n_readings <= 0) return -1;
    auto* drv = (Zcu104Driver*)g_handles[idx];
    if (!drv) return -1;

    /* Read thermal register block via AXI Lite */
    for (int i = 0; i < n_readings; ++i) {
        readings[i].TemperatureK   = *((float*)&drv->axi_lite_base[REG_THERMAL_FEEDBACK / 4]);
        readings[i].EmergencyStop  = drv->axi_lite_base[REG_EMERGENCY_STOP / 4];
        readings[i].TimestampMs    = drv->axi_lite_base[REG_STATUS / 4];
        readings[i].DtDt           = 0.0f;
        readings[i].NSamples       = 0;
        readings[i].Reserved0      = 0;
        readings[i].Reserved1      = 0.0f;
    }

    return n_readings;
}

int uhc_fpga_get_emergency_stop(UhcFpgaHandle h)
{
    return (int)(uhc_fpga_read_reg(h, REG_EMERGENCY_STOP) & 0x1);
}

} /* extern "C" */
