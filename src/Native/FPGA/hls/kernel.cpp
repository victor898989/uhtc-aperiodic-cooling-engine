/**
 * UHTC Aperiodic Cooling Engine — FPGA Kernel v2
 * Target: AMD Alveo U250 / ZCU104 (Zynq UltraScale+ MPSoC)
 *
 * Replaces placeholder VAdd with domain-specific SDF evaluation for
 * aperiodic lattice geometries (Gyroid, Lidinoid) used as passive oxygen
 * barriers in ultra-high-temperature ceramic (UHTC) additive manufacturing.
 *
 * The aperiodic wall thickness t_min is the critical geometric parameter:
 *   - if t_min < t_critical  → O2 can diffuse through tortuous channels
 *   - if t_min >= t_critical → oxygen ingress blocked geometrically
 *
 * Material model: ZrB2-SiC default (highest TRL for UHTC AM)
 *   - T_melt      = 3246 °C  (ZrB2)
 *   - k_cond      = 60 W/m·K @ 25°C, falls to ~25 W/m·K @ 2000°C
 *   - cp          = 0.55 J/g·K
 *   - rho         = 6.09 g/cm³
 *   - emissivity  = 0.82  (oxide-coated surface)
 */

#include "uhc_fpga_types.h"

/* ------------------------------------------------------------------ */
/*  Aperiodic SDF primitives (unit-cell, evaluated per-lattice point)  */
/* ------------------------------------------------------------------ */

static inline float sdf_gyroid(float x, float y, float z, float freq, float wall)
{
    float s = freq;
    float d =  (sinf(s*x)*cosf(s*y) +
                sinf(s*y)*cosf(s*z) +
                sinf(s*z)*cosf(s*x));
    return fabsf(d) - wall;
}

static inline float sdf_lidinoid(float x, float y, float z, float freq)
{
    float s  = 2.0f * freq;
    float s2 = s * 0.5f;
    float a  = sinf(s*x)*cosf(s*y)
             + sinf(s*y)*cosf(s*z)
             + sinf(s*z)*cosf(s*x);
    float b  = cosf(s2*x)*sinf(s2*y)*cosf(s2*z)
             + cosf(s2*y)*sinf(s2*z)*cosf(s2*x)
             + cosf(s2*z)*sinf(s2*x)*cosf(s2*y);
    return a - b;
}

static inline float sdf_split_void_gyroid(float x, float y, float z,
                                           float freq, float wall, float split)
{
    float d = sdf_gyroid(x, y, z, freq, wall);
    return fmaxf(d, fabsf(x) - split);
}

/* ------------------------------------------------------------------ */
/*  Material property helpers (pre-computed coefficients)              */
/*  k(T) = a + b*T + c*T²  [W/m·K],  T in K                          */
/*  cp(T) = d + e*T         [J/g·K]                                   */
/* ------------------------------------------------------------------ */

static inline float cond_zrb2(float T_K)
{
    float t = T_K * 0.001f;
    return 120.0f - 35.0f*t - 8.0f*t*t;
}

static inline float cond_tac(float T_K)
{
    float t = T_K * 0.001f;
    return 30.0f - 10.0f*t - 2.0f*t*t;
}

static inline float cp_zrb2(float T_K)
{
    return 0.42f + 0.00013f * T_K;
}

static inline float cp_tac(float T_K)
{
    return 0.35f + 0.00010f * T_K;
}

/* ------------------------------------------------------------------ */
/*  Laser heat-source model (Goldak double-ellipsoid simplified)       */
/*  Q(x,y,z) = (2*eta*A)/(pi*sqrt(pi)*c_x*c_y*c_z)                   */
/*             * exp(-2*((x/vx)²/c_x² + y²/c_y² + z²/c_z²))         */
/* ------------------------------------------------------------------ */

static inline float laser_power_density(float dx, float dy, float dz,
                                         float eta, float P, float vx,
                                         float ax, float ay, float az)
{
    float denom = (ax*ax + ay*ay + az*az) * 1.5707964f; /* pi/2 approx */
    float norm  = 2.0f * eta * P / denom;
    float ex    = -2.0f * (dx*dx) / (ax*ax);
    float ey    = -2.0f * (dy*dy) / (ay*ay);
    float ez    = -2.0f * (dz*dz) / (az*az);
    return norm * expf(ex + ey + ez);
}

/* ------------------------------------------------------------------ */
/*  Oxygen diffusion time through a tortuous channel                   */
/*  t_diff = L_tortuous² / D_O2_in_uhc                               */
/*  D_O2 @ 2000°C in ZrB2 ≈ 1e-15 m²/s (experimental order of mag)   */
/* ------------------------------------------------------------------ */

