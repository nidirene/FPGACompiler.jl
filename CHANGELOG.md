# Changelog

All notable changes to FPGACompiler.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2025-03-14

### Added

#### Hardware-Software CoDesign Module
- **CoDesign module** (`FPGACompiler.CoDesign`) for rapid DSE and co-design exploration
- **Hybrid simulation approach**: parametric (fast) and full-pipeline (cycle-accurate) backends

#### DSE Parameters & Workload Descriptors
- `DSEParameters` for configuring unroll factor, initiation interval, BRAM ports, etc.
- `WorkloadDescriptor` for characterizing kernel computation patterns
- Convenience workload constructors: `conv2d_workload()`, `matmul_workload()`, `fir_filter_workload()`, `elementwise_workload()`, `reduction_workload()`

#### Parametric Simulator
- `ParametricSimulator` for quick performance estimation without LLVM compilation
- `tick!(sim)`, `run!(sim)`, `reset!(sim)` - simulation control
- `calculate_throughput()` - throughput estimation based on DSE parameters
- `estimate_performance()` - quick performance estimates without full simulation

#### DSE Sweep Functions
- `sweep_unroll_factor()` - sweep unroll factor and collect metrics
- `sweep_dse_space()` - multi-dimensional parameter sweep
- `find_optimal_config()` - automatic optimization for throughput/latency/efficiency

#### Virtual FPGA Device Abstractions
- `VirtualFPGADevice` with preset configurations: `alveo_u200()`, `alveo_u280()`, `zynq_7020()`, `arty_a7()`
- `VirtualFPGAArray{T,N}` - array type with FPGA memory semantics and access tracking
- `VirtualPCIe` - PCIe transfer simulation for DMA timing estimation
- Memory allocation, transfer simulation, and resource utilization tracking

#### Observable Wrappers for Makie Integration
- `SimulatorObservables` - reactive state management for live visualization
- `DSEObservables` - observable DSE parameters for interactive control
- `ParetoObservables` - Pareto frontier tracking for design space visualization
- Throttled updates to prevent UI performance issues

#### CoDesign Kernel Interface
- `CoDesignKernel` - unified wrapper for both simulation backends
- `simulate!(kernel; backend=:auto)` - run simulation with automatic backend selection
- `estimate!(kernel)` - quick performance estimates
- `run_dse_sweep(kernel)` - DSE exploration from kernel
- `find_best_config(kernel)` - optimal configuration discovery

#### Full Pipeline Integration
- `compile_kernel(f, argtypes)` - compile through FPGACompiler pipeline
- `CompiledKernel` - holds CDFG, schedule, and native simulator
- `simulate_with_observables()` - cycle-accurate simulation with UI updates

#### Convenience Functions
- `quick_sim()` - one-liner performance estimation
- `compare_configs()` - compare multiple DSE configurations
- `create_kernel()` - factory function for flexible kernel creation
- `print_summary()` - formatted kernel summary
- `codesign_help()` - REPL help for CoDesign module

#### Example Notebooks
- `notebooks/dse_exploration.jl` - Pluto notebook demonstrating DSE workflow

### Dependencies
- Added Observables.jl v0.5 for reactive UI integration

## [0.3.0] - 2024-03-14

### Added

#### Native Julia RTL Simulator
- **SimValue type** with full X (undefined) value support for hardware simulation
- **Two-phase clock semantics** - combinational evaluation followed by sequential latching
- **Wire and Register primitives** for modeling combinational and sequential logic
- **ALU simulation** supporting 30+ operations (arithmetic, logic, comparison, shifts, extensions)
- **Memory (BRAM) simulation** with configurable depth, width, and latency
- **FSM controller simulation** with state transitions and cycle tracking
- **VCD waveform output** compatible with GTKWave and other waveform viewers
- **Test suite framework** for batch verification with `TestVector` and `TestSuite`
- **Debug utilities**: `dump_state()`, `dump_fsm()`, `examine()`, `watch()`

#### Simulation API
- `build_simulator(cdfg, schedule)` - Create simulator from CDFG
- `reset!(sim)`, `tick!(sim)`, `run!(sim)` - Simulation control
- `set_input!(sim, port, value)`, `get_output(sim, port)` - I/O interface
- `enable_trace!(sim)`, `write_vcd(sim, file)` - Waveform tracing
- `simulate(cdfg, schedule, inputs; backend=:native)` - Unified interface

