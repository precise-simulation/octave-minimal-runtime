# Minimal GNU Octave runtime for FEATool

This repository builds the application-private GNU Octave runtime used by the
FEATool source deployment path on Windows. The runtime is derived from the
official GNU Octave 11.3.0 Windows x64 distribution and removes compiler,
development, documentation, bundled package, and GUI files that are not needed
by the qualified FEATool runtime.

The canonical GitHub-hosted build produces two profiles:

- `headless-cli-featool`: 1,589 files and 100,698,366 payload bytes
  (about 96.0 MiB), launched with
  `mingw64\bin\octave-cli.exe --no-window-system`;
- `featool-qt-graphics`: 1,636 files and 181,986,202 payload bytes
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

Hosted run `45770870709` passed this complete path twice on independent
`windows-2025` runner initializations at commit `6cad911`. Both attempts
produced the same manifest SHA-256 values:
`874FC57B890A537300CBB05B323B73E4B71A73C39620170B2FB40424E33ABEDB`
for headless and
`8018D391679965EA07EBB8569A379652685DCCAD1B5E3608D62D312FB4719570`
for Qt. The builder removes Octave's generated bundled-package registry because
its only cross-run difference is a wall-clock timestamp and all referenced
bundled packages are already pruned from the runtime.

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