static inline float oxygen_diffusion_time(float wall_thickness_mm,
                                          float tortuosity)
{
    const float D_O2 = 1.0e-15f * 1.0e6f; /* mm²/s at 2000°C */
    float L = wall_thickness_mm * tortuosity;
    return (L*L) / D_O2;
}

/* ================================================================== */
/*  Top-level HLS kernel                                              */
/* ================================================================== */

#define BUFFER_SIZE 256

extern "C" {

/**
 * @brief UHTC SDF field evaluation + material/barrier/laser metrics
 *
 * Inputs (host-allocated, AXI burst):
 *   points     : float[N][3]  – lattice sample points (x,y,z) [mm]
 *   n_points   : int           – number of points
 *   params     : UHTCParams    – geometry + material + laser constants
 *
 * Outputs (host-allocated):
 *   sdf_out    : float[N]      – signed distance to aperiodic surface [mm]
 *   barrier    : float[N]      – 1.0 if wall thickness >= t_critical, else 0.0
 *   k_cond     : float[N]      – thermal conductivity at T_melt [W/m·K]
 *   laser_q    : float[N]      – laser power density at point [W/mm³]
 *   o2_time    : float[N]      – O2 diffusion time through wall [s]
 *
 * All arrays are packed: points[i*3], points[i*3+1], points[i*3+2].
 */
void krnl_uhc_sdf(
    const float*        points,
    float*              sdf_out,
    float*              barrier,
    float*              k_cond,
    float*              laser_q,
    float*              o2_time,
    const int           n_points,
    const UHTCParams*   params)
{
#pragma HLS INTERFACE m_axi     port=points      offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi     port=sdf_out     offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi     port=barrier     offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi     port=k_cond      offset=slave bundle=gmem2
#pragma HLS INTERFACE m_axi     port=laser_q     offset=slave bundle=gmem2
#pragma HLS INTERFACE m_axi     port=o2_time     offset=slave bundle=gmem3
#pragma HLS INTERFACE s_axilite port=n_points
#pragma HLS INTERFACE s_axilite port=params
#pragma HLS INTERFACE s_axilite port=return

    float local_pts[BUFFER_SIZE * 3];
#pragma HLS ARRAY_PARTITION variable=local_pts dim=1 complete

    for (int i = 0; i < n_points; i += BUFFER_SIZE) {
#pragma HLS LOOP_TRIPCOUNT min=256 max=65536
        int size = BUFFER_SIZE;
        if (i + size > n_points) size = n_points - i;

        /* Burst-read 3 floats per point */
    read_pts:
        for (int j = 0; j < size * 3; j++) {
#pragma HLS PIPELINE II=1
            local_pts[j] = points[i*3 + j];
        }

        /* Compute SDF + derived quantities per point */
    compute:
        for (int j = 0; j < size; j++) {
#pragma HLS PIPELINE II=4
            float px = local_pts[j*3    ];
            float py = local_pts[j*3 + 1];
            float pz = local_pts[j*3 + 2];

            /* --- aperiodic SDF --- */
            float d = 0.0f;
            if (params->geometry_type == 0) {
                d = sdf_gyroid(px, py, pz, params->freq, params->wall_thickness);
            } else if (params->geometry_type == 1) {
                d = sdf_lidinoid(px, py, pz, params->freq);
            } else {
                d = sdf_split_void_gyroid(px, py, pz, params->freq,
                                          params->wall_thickness, params->split);
            }

            sdf_out[i + j] = d;

            /* --- oxygen barrier metric --- */
            float wall_mm = params->wall_thickness * 0.1f; /* unit-cell → mm */
            float t_diff  = oxygen_diffusion_time(wall_mm, params->tortuosity);
            float t_layer = params->layer_time_s;

            barrier[i + j] = (wall_mm >= params->t_critical_mm && t_diff > t_layer)
                              ? 1.0f : 0.0f;
            o2_time[i + j] = t_diff;

            /* --- thermal conductivity at T_melt --- */
            float T_K = params->T_melt_K;
            if (params->material_id == 0) {
                k_cond[i + j] = cond_zrb2(T_K);
            } else {
                k_cond[i + j] = cond_tac(T_K);
            }

            /* --- laser power density at point --- */
            float dx = px - params->laser_x;
            float dy = py - params->laser_y;
            float dz = pz - params->laser_z;
            laser_q[i + j] = laser_power_density(
                dx, dy, dz,
                params->laser_eta,
                params->laser_power_W,
                params->scan_speed_mm_s,
                params->ellipse_x,
                params->ellipse_y,
                params->ellipse_z);
        }
    }
}

} /* extern "C" */
