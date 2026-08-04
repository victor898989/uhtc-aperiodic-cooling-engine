# Guided analysis of OpenVDB IO (Archive.cc)

Goal: understand how OpenVDB prepares voxels for hardware transmission, split into 4 blocks.

## Day 1 — Stream state, metadata and mapped file

### 1.1 `StreamMetadata`
- This is the stream's "control record".
- Stores: file version, compression, grid class, mapped file pointer, delayed-load metadata.
- Hardware analogy: AXI-Lite registers that configure the DMA before a burst.

### 1.2 `StreamState`
- Internal stream state during read/write.
- Allows `seek`, `tell`, and save/restore of position.
- Hardware analogy: circular buffer pointer in DRAM.

### 1.3 `MappedFile` (boost::interprocess)
- Maps the `.vdb` file into virtual memory.
- Allows random access without loading the full volume into RAM.
- Hardware analogy: MMU / scatter-gather for volumetric streaming.

## Day 2 — Volumetric compression and delayed loading

### 2.1 `PopulateDelayedLoadMetadataOp`
- Iterates over each `LeafNode`.
- Per leaf it calculates:
  - Active voxel mask
  - Compressed size
  - Offset within the file
- Generates the "DMA descriptors" for each voxel block.

### 2.2 `writeCompressedValuesSize`
- Calculates the exact size of compressed values.
- Uses `zlib`/`blosc` depending on configuration.
- Important for planning AXI bursts and avoiding FIFO overflow.

## Day 4 — Connection with NanoVDB and FPGA

### Expected flow
1. OpenVDB produces `geometry_voxels.bin` and `thermal_field.bin`
2. NanoVDB converts to a `GridHandle` on GPU
3. AXI DMA moves blocks from DRAM to FPGA
4. XRT kernel processes voxels in PL

### Checkpoints
- [ ] Archive.cc compiles with `NANOVDB_USE_OPENVDB=1`
- [ ] Delayed-load metadata is generated without errors
- [ ] Block size matches AXI data width (64/128 bits)
