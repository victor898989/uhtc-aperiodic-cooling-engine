# Arquitectura del Motor UHTC

## Flujo de Datos
1. **Definición Cristalográfica (C#)**: Se especifican las funciones de distancia con signo (SDF) aperiódicas y las proporciones de matriz Zr/Ta.
2. **Evaluación Intensiva (C++ / CUDA / FPGA)**: Los puntos del dominio tridimensional se evalúan en paralelo mediante los kernels nativos.
3. **Generación de Vóxeles y Malla (PikoGK)**: Se convierte el campo en una estructura VDB para exportación y visualización.

## Estructura del Repositorio
```
src/
├── CSharp/              # Lógica de dominio, SDFs y orquestación C#
│   ├── Cooling/         # Redes TPMS/Giroides (LEAP71_LatticeLibrary)
│   ├── Macro/           # Kernel de formas (LEAP71_ShapeKernel)
│   ├── Core/            # Cuasicristales 6D y generación de teselaciones
│   ├── Interop/         # Bindings P/Invoke hacia la capa nativa
│   └── Tests/           # Testbenches unitarios
├── Native/              # Aceleración hardware
│   ├── Cuda/            # Kernels CUDA y runtime OpenDVB
│   ├── XRT/             # Kernels HLS y host code para Alveo/Versal
│   └── Common/          # CMake modules y encabezados compartidos
├── Runtime/             # Motores de voxelización (PikoGK)
├── Docs/                # Referencias y diagramas arquitectónicos
└── Slices/              # Exportación bitmap CLI
```

## Componentes Clave
- **C# 12**: Define la topología de enfriamiento y las SDFs.
- **CUDA / C++ 20**: Evalúa campos de distancia en GPU.
- **Xilinx XRT / Vitis AIE**: Aceleración FPGA para síntesis de bitstreams.
- **NanoVDB**: Representación compacta de campos de distancia en GPU.

## Pipeline de CI/CD
- `dotnet build` para validar el ensamblado C#.
- `cmake -B build && cmake --build build` para verificar kernels nativos.
