# Minimal GNU Octave runtime for FEATool

This repository builds application-private GNU Octave runtimes used by the
FEATool source deployment path. The qualified Windows runtime is derived from
the official GNU Octave 11.3.0 Windows x64 distribution. The Linux runtime is
built from the pinned GNU Octave 11.3.0 source release and is being qualified as
a relocatable x86-64/glibc artifact. Both paths remove compiler, development,
documentation, and GUI content that is not needed by their runtime profile.

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

## Linux headless source build

`.github/workflows/build-linux-runtime.yml` is the first Linux x86-64 hosted
checkpoint. It runs on `ubuntu-24.04` inside a digest-pinned Ubuntu 22.04
container and builds GNU Octave 11.3.0 from the pinned source archive with
SHA-256
`2b80f3149b2de6d1f4f2fcb4fe6515a17eb363b52111bf57b90f37bf6f5e12e1`.
The Ubuntu package repositories remain mutable; each run records the exact
resolved `dpkg` package versions in the manifest and uploaded build evidence.
The current checkpoint is intentionally headless: Qt/native Octave graphics and
the production FEATool/PyRuntime integration remain later qualification steps.

`util/build_octave_runtime_linux.sh` configures a shared-library Octave build
with BLAS/LAPACK, SuiteSparse, ARPACK, FFTW, HDF5, Qhull, libcurl, and MEX
support from the declared hosted build dependencies while disabling Java,
documentation, Qt, FLTK, OpenGL, and ImageMagick integration. It installs into
the configured private prefix inside the disposable build container, copies out
the runtime tree, removes development-only payload, and creates a
relative launcher that
sets the packaged Octave home, supplies a deterministic child `PATH`, and
disables Octave startup files without requiring a system Octave installation.

`util/linux_runtime_tool.py` derives the packaged ELF closure from `DT_NEEDED`
entries. Non-glibc dependencies are copied into `lib/runtime-deps`; Octave-owned
libraries are exposed there through relative symlinks. Every packaged ELF object
receives an `$ORIGIN`-relative search path. Verification rejects unresolved
dependencies, non-relative RPATH/RUNPATH entries, external symlink targets,
non-x86-64 ELF objects, source/build paths in loader-visible ELF metadata, and
source/build paths in every other delivered file. The only raw-byte exception is
an enumerated set of 30 GNU Fortran diagnostic source filenames embedded in GNU
Octave 11.3's `liboctave.so.13.0.2`; any other source-prefix occurrence and every
build-prefix occurrence still fail the audit.

The Linux manifest records file types, modes, regular-file sizes/SHA-256 values,
symlink targets, build/compiler provenance, exact resolved `dpkg` package
versions, the host-library allowlist, and the maximum required `GLIBC`,
`GLIBCXX`, `CXXABI`, and `GCC` symbol versions. The
first hosted lane uses glibc 2.35 as its selected build baseline; that is a
checkpoint baseline rather than the final public compatibility claim. A later
compatibility lane will test the preferred glibc 2.17 floor or narrow the claim
to the oldest fully qualified baseline.

The workflow validates sparse linear algebra, ARPACK, FFTW, HDF5, Qhull
geometry, libcurl URL I/O, JSON support, and an externally compiled MEX probe
under a minimal environment. It then emits a metadata-preserving `tar.zst`,
extracts it to a different absolute path, and reruns manifest, ELF, dependency,
and relocation smoke checks on the extracted tree before uploading the archive
and build evidence.

Hosted run `45781365018` passed this complete Linux path at commit `95bbb4d`.
The qualified headless payload contains 1,182 files and 102,752,311 bytes
(about 98.0 MiB); its `tar.zst` is 25,847,102 bytes with SHA-256
`c57caa5936362e238d820a57e7f89b17727183729900622d746182375c130988`.
The runtime closure contains 61 bundled non-host dependency SONAMEs and the
manifest records 259 installed `dpkg` package/version entries. Maximum required
symbol versions are `GLIBC_2.35`, `GLIBCXX_3.4.30`, `CXXABI_1.3.9`, and
`GCC_4.3.0`.

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
