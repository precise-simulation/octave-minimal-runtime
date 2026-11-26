# Minimal GNU Octave runtime for FEATool

This repository builds the application-private GNU Octave runtime used by the
FEATool source deployment path on Windows. The runtime is derived from the
official GNU Octave 11.3.0 Windows x64 distribution and removes compiler,
development, documentation, bundled package, and GUI files that are not needed
by the qualified FEATool runtime.

The current builder produces two profiles:

- `headless-cli-featool`: about 125 MiB in the qualified local build, launched
  with `mingw64\bin\octave-cli.exe --no-window-system`;
- `featool-qt-graphics`: about 203 MiB in the qualified local build, adding the
  Qt runtime and plugins needed for native Octave figures and waitbars.

The detailed qualification history, packaging contract, and remaining FEATool
integration work are recorded in
[`plans/in-progress/stripped-octave-runtime-featool.md`](plans/in-progress/stripped-octave-runtime-featool.md).

## Local build

A runtime-only build needs a clean GNU Octave 11.3.0 Windows installation or
extracted distribution:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\util\build_octave_runtime.ps1 `
  -OctaveRoot 'C:\Program Files\GNU Octave\Octave-11.3.0' `
  -Destination "$env:TEMP\featool-octave-runtime"
```

Add `-GraphicsSupport` for the Qt graphics profile.

Full FEATool qualification is intentionally explicit because the FEATool source
tree is not owned by this repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\util\build_octave_runtime.ps1 `
  -OctaveRoot 'C:\Program Files\GNU Octave\Octave-11.3.0' `
  -Destination "$env:TEMP\featool-octave-runtime" `
  -FeatoolRoot 'C:\path\to\featool-repo' `
  -PyRuntimeSource 'C:\path\to\pyruntime' `
  -Validate
```

`-Validate` runs the FEATool smoke, solver, assembly, MEX, and optional
Python/Tk probes with the generated runtime isolated from the full Octave
installation. The builder removes PATH entries under the supplied Octave
source tree, rejects destinations that overlap source/repository paths, and
only replaces an existing destination that contains a compatible runtime
manifest.

The generated tree can be checked independently with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\util\verify_octave_runtime.ps1 `
  -RuntimeRoot "$env:TEMP\featool-octave-runtime" `
  -ExpectedProfile 'headless-cli-featool'
```

Pass `-ArchivePath` to test and extract a `.7z` archive, then verify that its
complete file set, sizes, and SHA-256 hashes match the manifest.

## GitHub Actions

`.github/workflows/build-windows-runtime.yml` runs on `windows-2025`. It:

1. downloads the official `octave-11.3.0-w64.7z` distribution;
2. verifies SHA-256
   `fd3cf0e885467a15211b8ceded42800432a5462481324d49a896ef257e05d1a0`;
3. runs the distribution `post-install.bat`;
4. builds and verifies the headless runtime;
5. builds the Qt graphics payload and verifies its manifest/components;
6. repeats both builds and compares their manifest hashes to check
   reproducibility;
7. tests each `.7z` archive, extracts it, and verifies the complete payload
   against the embedded manifest;
8. publishes `.7z` archives and SHA-256 files as workflow artifacts.

The hosted workflow does not yet run the FEATool/PyRuntime qualification
because those source inputs are external to this repository. The builder is
ready for that gate once an authenticated CI source or artifact path is defined.
Visible Qt graphics qualification also remains a local or interactive-runner
acceptance check; the hosted workflow verifies the Qt payload without opening
windows.
