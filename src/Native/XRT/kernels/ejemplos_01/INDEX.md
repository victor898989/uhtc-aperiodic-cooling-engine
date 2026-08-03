# ejemplos_01 — Vector Addition (VADD) XRT Example

Iterative versions of the AMD/XRT vector-addition kernel project for Alveo / ZCU104.

```
ejemplos_01/
├── README.rst              ← Base documentation (version 0 / original)
├── description.json        ← Base metadata (version 0)
├── details.rst             ← Base details  (version 0)
├── qor.json                ← Base QoR     (version 0)
├── makefile_us_alveo.mk    ← Base Makefile (version 0)
├── utils.mk                ← Base utils    (version 0)
├── host.cpp                ← Base host app (version 0)
├── krnl_vadd.cpp           ← Base kernel   (version 0)
├── vadd.cpp                ← Base kernel (alternate)
├── vector_addition.cpp     ← Base kernel (alternate)
├── copy_kernel.cpp         ← Utility kernel
│
├── v1/                     ← Iteration (1)
│   ├── host (1).cpp
│   ├── krnl_vadd (1).cpp
│   ├── description (1).json
│   ├── details (1).rst
│   ├── qor (1).json
│   ├── README (1).rst
│   ├── makefile_us_alveo (1).mk
│   └── utils (1).mk
│
├── v2/                     ← Iteration (2)
│   ├── host (2).cpp
│   ├── description (2).json
│   ├── details (2).rst
│   ├── qor (2).json
│   ├── README (2).rst
│   ├── makefile_us_alveo (2).mk
│   └── utils (2).mk
│
├── v3/                     ← Iteration (3)
│   ├── host (3).cpp
│   └── README (3).rst
│
└── v4/                     ← Iteration (4)
    └── host (4).cpp
```

Each numbered sub-folder groups all files that share the same `(n)` suffix,
representing one coherent iteration of the VADD design for a given Alveo card.

Build:
  cd vN && make -f makefile_us_alveo.mk
