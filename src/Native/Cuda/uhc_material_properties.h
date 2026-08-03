// SPDX-License-Identifier: Apache-2.0
//
// uhc_material_properties.h
//
// Temperature-dependent material properties for UHTC ceramics used in
// laser powder-bed fusion (L-PBF) with aperiodic lattice oxygen barriers.
//
// Materials:
//   ZrB2  — Zirconium diboride      (TRL 5, most mature)
//   TaC   — Tantalum carbide        (TRL 3)
//   HfC   — Hafnium carbide         (TRL 3, highest T_melt known)
//
// Property sources:
//   - Upadhya et al., J. Am. Ceram. Soc. 80(11), 1997  (ZrB2 thermal cond)
//   - Fahrenholtz et al., J. Am. Ceram. Soc. 90(1), 2007 (ZrB2 oxidation)
//   - Pierson, Handbook of Refractory Carbides and Nitrides, 1996
//   - Opeka et al., J. Eur. Ceram. Soc. 24, 2004 (HfC, TaC thermal)
//
// All polynomials return SI units unless noted.  Temperature input is [K].
// Valid range: 300 K ≤ T ≤ 3500 K (covers full L-PBF build envelope).
//
// Aperiodic oxygen-barrier model:
//   The tortuosity τ of the aperiodic channel network is characterised by
//   the ratio of effective diffusion path length to the straight-line wall
//   thickness.  A wall thickness below t_critical = 80 µm (for ZrB2) at
//   τ ≥ 3 allows O2 to reach the hot interior during a layer time ≤ 2 s.
//   The uhc_oxygen_barrier CUDA kernel evaluates this metric per-voxel.

#ifndef UHC_MATERIAL_PROPERTIES_H
#define UHC_MATERIAL_PROPERTIES_H

#include <cuda_runtime.h>
#include <cmath>

