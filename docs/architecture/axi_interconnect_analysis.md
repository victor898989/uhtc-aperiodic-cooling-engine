# AXI interconnect analysis (TCL script)

Goal: verify that the system AXI interconnect can move NanoVDB blocks without bottlenecks.

## Day 3 — Run AXI analysis

### 3.1 Preparation
- Have an implemented design in Vivado/Vitis.
- Export the `.xsa` or `.bit` design.
- Open Vivado TCL Console or use `vivado -mode batch`.

### 3.2 Analysis script
Run `src/Native/FPGA/axi_dtpi/analyze_axi_interconnect.tcl`.

The script:
- Inspects the AXI interconnect
- Lists masters/slaves
- Detects: FIFOs, RegSlices, protocol converters, clock converters, slicers, data-width converters
- Prints tables with the AXI configuration

### 3.3 Mandatory checks
- [ ] FIFO present between AXI DMA and memory
- [ ] RegSlice in the data path
- [ ] Protocol converter if AXI4-Lite ↔ AXI4-Stream
- [ ] Clock converter if different clock domains
- [ ] Burst length ≥ NanoVDB block size / data width
- [ ] No narrow bursts that degrade bandwidth

### 3.4 Quick diagnosis
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Low bandwidth | Missing RegSlice | Insert RegSlice in path |
| Corrupt data | Missing clock converter | Add clock domain crossing |
| Timeout | FIFO too small | Increase FIFO depth |
| Short bursts | Default config | Adjust `max_burst_len` in AXI DMA |

## Day 4 — Connect CUDA pipeline

### Data mapping
```
NanoVDB GridHandle
    → device pointer
    → AXI DMA (linear buffer)
    → FPGA (processing)
    → result → host
```

### Final checklist
- [ ] TCL script passes without errors
- [ ] AXI DMA can transfer 64KB blocks (typical for NanoVDB)
- [ ] Clock domains are correctly isolated
- [ ] No FIFO overflow at maximum load