#### Documentation & Examples
- `docs/simulation.md` - Comprehensive simulation guide
- `examples/native_simulation.jl` - Native simulator usage examples
- `examples/verilator_integration.jl` - Verilator + CxxWrap.jl workflow

### Changed
- `Sim.jl` now exports all native simulator types and functions
- Unified `simulate()` function supports both `:native` and `:verilator` backends

### Fixed
- Signed integer handling in SimValue using `reinterpret()` for safe conversion
- Arithmetic shift right (ASHR) with signed operands
- Signed division and remainder operations (SDIV, SREM)

## [0.2.0] - 2024-03-14

### Added

#### RTL Generation Backend
- **Datapath generation** with ALU, multiplexer, and register instantiation
- **FSM generation** with one-hot and binary encoding support
- **Verilog emitter** producing synthesizable RTL
- **Memory interface generation** for BRAM integration
- **Top module generator** integrating datapath, FSM, and memories

#### RTL Types
- `RTLModule` - Container for generated RTL
- `DatapathComponent` - ALUs, MUXes, registers
- `FSMState`, `FSMTransition` - State machine representation
- `MemoryInterface` - BRAM port definitions

### Changed
- Extended HLS module to support RTL generation flow

## [0.1.0] - 2024-03-14

### Added

#### HLS Backend
- **CDFG construction** - Combined Control and Data Flow Graph from Julia functions
- **Scheduling algorithms**:
  - ASAP (As Soon As Possible)
  - ALAP (As Late As Possible)
  - List scheduling with resource constraints
  - ILP-based optimal scheduling via JuMP.jl
- **Resource binding** - Maps operations to functional units with sharing
- **FSM generation** - Synthesizes control state machines

#### Core Compiler
- `FPGATarget` extending GPUCompiler.AbstractCompilerTarget
- `FPGACompilerParams` for compilation configuration
- Three-phase LLVM optimization pipeline:
  - Phase 1: Canonicalization (mem2reg, inline, loop-simplify)
  - Phase 2: Dependency analysis (alias analysis, scalar evolution)
  - Phase 3: Hardware metadata injection

#### Types
- `PartitionedArray{T,N,Factor,Style}` for BRAM partitioning
- `FixedInt{N,T}` for arbitrary bit-width integers
- Convenience types: `Int3`, `Int5`, `Int7`, `Int12`, `Int14`, `Int24`

#### User API
- `fpga_compile(f, types)` - Compile function to LLVM.Module
- `fpga_code_llvm(f, types)` - Return LLVM IR as string
- `fpga_code_native(f, types; format, output)` - Write IR to file
- `@fpga_kernel`, `@pipeline`, `@unroll` macros

#### Metadata Functions
- `apply_pipeline_metadata!(block, ii)` - Add pipelining hints
- `apply_unroll_metadata!(block, factor)` - Add unrolling hints
- `apply_partition_metadata!(inst, factor, style)` - Memory partitioning
- `apply_noalias_metadata!(mod)` - Mark arrays as non-overlapping

#### Verilator Integration
- `check_verilator()` - Check Verilator installation
- `compile_verilator(verilog, output_dir)` - Compile Verilog to C++
- `run_verilator(executable)` - Run compiled simulation
- `SimulationResult` type for simulation outputs

#### Documentation
- `README.md` with comprehensive usage guide
- `CLAUDE.md` for AI assistant guidance
- `docs/api.md` - API reference
- `docs/architecture.md` - Internal design documentation
- `docs/tutorial.md` - Step-by-step tutorial
- `docs/vendor-integration.md` - Vendor tool workflows

#### Examples
- `examples/vector_add.jl` - Basic kernel compilation
- `examples/matrix_mul.jl` - Pipelined matrix multiplication
- `examples/memory_partition.jl` - PartitionedArray usage
- `examples/custom_bitwidth.jl` - FixedInt for resource efficiency

### Dependencies
- GPUCompiler.jl v1.x
- LLVM.jl v9.x
- Graphs.jl
- JuMP.jl
- HiGHS.jl

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 0.4.0 | 2025-03-14 | Hardware-Software CoDesign Module |
| 0.3.0 | 2024-03-14 | Native Julia RTL Simulator |
| 0.2.0 | 2024-03-14 | RTL Generation Backend |
| 0.1.0 | 2024-03-14 | Initial HLS Backend |

[Unreleased]: https://github.com/yourusername/FPGACompiler.jl/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/yourusername/FPGACompiler.jl/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/yourusername/FPGACompiler.jl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/yourusername/FPGACompiler.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/yourusername/FPGACompiler.jl/releases/tag/v0.1.0
