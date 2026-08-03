/**
 * @file uhc_fpga_types.h
 *
 * Shared parameter structs and constants for UHTC FPGA kernels.
 * Keep this header free of C++ standard library includes so HLS can
 * compile it with a minimal toolchain.
 */

#ifndef UHC_FPGA_TYPES_H
#define UHC_FPGA_TYPES_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/*  Geometry identifiers                                               */
/* ------------------------------------------------------------------ */
#define UHC_GYROID           0
#define UHC_LIDINOID         1
#define UHC_SPLIT_VOID_GYROID 2

/* ------------------------------------------------------------------ */
/*  Material identifiers                                               */
/* ------------------------------------------------------------------ */
#define UHC_MAT_ZRB2         0
#define UHC_MAT_TAC          1
#define UHC_MAT_HFC          2

/* ------------------------------------------------------------------ */
/*  Parameter struct — must be POD (plain-old-data) for HLS            */
/* ------------------------------------------------------------------ */
typedef struct {
    /* ---- lattice geometry ---- */
    int   geometry_type;   /* 0=Gyroid, 1=Lidinoid, 2=SplitVoidGyroid */
    float freq;            /* spatial frequency of the aperiodic unit cell [1/mm] */
    float wall_thickness;  /* SDF offset applied to the surface [unitless, ~0.1-0.5] */
    float split;           /* split-plane position for SplitVoidGyroid [mm] */

    /* ---- oxygen barrier ---- */
    float t_critical_mm;   /* minimum wall thickness to block O2 ingress [mm] */
    float tortuosity;      /* geometric tortuosity factor (> 1) */

    /* ---- thermal / laser ---- */
    float T_melt_K;        /* target melt-pool temperature [K] */
    float T_ambient_K;     /* build-chamber ambient [K] */
    float layer_time_s;    /* time allocated per layer [s] */

    /* ---- material ---- */
    int   material_id;     /* 0=ZrB2, 1=TaC, 2=HfC */

    /* ---- laser source (Goldak double-ellipsoid, simplified) ---- */
    float laser_x, laser_y, laser_z; /* laser focus position [mm] */
    float laser_power_W;             /* nominal laser power [W] */
    float laser_eta;                 /* absorption efficiency (0-1) */
    float scan_speed_mm_s;           /* scan speed [mm/s] */
    float ellipse_x, ellipse_y, ellipse_z; /* Gaussian radii [mm] */
} UHTCParams;

#endif /* UHC_FPGA_TYPES_H */
