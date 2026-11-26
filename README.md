# Minimal GNU Octave runtime for FEATool

This repository builds the application-private GNU Octave runtime used by the
FEATool source deployment path on Windows. The runtime is derived from the
official GNU Octave 11.3.0 Windows x64 distribution and removes compiler,
development, documentation, bundled package, and GUI files that are not needed
by the qualified FEATool runtime.

The canonical GitHub-hosted build produces two profiles:

- `headless-cli-featool`: 1,590 files and 100,792,709 payload bytes
  (about 96.1 MiB), launched with
  `mingw64\bin\octave-cli.exe --no-window-system`;
- `featool-qt-graphics`: 1,637 files and 182,080,545 payload bytes
  (about 173.6 MiB), adding the Qt runtime and plugins needed for native
  Octave figures and waitbars.

The detailed qualification history, packaging contract, and remaining FEATool
integration work are recorded in
[`plans/in-progress/stripped-octave-runtime-featool.md`](plans/in-progress/stripped-octave-runtime-featool.md).

## GitHub Actions

`.github/workflows/build-windows-runtime.yml` is the canonical build and runs
on `windows-2025`. It:

1. downloads the official `octave-11.3.0-w64.7z` distribution;
2. verifies SHA-256
   `fd3cf0e885467a15211b8ceded42800432a5462481324d49a896ef257e05d1a0`;
3. runs the distribution `post-install.bat` with an isolated Windows system
   `PATH`;
4. builds and verifies the headless runtime;
5. runs the headless numerical probe with only the generated runtime and Windows
   system directories on `PATH`;
6. builds the Qt graphics payload and verifies its manifest/components;
7. repeats both builds and compares their manifest hashes;
8. tests each `.7z` archive, extracts it, and verifies the complete payload
   against the embedded manifest;
9. publishes `.7z` archives and SHA-256 files as workflow artifacts.

Hosted run `45767968400` passed this complete path at commit `cc69f3f`.
Its reproducible manifest SHA-256 values were
`A68384AB108203DEE93268A87E0C99016195A1B95B86153546C19F07161B6785`
for headless and
`DAC1479E6531FD5179E1B991EB16858450A415CF3502B7FF421714489C405AAD`
for Qt.

## Authenticated FEATool qualification

Manual workflow dispatches can enable `qualify_featool`. The optional
`qualify` job consumes an immutable FEATool qualification bundle configured
through:

- repository variable `FEATOOL_QUALIFICATION_URL`: an immutable ZIP URL;
- repository variable `FEATOOL_QUALIFICATION_SHA256`: the exact ZIP digest;
- optional secret `FEATOOL_QUALIFICATION_TOKEN`: sent as a Bearer token.

The ZIP root must contain `featool/`, `test/`, and `test_runner.m`. The
production-composed PyRuntime must be installed at
`featool/bin/pyrt/win-x64`, including `manifest.json` and `bridge.mex`.

The hosted qualification job verifies the bundle digest and runs FEATool smoke,
solver, assembly, MEX, embedded Python, and Tk probes with
`-ValidatePackagedPyRuntime -StrictIsolation`. Strict isolation limits `PATH`
to the generated Octave runtime plus Windows system directories and clears
ambient Python, Tcl/Tk, PyRuntime source, and bridge backend overrides before
the probes.

The repository currently has no qualification URL, digest, or token configured,
so this gate is defined but cannot run until the immutable release source bundle
is published.

## Builder interface

`util/build_octave_runtime.ps1` helps implement the hosted workflow.
A production qualification invocation is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\util\build_octave_runtime.ps1 `
  -OctaveRoot 'C:\path\to\Octave-11.3.0' `
  -Destination "$env:TEMP\featool-octave-runtime" `
  -FeatoolRoot 'C:\path\to\qualification-bundle' `
  -Validate -ValidatePackagedPyRuntime -StrictIsolation
```

`-ValidatePackagedPyRuntime` requires FEATool's composed runtime under
`featool/bin/pyrt/win-x64` and verifies that FEATool selects that exact package.
`-PyRuntimeSource` remains available for source-development diagnostics and is
mutually exclusive with packaged-runtime validation.

The generated tree can be checked independently with
`util/verify_octave_runtime.ps1`. Pass `-ArchivePath` to test and extract a
`.7z` archive, then verify that its complete file set, sizes, and SHA-256
hashes match the manifest.

Visible Qt graphics qualification requires an interactive Windows runner. The
standard GitHub-hosted build verifies the Qt payload and components without
opening visible windows.

## Release inputs still external to this repository

The standalone Octave artifact is fully built and verified on GitHub runners.
Final FEATool release qualification additionally requires the immutable
FEATool/PyRuntime bundle, external geometry/mesh/solver helpers, final launcher
and relocatable application assembly, and the release's approved corresponding
source/compliance material. Those are release inputs rather than prerequisites
for producing the standalone Octave runtime artifacts.
