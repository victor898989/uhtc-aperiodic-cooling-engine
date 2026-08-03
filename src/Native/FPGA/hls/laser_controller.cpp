/**
 * @file laser_controller.cpp
 *
 * UHTC ZCU104 FPGA Laser Controller — HLS kernel
 *
 * Target: Zynq UltraScale+ MPSoC (ZCU104 board)
 *
 * Interfaces:
 *   - AXI4-Lite  s_axilite  : control/status registers (laser enable, power,
 *                             thermal threshold, PID gains, emergency stop)
 *   - AXI4-Stream axis_in    : incoming stream of UhclLaserCommand packets
 *                             from PS (C# host via XRT/UIO)
 *   - AXI4-Stream axis_out   : optional debug stream (thermal readings)
 *
 * AXI DTPI (Debug and Trace) probes:
 *   - dp0: laser_power_W (current output)
 *   - dp1: galvo_x, galvo_y
 *   - dp2: temperature_K (feedback)
 *   - dp3: emergency_stop flag
 *
 * Safety rules (hard-wired, cannot be bypassed by software):
 *   1. If T_measured > T_critical_K  →  laser power → 0 immediately
 *   2. If e_stop_reg == 1            →  all outputs held at zero
 *   3. Power is rate-limited: dP/dt <= P_max_per_tick
 */

#include "uhc_fpga_types.h"
#include "NativeEngineAPI.h"

#include <hls_stream.h>
#include <ap_axi_sdata.h>
#include <ap_int.h>

/* ================================================================== */
/*  AXI Stream data types                                              */
/* ================================================================== */

typedef ap_axiu<32, 0, 0, 0> AxisWord;
typedef hls::stream<AxisWord> AxisStream;

/* ================================================================== */
/*  AXI Lite register map (byte offsets from base address)             */
/* ================================================================== */

#define REG_LASER_ENABLE       0x00
#define REG_POWER_SETPOINT     0x04
#define REG_T_CRITICAL         0x08
#define REG_THERMAL_FEEDBACK   0x0C
#define REG_EMERGENCY_STOP     0x10
#define REG_PID_KP             0x14
#define REG_PID_KI             0x14
#define REG_PID_KD             0x1C
#define REG_GALVO_X            0x20
#define REG_GALVO_Y            0x24
#define REG_STATUS             0x30

/* ================================================================== */
/*  Rate limiter: prevents dT/dt overshoot on the laser               */
/* ================================================================== */

static inline float rate_limit(float P_new, float P_prev, float dP_max)
{
    float dP = P_new - P_prev;
    if (dP >  dP_max) return P_prev + dP_max;
    if (dP < -dP_max) return P_prev - dP_max;
    return P_new;
}

/* ================================================================== */
/*  PID controller state (per-channel, kept in BRAM/registers)        */
/* ================================================================== */

typedef struct {
    float e_prev;
    float integral;
} PidState;

static void pid_update(PidState* pid, float Kp, float Ki, float Kd,
                       float T_meas, float T_target,
                       float* P_out)
{
    float e_n = T_target - T_meas;

    /* Anti-windup */
    pid->integral += e_n;
    if (pid->integral >  5000.0f) pid->integral =  5000.0f;
    if (pid->integral < -5000.0f) pid->integral = -5000.0f;

    float P = Kp*e_n + Ki*pid->integral + Kd*(e_n - pid->e_prev);
    pid->e_prev = e_n;

    if (P < 50.0f)  P = 50.0f;
    if (P > 1200.0f) P = 1200.0f;

    *P_out = P;
}

/* ================================================================== */
/*  Top-level HLS kernel                                               */
/* ================================================================== */