namespace uhc {

/* ================================================================== */
/*  Enumerations                                                       */
/* ================================================================== */

enum MaterialID : int {
    MAT_ZRB2 = 0,
    MAT_TAC  = 1,
    MAT_HFC  = 2,
    MAT_POWDER_ZRB2 = 3,   /* loose powder — lower conductivity */
    MAT_POWDER_TAC  = 4,
    MAT_POWDER_HFC  = 5
};

enum GeometryType : int {
    GEO_GYROID           = 0,
    GEO_LIDINOID         = 1,
    GEO_SPLIT_VOID_GYROID= 2
};

/* ================================================================== */
/*  Melting points [K]                                                 */
/* ================================================================== */

__host__ __device__ inline float T_melt(MaterialID m)
{
    switch (m) {
        case MAT_ZRB2:         return 3519.0f;
        case MAT_TAC:          return 4215.0f;
        case MAT_HFC:          return 4231.0f;
        case MAT_POWDER_ZRB2:  return 3519.0f;
        case MAT_POWDER_TAC:   return 4215.0f;
        case MAT_POWDER_HFC:   return 4231.0f;
        default:               return 3000.0f;
    }
}

/* ================================================================== */
/*  Density [g/cm³] at reference temperature (RT, corrected for T)    */
/*  ρ(T) = ρ_0 / (1 + β*(T - T_0))  with β ≈ 3.5e-5 K^-1           */
/* ================================================================== */

__host__ __device__ inline float density(MaterialID m, float T)
{
    float rho0 = 0.0f;
    switch (m) {
        case MAT_ZRB2:  case MAT_POWDER_ZRB2:  rho0 = 6.09f; break;
        case MAT_TAC:   case MAT_POWDER_TAC:   rho0 = 14.5f; break;
        case MAT_HFC:   case MAT_POWDER_HFC:   rho0 = 12.0f; break;
        default:                          rho0 = 6.0f;  break;
    }
    /* Powder bed: ~55 % of theoretical density after spreading */
    if (m >= MAT_POWDER_ZRB2) rho0 *= 0.55f;

    const float beta = 3.5e-5f;
    const float T0   = 298.0f;
    return rho0 / (1.0f + beta * (T - T0));
}

/* ================================================================== */
/*  Specific heat capacity [J/(g·K)]                                  */
/*  cp(T) = a + b*T  (linear fit, 300 K – 3500 K)                   */
/* ================================================================== */

__host__ __device__ inline float specific_heat(MaterialID m, float T)
{
    float a, b;
    switch (m) {
        case MAT_ZRB2:  case MAT_POWDER_ZRB2:  a = 0.38f; b = 1.2e-4f; break;
        case MAT_TAC:   case MAT_POWDER_TAC:   a = 0.32f; b = 1.0e-4f; break;
        case MAT_HFC:   case MAT_POWDER_HFC:   a = 0.33f; b = 1.1e-4f; break;
        default:                           a = 0.35f; b = 1.0e-4f; break;
    }
    float cp = a + b * T;
    return fmaxf(cp, 0.25f);   /* avoid unphysical negatives at very high T */
}

/* ================================================================== */
/*  Thermal conductivity [W/(m·K)]                                    */
/*  k(T) = max(k_min, a + b*T + c*T²)  — quadratic fit               */
/*  Powder form: multiply by ~0.15 (contact resistance dominates)     */
/* ================================================================== */

__host__ __device__ inline float thermal_conductivity(MaterialID m, float T)
{
    float a, b, c, k_min;
    switch (m) {
        case MAT_ZRB2:
            a = 140.0f; b = -8.0e-2f; c = -1.5e-5f; k_min = 18.0f;
            break;
        case MAT_TAC:
            a = 30.0f;  b = -1.0e-2f; c = -2.0e-6f; k_min = 10.0f;
            break;
        case MAT_HFC:
            a = 28.0f;  b = -9.0e-3f; c = -1.8e-6f; k_min = 8.0f;
            break;
        case MAT_POWDER_ZRB2:
            a = 140.0f; b = -8.0e-2f; c = -1.5e-5f; k_min = 3.0f;
            break;
        case MAT_POWDER_TAC:
            a = 30.0f;  b = -1.0e-2f; c = -2.0e-6f; k_min = 2.0f;
            break;
        case MAT_POWDER_HFC:
            a = 28.0f;  b = -9.0e-3f; c = -1.8e-6f; k_min = 1.5f;
            break;
        default:
            a = 50.0f;  b = -2.0e-2f; c = -5.0e-6f; k_min = 10.0f;
            break;
    }
    float k = a + b * T + c * T * T;
    return fmaxf(k, k_min);
}

/* ================================================================== */
/*  Thermal diffusivity [mm²/s]                                       */
/*  α = k / (ρ·c_p)   with k in W/(m·K), ρ in g/cm³, c_p in J/(g·K)*/
/*  Returns [mm²/s]                                                   */
/* ================================================================== */

__host__ __device__ inline float thermal_diffusivity(MaterialID m, float T)
{
    float k  = thermal_conductivity(m, T);          /* W/(m·K)  */
    float rho_gcm3 = density(m, T);                 /* g/cm³    */
    float cp = specific_heat(m, T);                 /* J/(g·K)  */

    /* Convert k → W/(cm·K) to match ρ units */
    float k_cm = k * 0.1f;
    float alpha_cm2s = k_cm / (rho_gcm3 * cp);     /* cm²/s    */

    return alpha_cm2s * 100.0f;                     /* mm²/s    */
}

/* ================================================================== */
/*  Total hemispherical emissivity (oxide-coated UHTC surface)         */
/*  ε(T) = ε_0 + ε_1*(T - T_ref)  [dimensionless, 0-1]              */
/* ================================================================== */

__host__ __device__ inline float emissivity(MaterialID m, float T)
{
    float e0, e1;
    switch (m) {
        case MAT_ZRB2:  case MAT_POWDER_ZRB2:  e0 = 0.78f; e1 = 1.5e-5f; break;
        case MAT_TAC:   case MAT_POWDER_TAC:   e0 = 0.68f; e1 = 1.2e-5f; break;
        case MAT_HFC:   case MAT_POWDER_HFC:   e0 = 0.72f; e1 = 1.3e-5f; break;
        default:                           e0 = 0.70f; e1 = 1.0e-5f; break;
    }
    float e = e0 + e1 * (T - 298.0f);
    return fmaxf(0.0f, fminf(1.0f, e));
}

/* ================================================================== */
/*  Aperiodic oxygen-barrier metric                                    */
/*  Returns 1.0 if wall thickness blocks O2, 0.0 otherwise            */
/*                                                                     */
/*  Criterion:                                                         */
/*    t_diff = (t_wall * τ)² / D_O2                                   */
/*    safe   ⇔  t_diff > t_layer                                       */
/*                                                                     */
/*  D_O2 in ZrB2 @ 2000 °C ≈ 1.0e-15 m²/s  → 1.0e-9 mm²/s          */
/* ================================================================== */

__host__ __device__ inline float oxygen_barrier(float t_wall_mm,
                                                 float tortuosity,
                                                 float t_layer_s)
{
    const float D_O2_mm2s = 1.0e-9f;  /* mm²/s at 2000 °C */
    float L   = t_wall_mm * tortuosity;
    float t_diff = (L * L) / D_O2_mm2s;
    return (t_diff > t_layer_s) ? 1.0f : 0.0f;
}

/* ================================================================== */
/*  Stefan-Boltzmann radiative heat loss [W/m²]                        */
/*  q_rad = ε·σ·(T^4 - T_amb^4)                                      */
/* ================================================================== */

__host__ __device__ inline float radiative_heat_flux(MaterialID m, float T_K, float T_amb_K)
{
    const float sigma = 5.670374419e-8f;   /* W/(m²·K⁴) */
    float e = emissivity(m, T_K);
    return e * sigma * (T_K*T_K*T_K*T_K - T_amb_K*T_amb_K*T_amb_K*T_amb_K);
}

/* ================================================================== */
/*  struct passed per-voxel to the thermal solver kernel               */
/* ================================================================== */

struct VoxelMaterial {
    MaterialID mat;
    float      density;     /* g/cm³  — set by uhc_deposition kernel  */
    float      activation;  /* 0.0 = powder bed, 1.0 = fully melted  */
};

__host__ __device__ inline float effective_conductivity(const VoxelMaterial& vm, float T)
{
    float k = thermal_conductivity(vm.mat, T);
    /* Partially melted zone: interpolate towards liquid conductivity */
    float k_liq = k * 0.55f;
    return k * vm.activation + k_liq * (1.0f - vm.activation);
}

} /* namespace uhc */

#endif /* UHC_MATERIAL_PROPERTIES_H */
