/**
 * @file fpga_laser_control.cpp
 *
 * UHTC FPGA Laser-Control Kernel
 * Target: AMD Alveo U250 / ZCU104
 *
 * Runs in lock-step with krnl_uhc_sdf.  For each voxel column (x, y)
 * the kernel receives the current melt-pool temperature and computes
 * the adjusted laser power to maintain T_target.
 *
 * A simple discrete PID regulates the effective laser power P_eff:
 *   e_n  = T_target - T_measured
 *   P_n  = Kp*e_n + Ki*sum(e) + Kd*(e_n - e_{n-1})
 *   P_n  = clamp(P_n, P_min, P_max)
 *
 * Safety guards:
 *   - Thermal runaway: if T_measured > T_critical → emergency stop flag
 *   - Over-speed: if scan_speed > v_max → reduce power linearly
 */

#include "uhc_fpga_types.h"

/* ------------------------------------------------------------------ */
/*  PID gains — tuned for ZrB2-SiC, 500 W laser, 5 mm/s scan          */
/* ------------------------------------------------------------------ */
#define PID_KP   8.0f
#define PID_KI   0.5f
#define PID_KD   1.5f
#define P_MIN    50.0f       /* W */
#define P_MAX    1200.0f     /* W */
#define T_CRITICAL_OFFSET 600.0f  /* K above T_target that triggers e-stop */

/* ------------------------------------------------------------------ */
/*  Scan-path lookup table — pre-computed in C# host, streamed to FPGA */
/*  Each entry encodes the next (x, y) laser focus position and the   */
/*  expected speed for that segment.                                   */
/* ------------------------------------------------------------------ */

typedef struct {
    float x, y;
    float speed;
    float power;
} ScanSegment;

/**
 * @brief PID-regulated laser power for one voxel column.
 *
 * @param T_measured   current voxel temperature [K] (from thermal sensor)
 * @param T_target     desired melt-pool temperature [K]
 * @param e_prev       previous error (for D term) [K]
 * @param integral_sum accumulated integral term [K·s]
 * @param scan_speed   current scan speed [mm/s]
 * @param params       global UHTC parameters
 * @param e_stop       output: 1.0 if thermal runaway detected
 *
 * @return effective laser power [W]
 */
static inline float pid_laser_power(float T_measured, float T_target,
                                     float* e_prev, float* integral_sum,
                                     float scan_speed,
                                     const UHTCParams* params,
                                     float* e_stop)
{
    float e_n = T_target - T_measured;

    /* Thermal runaway guard */
    if (T_measured > T_target + T_CRITICAL_OFFSET) {
        *e_stop = 1.0f;
        return 0.0f;
    }
    *e_stop = 0.0f;

    /* Anti-windup: clamp integral */
    *integral_sum += e_n;
    if (*integral_sum >  2000.0f) *integral_sum =  2000.0f;
    if (*integral_sum < -2000.0f) *integral_sum = -2000.0f;

    float P = PID_KP * e_n + PID_KI * (*integral_sum) + PID_KD * (e_n - *e_prev);
    *e_prev = e_n;

    /* Over-speed compensation: linear derating above 15 mm/s */
    float v_max = 15.0f;
    if (scan_speed > v_max) {
        P *= v_max / scan_speed;
    }

    /* Clamp to safe operating window */
    if (P < P_MIN) P = P_MIN;
    if (P > P_MAX) P = P_MAX;

    return P;
}

extern "C" {

/**
 * @brief Batch PID controller for a full layer scan path.
 *
 * Scan path is supplied as a stream of ScanSegment structs.
 * The kernel writes the emergency-stop flag to e_stop_out.
 *
 * @param segments      array of ScanSegment[segments_per_layer]
 * @param T_measured    measured temperature per segment [K]
 * @param P_eff_out     computed effective power per segment [W]
 * @param e_stop_out    1.0 if any segment triggered thermal runaway
 * @param n_segments    number of scan segments in this layer
 * @param T_target      melt-pool temperature [K]
 * @param params        global UHTC parameters
 */
void krnl_uhc_pid_control(const ScanSegment* segments,
                           const float*        T_measured,
                           float*              P_eff_out,
                           float*              e_stop_out,
                           const int           n_segments,
                           const float         T_target,
                           const UHTCParams*   params)
{
#pragma HLS INTERFACE m_axi port=segments    offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi port=T_measured  offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi port=P_eff_out   offset=slave bundle=gmem2
#pragma HLS INTERFACE m_axi port=e_stop_out  offset=slave bundle=gmem3
#pragma HLS INTERFACE s_axilite port=n_segments
#pragma HLS INTERFACE s_axilite port=T_target
#pragma HLS INTERFACE s_axilite port=params
#pragma HLS INTERFACE s_axilite port=return

    float e_stop_acc = 0.0f;

    for (int i = 0; i < n_segments; ++i) {
#pragma HLS PIPELINE II=1
        float e_prev = 0.0f;
        float integral = 0.0f;
        float e_stop = 0.0f;

        P_eff_out[i] = pid_laser_power(
            T_measured[i], T_target,
            &e_prev, &integral,
            segments[i].speed,
            params,
            &e_stop
        );

        e_stop_acc += e_stop;
    }

    e_stop_out[0] = (e_stop_acc > 0.0f) ? 1.0f : 0.0f;
}

/**
 * @brief Thermal runaway guard — runs at max sample rate (independent of scan path).
 *
 * Reads a rolling buffer of recent temperature readings and asserts e-stop
 * if the rate of temperature rise exceeds dT/dt_max.
 *
 * @param T_history      ring buffer of recent temperatures [K]
 * @param dt_sample_s    time between samples [s]
 * @param dT_dt_max      maximum safe temperature rise rate [K/s]
 * @param e_stop_out     1.0 if runaway detected
 */
void krnl_uhc_thermal_guard(const float* T_history,
                              float         dt_sample_s,
                              float         dT_dt_max,
                              float*        e_stop_out)
{
#pragma HLS INTERFACE m_axi port=T_history   offset=slave bundle=gmem0
#pragma HLS INTERFACE s_axilite port=dt_sample_s
#pragma HLS INTERFACE s_axilite port=dT_dt_max
#pragma HLS INTERFACE m_axi port=e_stop_out  offset=slave bundle=gmem1
#pragma HLS INTERFACE s_axilite port=return

    const int WINDOW = 16;
    float dT = T_history[WINDOW - 1] - T_history[0];
    float dt = dt_sample_s * (WINDOW - 1);
    float rate = (dt > 0.0f) ? (dT / dt) : 0.0f;

    e_stop_out[0] = (rate > dT_dt_max) ? 1.0f : 0.0f;
}

} /* extern "C" */