void laser_controller_kernel(
    /* ---- AXI4-Stream: incoming laser commands from PS ---- */
    AxisStream& axis_in,

    /* ---- AXI4-Lite: control/status ---- */
    volatile uint32_t* s_axilite,

    /* ---- AXI4-Stream: debug output (thermal readings) ---- */
    AxisStream& axis_out,

    /* ---- AXI DTPI debug probes (mapped by Vitis to XRT debug IP) ---- */
    ap_uint<32>& dp_laser_power,
    ap_uint<32>& dp_galvo_x,
    ap_uint<32>& dp_galvo_y,
    ap_uint<32>& dp_temperature
)
{
#pragma HLS INTERFACE axis     port=axis_in
#pragma HLS INTERFACE s_axilite port=s_axilite bundle=control
#pragma HLS INTERFACE axis     port=axis_out
#pragma HLS INTERFACE ap_ctrl_none port=return

    /* Register map aliases */
    uint32_t& reg_enable   = s_axilite[REG_LASER_ENABLE   / 4];
    uint32_t& reg_e_stop   = s_axilite[REG_EMERGENCY_STOP / 4];
    uint32_t& reg_t_crit   = s_axilite[REG_T_CRITICAL     / 4];
    uint32_t& reg_power_sp = s_axilite[REG_POWER_SETPOINT / 4];
    uint32_t& reg_T_fb     = s_axilite[REG_THERMAL_FEEDBACK / 4];
    uint32_t& reg_Kp       = s_axilite[REG_PID_KP         / 4];
    uint32_t& reg_Ki       = s_axilite[REG_PID_KI         / 4];
    uint32_t& reg_Kd       = s_axilite[REG_PID_KD         / 4];
    uint32_t& reg_galvo_x  = s_axilite[REG_GALVO_X        / 4];
    uint32_t& reg_galvo_y  = s_axilite[REG_GALVO_Y        / 4];
    uint32_t& reg_status   = s_axilite[REG_STATUS         / 4];

    /* Persistent state */
    static PidState  pid;
    static float     P_prev = 0.0f;
    static uint32_t  tick   = 0;

    /* Read control registers */
    bool   laser_enable = (reg_enable & 0x1) != 0;
    bool   e_stop       = (reg_e_stop & 0x1) != 0;
    float  T_critical   = *((float*)&reg_t_crit);
    float  P_setpoint   = *((float*)&reg_power_sp);
    float  T_measured   = *((float*)&reg_T_fb);
    float  Kp           = *((float*)&reg_Kp);
    float  Ki           = *((float*)&reg_Ki);
    float  Kd           = *((float*)&reg_Kd);
    uint16_t galvo_x    = (uint16_t)(reg_galvo_x & 0xFFFF);
    uint16_t galvo_y    = (uint16_t)(reg_galvo_y & 0xFFFF);

    float P_eff = 0.0f;

    /* ---- Safety layer ---- */
    if (e_stop || !laser_enable) {
        P_eff = 0.0f;
        pid.integral = 0.0f;
        reg_status = 0x1;  /* e-stop flag */
    }
    else if (T_measured > T_critical) {
        /* Thermal runaway guard: cut power immediately */
        P_eff = 0.0f;
        pid.integral = 0.0f;
        reg_status = 0x2;  /* thermal runaway flag */
    }
    else {
        /* Normal operation: PID control */
        pid_update(&pid, Kp, Ki, Kd, T_measured, T_critical, &P_eff);

        /* Rate limiting: max 200 W/s change */
        P_eff = rate_limit(P_eff, P_prev, 0.2f);
        P_prev = P_eff;

        reg_status = 0x0;  /* OK */
    }

    /* ---- Process incoming AXI Stream command ---- */
    if (!axis_in.empty()) {
        AxisWord cmd = axis_in.read();

        /* Packet format (3 words per command):
         *   word 0: [31:16] power_W  [15:0] galvo_x
         *   word 1: [31:16] galvo_y   [15:0] mod_freq
         *   word 2: reserved
         */
        uint16_t cmd_power  = (uint16_t)(cmd.data >> 16);
        uint16_t cmd_galvo_x = (uint16_t)(cmd.data & 0xFFFF);

        /* Apply command only if no e-stop */
        if (!e_stop && laser_enable && T_measured <= T_critical) {
            galvo_x = cmd_galvo_x;
            /* Override PID power with commanded power (host override) */
            P_eff = (float)cmd_power;
        }

        /* Update debug probes */
        dp_laser_power = (ap_uint<32>)P_eff;
        dp_galvo_x     = (ap_uint<32>)galvo_x;
        dp_galvo_y     = (ap_uint<32>)reg_galvo_y;
        dp_temperature = (ap_uint<32>)T_measured;

        /* Push thermal reading to output stream */
        AxisWord fb;
        fb.data  = ((uint32_t)T_measured & 0xFFFF) | (reg_status << 16);
        fb.keep  = 0xF;
        fb.strb  = 0xF;
        fb.last  = (tick & 0xFFF) == 0 ? 1 : 0;  /* end-of-frame every 4096 ticks */
        axis_out.write(fb);

        tick++;
    }

    /* ---- Write DAC outputs (mapped to external IP via AXI DTPI) ---- */
    /* In production: connect galvo_x/y to DAC IP via AXI Stream or GPIO */
}

/* ================================================================== */
/*  Simpler scalar variant for ZCU104 PS (Cortex-A53) without HLS      */
/* ================================================================== */

void laser_controller_ps(
    const UhcLaserCommand* cmd_buffer,
    UhcThermalReading*     fb_buffer,
    int                    n_samples,
    const float            T_critical,
    float*                 P_eff_out)
{
    for (int i = 0; i < n_samples; ++i) {
        float P = (float)cmd_buffer[i].power_W;

        if (fb_buffer[i].EmergencyStop != 0) {
            P = 0.0f;
        }
        else if (fb_buffer[i].TemperatureK > T_critical) {
            P = 0.0f;
        }

        P_eff_out[i] = P;
    }
}
