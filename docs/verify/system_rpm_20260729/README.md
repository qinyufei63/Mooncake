# Mooncake PR13 system UbDiag RPM full verification

This directory is backup-only validation material. It is not part of the
formal PR diff.

## Fixed inputs

- Mooncake formal commit:
  `1f9a0f28ab11fae396b0d466d61fb740ee66e593`
- Layer 0 header source:
  `8df2c2844d402e2e4dcd5ceab2424e8d36c5f99f`
- System UbDiag RPM source:
  `0d00321945740391da92e81f0f56c3c5187b2402`
- UbDiag RPM features: shared SDK, CLI, P99, and PerfLog.

## Coverage

1. Build one UbDiag RPM set and install the same base/devel version on both
   nodes.
2. Verify CLI and real shared library RPM ownership, exact EVR/architecture,
   build identity, loader resolution, and absence of build RPATH.
3. Configure and build Layer 0 and Layer 1 from clean build directories.
4. Verify Layer 0 uses `UBDIAG_DISABLE`, has no `libubdiag` dependency or
   runtime product, and creates no shared memory during the UB benchmark.
5. Verify Layer 1 links `/usr/lib64/libubdiag.so.0` and survives
   `OFF -> ON -> OFF` reconfiguration.
6. Run master/client/write/read over the real UB device for both layers.
7. Verify summary, detail, sort, P99/P999/P9999, PerfLog, raw table, watch,
   history, and all six CSV output families.
8. Build both Mooncake RPM modes, inspect payload and loader paths, compare the
   embedded UbDiag payload with the selected system RPM installation, and
   perform a normal installation in a disposable container.

Every terminal PASS marker is printed only after its corresponding assertions
have succeeded. Script failure exits only the script process and leaves the SSH
session active.
