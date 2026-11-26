---
kind: plan
title: Stripped GNU Octave runtime for FEATool
summary: Build, validate, and publish a minimal GNU Octave 11.3.0 Windows runtime for FEATool from this repository, including reproducible GitHub-hosted Windows packaging and isolated FEATool qualification.
area: deployment
priority: P2
depends_on: []
children: []
affected_files:
  - plans/in-progress/stripped-octave-runtime-featool.md
  - util/build_octave_runtime.ps1
  - .github/workflows/build-windows-runtime.yml
  - README.md
---

## Goal and scope

Build and validate a substantially reduced GNU Octave runtime for the FEATool
source deployment path on Windows. The target architecture runs FEATool `.m`
code directly in `octave-cli --no-window-system` and uses the host-neutral Python
MEX bridge for the Tk user interface.

This path is separate from the MATLAB-compiled `FEATool_Multiphysics.exe` and
cannot run that executable. It depends on the unobfuscated FEATool `.m` sources
from the development tree. A packaged MATLAB `.p` release is not usable because
GNU Octave cannot execute MATLAB P-code.

The goals are to:

- reduce the official Windows Octave distribution to a FEATool-specific runtime;
- keep the default headless profile free of Qt/Octave GUI, compiler/development
  files, documentation, and bundled packages not required by FEATool;
- make the package deterministic and reproducible;
- prove solver, assembly, MEX, embedded Python, and Tk behavior with ambient
  Octave/Python/Tk installations excluded;
- keep external FEATool helpers as independent application assets rather than
  folding them into the interpreter runtime.

This dedicated repository owns the Octave runtime builder and CI packaging.
FEATool application sources, PyRuntime, and external geometry/mesh/solver
helpers remain external inputs. The workflow must identify those inputs
explicitly rather than depending on developer-machine paths.

## Repository and CI ownership

The canonical builder is `util/build_octave_runtime.ps1` in this repository.
It must support runtime-only packaging from a clean GNU Octave 11.3.0 Windows
distribution without a FEATool checkout, and isolated FEATool qualification
when an explicit FEATool source root is supplied. PyRuntime remains an optional
input for the embedded Python/Tk probes.

The canonical hosted build runs on GitHub Actions `windows-2025`. It downloads
the official `octave-11.3.0-w64.7z`, verifies the pinned SHA-256 digest, runs
the archive's `post-install.bat`, generates the runtime, verifies the manifest,
archives the exact generated tree, and uploads it as a workflow artifact.

The hosted workflow also supports an explicit `qualify_featool` dispatch gate.
That gate consumes a SHA-256-pinned FEATool qualification ZIP from repository
configuration, optionally authenticates with a secret Bearer token, and requires
the production-composed PyRuntime below `featool/bin/pyrt/win-x64`. It runs the
FEATool numerical, MEX, embedded Python, and Tk probes with strict process
isolation.

FEATool and PyRuntime are not assumed to be public GitHub repositories. Hosted
qualification must therefore use explicit authenticated source or artifact
inputs before it becomes a required acceptance gate. Building the standalone
Octave runtime must not depend on those private inputs.

## Baseline measurements

The installed GNU Octave 11.3.0 tree is approximately 2698.8 MiB. Most of that
installation is not required at runtime: it includes MinGW/MSYS2 compiler and
development files, headers, static libraries, Qt, documentation, and bundled
Octave Forge packages.

A live headless FEATool Poisson solve loaded only 55 Octave-owned native modules,
with about 111 MiB of mapped module images. The module trace was used to guide
the investigation, but it is not used as the packaging algorithm because lazy
loading would make a trace-derived package fragile.

## Deterministic runtime builder

`util/build_octave_runtime.ps1` builds a Windows x64 headless runtime from a
clean GNU Octave 11.3.0 installation. The builder contains an explicit 54-file
native `bin` closure and copies the required core Octave function and `.oct`
trees before applying fixed pruning rules.

The builder removes:

- the Qt/Octave GUI by never staging it;
- compilers, headers, MinGW development support, and general MSYS2 tooling;
- Octave Forge `share/octave/packages` and `lib/octave/packages`;
- static `.a` and libtool `.la` development archives;
- Octave documentation, tests, notebooks, and related assets not needed by the
  deployed runtime.

It retains:

- `octave-cli.exe`;
- BLAS/LAPACK;
- SuiteSparse;
- ARPACK;
- FFTW;
- HDF5;
- Octave interpreter libraries;
- `liboctmex` and the MEX loader/API;
- core `.m` and `.oct` runtime files;
- runtime localization/fonts from the stock distribution;
- installed license files.

The builder verifies that the source is exactly GNU Octave 11.3.0, rejects
unsafe source/destination nesting, and writes a per-file SHA-256
`runtime-manifest.json`.

Validation with `-Validate` removes installed GNU Octave paths from `PATH` and
sets `OCTAVE_HOME` and `OCTAVE_EXEC_HOME` to the generated runtime. With
`-StrictIsolation`, validation permits only the generated runtime and Windows
system directories on `PATH` and clears ambient Python, Tcl/Tk, PyRuntime source,
and bridge-backend environment overrides.

A representative local validation command is:

`powershell -ExecutionPolicy Bypass -File util\build_octave_runtime.ps1 -Destination C:\temp\octave_featool_min_generated -FeatoolRoot C:\path\to\featool-repo -Validate`

In this repository, validation also supplies `-FeatoolRoot` explicitly. For the
current development PyRuntime layout, add:

`-PyRuntimeSource C:\Users\jsh\Dropbox\code\featool\pyruntime`

This runs the same isolated Octave qualification plus FEATool `pyengine` probes
both without GUI initialization and with the hidden Tk root enabled. Production
qualification uses `-ValidatePackagedPyRuntime`: it requires the composed runtime
below `featool/bin/pyrt/win-x64`, rejects `-PyRuntimeSource`, and verifies that
FEATool selected that exact packaged runtime before the Python/Tk probes.

## Runtime checkpoint

Two clean builder runs from
`C:\Program Files\GNU Octave\Octave-11.3.0` produced the same result:

- payload: 1,590 files;
- payload bytes: 131,169,579 bytes, approximately 125.1 MiB;
- manifest: approximately 412 KiB;
- total generated tree including manifest: approximately 125.5 MiB;
- manifest SHA-256 on both builds:
  `A16FDEB058BA65AC3B27E8214CCCE04E77AAB221FE514D3D78B5141B4A025F15`.

With the full Octave installation removed from `PATH`, a live FEATool solve used
55 modules from the generated runtime and zero modules from the full Octave
installation.

The measurements above are the historical installed-Octave checkpoint. The
canonical GitHub-hosted build from the pinned official archive is smaller.
Hosted run `45770870709` at commit `6cad911` passed twice on independent
`windows-2025` runner initializations with:

- headless payload: 1,589 files, 100,698,366 bytes (about 96.0 MiB), manifest
  SHA-256
  `874FC57B890A537300CBB05B323B73E4B71A73C39620170B2FB40424E33ABEDB`;
- Qt payload: 1,636 files, 181,986,202 bytes (about 173.6 MiB), manifest
  SHA-256
  `8018D391679965EA07EBB8569A379652685DCCAD1B5E3608D62D312FB4719570`;
- headless numerical probe with a minimal runtime/system `PATH`: pass;
- repeat-build manifest identity for both profiles within each run: pass;
- manifest identity across two fresh hosted runner initializations: pass;
- archive test, extraction, complete file-set/size/SHA-256 verification: pass;
- GitHub artifact publication for both profiles: pass.

The only cross-run difference found before this checkpoint was the first line
of `share/octave/site/api-v61/octave_packages`, where Octave's
`post-install.bat` writes the current UTC timestamp. Because the runtime
already removes all bundled `share/octave/packages` and `lib/octave/packages`
content, the builder now removes this stale package registry as well.

## Optional Qt graphics profile

The canonical hosted default is the 96.0 MiB headless profile. For FEATool workflows
that need native Octave figures, `plot`, or `waitbar`, the builder supports an
optional `-GraphicsSupport` switch.

This profile uses Octave's Qt graphics toolkit rather than FLTK. FLTK was also
investigated and needs only about 1.2 MiB of extra native libraries, but the
stock GNU Octave 11.3.0 Windows installation itself crashes during FLTK teardown
after creating plot/waitbar windows. Qt exits cleanly and is also required for
Octave's waitbar cancel-button implementation.

The Qt graphics profile adds only the runtime DLLs observed for
`octave.exe --no-gui` with `graphics_toolkit('qt')`, plus the Qt plugin
directories needed on Windows:

- `qt6/plugins/platforms`;
- `qt6/plugins/styles`;
- `qt6/plugins/iconengines`;
- `qt6/plugins/imageformats`.

It does not stage the Qt development headers, static libraries, tools, full
Octave IDE, or the rest of the Qt SDK.

The stock Octave `qt.conf` contains an absolute installation prefix, so it is
not copied. The builder generates a relocatable `bin/qt.conf` using
`Prefix=..` and `Plugins=qt6/plugins`; this prevents Qt from depending on the
source Octave installation after relocation.

A graphics-enabled build is generated with:

`powershell -ExecutionPolicy Bypass -File util\build_octave_runtime.ps1 -Destination C:\temp\octave_featool_qt_generated -GraphicsSupport -Validate`

The measured graphics profile is:

- payload: 1,637 files;
- payload bytes: 212,457,413 bytes;
- payload size: approximately 202.6 MiB;
- increase over the 125.1 MiB headless profile: approximately 77.5 MiB.

The graphics validation launches `octave.exe --no-gui`, selects the Qt toolkit,
creates a visible figure and plot, creates and updates a waitbar with a
`createcancelbtn` callback, verifies both graphics handles, then closes them and
exits normally. The isolated builder validation reports:

`QT_GRAPHICS_WAITBAR_PROBE=pass`

The standard numerical and MEX validation suite also passes on the same
graphics-enabled artifact with the full Octave installation excluded from
`PATH`.

Production FEATool graphics paths were also exercised directly against this
artifact, using repository `.m` sources and FEATool grid primitives so the test
did not depend on separately packaged geometry helpers. The qualification
covered:

- 2-D `postplot` with surface, contour, arrow, and colorbar rendering;
- `plotgrid` with node and cell labels;
- 3-D `postplot` slice rendering;
- 3-D `postplot` surface rendering with a cell-selection expression;
- FEATool `gui_Waitbar` creation, update, redraw, and close.

The runtime was launched from
`C:\temp\octave_featool_qt_generated\mingw64\bin\octave.exe --no-gui`, with
the installed Octave removed from `PATH` and `OCTAVE_HOME`/
`OCTAVE_EXEC_HOME` pointing at the generated runtime. The probe resolved
`postplot.m` from the FEATool repository and reported:

- `FEATOOL_POSTPLOT_2D=pass`;
- `FEATOOL_PLOTGRID_LABELS=pass`;
- `FEATOOL_POSTPLOT_3D_SLICE=pass`;
- `FEATOOL_POSTPLOT_3D_SURFACE=pass`;
- `FEATOOL_GUI_WAITBAR=pass`;
- `FEATOOL_PRODUCTION_GRAPHICS=pass`.

An initial example-based probe using `gobj_rectangle` reached the external
`geomtool` geometry-helper boundary and could not create the geometry object.
That helper is intentionally outside the stripped interpreter runtime, so the
production graphics qualification uses `rectgrid`/`blockgrid` instead. External
geometry helpers remain a separate packaging and validation requirement.

Applications using this profile should launch through `octave.exe --no-gui`
when Qt plotting/waitbars are required. The default headless runtime continues
to use `octave-cli.exe --no-window-system` and does not carry the Qt overhead.

Plot-file export through `print` is not yet part of the graphics-profile
acceptance test; add an explicit export test and any required image codec support
if exported PNG/PDF/SVG files are part of the deployed FEATool workflow.

## Validation results

The generated runtime passed:

- `test/test_smoke.m`;
- `testModelsAndExamples:test_ex_poisson1`;
- all `testSolvPoisson1` cases;
- all `testAssemblea` cases, including 1-D/2-D/3-D mass, diffusion, and
  convection assembly;
- `testSolver:test_solvetime_BE_diffusion2`;
- `testSolver:test_solvestat_newton_partial_solcomp`;
- a separately compiled MEX probe loaded by the generated runtime, with
  `MEX_RUNTIME_PROBE=pass`;
- FEATool `pyengine('start',false)` using the packaged bridge/CPython runtime,
  with `PYENGINE_HEADLESS=pass`;
- FEATool `pyengine('start',true)`, which initializes the actual hidden Tk root,
  with `PYENGINE_TK=pass`.

With `-GraphicsSupport`, the same runtime also passes both the low-level Qt
figure/plot/waitbar probe and the production FEATool `postplot`, `plotgrid`, and
`gui_Waitbar` qualification described above.

The selected eigenvalue reference check
`testSolver:test_solveeig_default_imass` was also investigated. It misses its
`1e-10` reference tolerance under both the full GNU Octave 11.3.0 installation
and the reduced runtime, so it is not evidence of a pruning regression.

The broad `testGrid` suite is not an acceptance test for the minimal interpreter
alone because several cases require the external FEATool `geomtool` executable
and one case requires a graphics toolkit. Built-in grid primitives exercised
before those boundaries work. External FEATool executables should be packaged
beside the Octave runtime as independent application assets.

## Python/Tk bridge integration

The development bridge/Tk integration is qualified against the generated
runtime. `pyengine('runtime')` resolves the FEATool Windows runtime under
`featool/_assets/bin/pyrt/win-x64`, currently about 82.6 MiB and containing the
host-neutral bridge MEX, CPython 3.14.10, Tcl/Tk, and Tkinter.

In the development layout its Python backend is intentionally loaded from the
sibling `pyruntime` checkout; the `pyruntime` package source itself is about
1.74 MiB.

With Tk initialized through `pyengine('start',true)`, a process-module census
showed:

- 55 modules from the generated Octave runtime;
- zero modules from the full installed Octave tree;
- 13 modules from the FEATool PyRuntime;
- zero Python DLLs from outside that PyRuntime;
- zero Tcl/Tk DLLs from outside that PyRuntime.

This establishes the intended execution boundary:

`Octave -> bridge MEX -> embedded CPython -> Tk`

without ambient Octave/Python/Tk native fallback.

## Size floor and further reduction

The remaining 125 MiB is already close to the practical floor for pruning the
official Windows Octave binary distribution. Approximately 109 MiB is the
54-file native `bin` closure, dominated by BLAS, `liboctave`/`liboctinterp`,
LAPACK, HDF5, FFTW, Fortran runtime, and SuiteSparse. These files were mapped
during the headless FEATool solve.

Material reductions below this point would require a custom Octave build with
optional dependencies disabled rather than ordinary runtime pruning.

The approximate current development-layout footprint is:

- minimal Octave runtime: 125.1 MiB;
- optional Qt graphics Octave runtime: 202.6 MiB total, including the 77.5 MiB
  graphics overhead over the headless profile;
- FEATool PyRuntime: 82.6 MiB;
- FEATool `.m` source: about 5.7 MiB;
- PyRuntime Python source: about 1.74 MiB;
- total before external FEATool helpers and other application assets: about
  215 MiB with the headless Octave profile, or about 293 MiB with the Qt
  graphics profile.

These are installed/uncompressed payload measurements. A ZIP/7z archive or
Windows installer will normally be smaller on disk while compressed, but no
release-package compression size should be claimed until the exact production
tree has been assembled and measured.

## Distribution packaging

Package Octave as an application-private, relocatable FEATool runtime rather
than installing it as a system-wide GNU Octave. The release should first be
assembled as one self-contained directory tree; portable archives and a Windows
installer should wrap that same tree rather than maintain different runtime
layouts.

A target layout is:

```text
FEATool/
  bin/
    featool-launcher.exe
  runtime/
    octave/
      mingw64/
    python/
      ...
  featool/
    ... FEATool .m sources ...
  helpers/
    ... geomtool/gmsh/solver executables ...
  licenses/
    ... Octave and other redistributed-license material ...
```

The launcher must configure only the child process environment. It should set
`OCTAVE_HOME` and `OCTAVE_EXEC_HOME` to the bundled runtime, prepend the private
Octave `mingw64/bin` directory to the child `PATH`, clear or override
`OCTAVE_PATH` as required by the validated runtime, and exclude ambient Octave,
MATLAB, Python, Tcl, and Tk paths that could provide accidental fallback. It
must not require a permanent system `PATH` change, registry-based Octave
installation, or an existing user Octave installation.

The default/headless application path should start the bundled
`octave-cli.exe --no-window-system`. When the optional native graphics component
is installed and requested, the launcher should instead use the bundled
`octave.exe --no-gui` with the existing relative `bin/qt.conf`. The runtime
tree must remain relocatable after installation or extraction.

Two distribution surfaces can use this same payload:

- a portable ZIP/7z package that is extracted and run in place, with no system
  installation requirements;
- a conventional Windows installer, preferably a thin wrapper around the same
  directory tree, using Inno Setup, NSIS, WiX/MSI, or an equivalent installer
  technology.

For the installer, make native Octave Qt graphics an optional component. The
base install then carries the 96.0 MiB hosted headless Octave runtime; selecting the
graphics component adds approximately 77.5 MiB and enables the 173.6 MiB hosted Qt
profile. External geometry, meshing, and solver helpers remain separate FEATool
application assets under `helpers/` and should not be folded into the Octave
interpreter runtime merely for installer convenience.

The production package also needs the applicable GNU Octave/GPL license
material and a compliant corresponding-source distribution mechanism. Treat
that compliance material as a required release artifact alongside the runtime,
not as an installer-only afterthought.

## Remaining work

Runtime feasibility, focused FEATool qualification, and the deterministic
GitHub-hosted Windows build of the standalone Octave payload are established.
The repository also defines the authenticated hosted FEATool/package
qualification gate, but no immutable production qualification bundle is
configured in GitHub yet.

A production FEATool package must:

1. publish an immutable FEATool qualification bundle and configure its URL and
   SHA-256 for the hosted qualification gate;
2. include the production-composed PyRuntime in that bundle and pass the
   embedded Python/Tk probes under strict isolation;
3. package required external FEATool geometry/mesh/solver helpers independently;
4. assemble and qualify the application-private relocatable release tree and
   launcher;
5. wrap the same qualified tree as a portable archive and/or Windows installer,
   with Qt graphics optional rather than a base requirement;
6. verify no ambient Octave, Python, Tcl, or Tk fallback after relocation and
   through the production launcher;
7. define and satisfy GNU Octave GPL license and corresponding-source
   distribution obligations for the shipped artifact.

If the release requires plot-file export, separately qualify `print` for the
required PNG/PDF/SVG formats and stage only the additional export dependencies
that the resulting trace demonstrates. Visible Qt plots and FEATool waitbars are
qualified; plot-file export remains outside the current acceptance scope.

## Acceptance criteria

The stripped Octave runtime is acceptable when:

- it is reproducibly generated by `util/build_octave_runtime.ps1` from the
  supported GNU Octave 11.3.0 Windows distribution;
- a GitHub-hosted Windows workflow downloads the pinned official Octave
  distribution, verifies its SHA-256 digest, runs the required post-install
  setup, builds the requested runtime profiles, and publishes archives
  containing the generated manifest;
- FEATool headless solver and assembly qualification passes with ambient Octave
  installations excluded;
- the MEX loader/API probe passes in the generated runtime;
- if `-GraphicsSupport` is shipped, both the Qt figure/plot/waitbar probe and
  representative FEATool `postplot`, `plotgrid`, and `gui_Waitbar` paths pass
  from the generated runtime with no fallback to the full Octave installation;
- the packaged Python MEX bridge and Tk/PyRuntime stack pass against that exact
  generated runtime with no ambient Python/Octave/Tcl/Tk fallback;
- required external FEATool geometry/mesh/solver executables are packaged and
  validated independently;
- the final release uses the production-composed PyRuntime rather than the
  development sibling-source fallback;
- the release is relocatable as one application-private directory tree and
  launches without a system Octave installation, permanent `PATH` edits, or
  registry-installed Octave state;
- the portable archive and any Windows installer use the same qualified runtime
  payload, with Qt graphics optional rather than required by the base install;
- redistribution includes the required GNU Octave license and corresponding
  source compliance material.

The current checkpoint is a deterministic GitHub-hosted 96.0 MiB headless
Octave payload and 173.6 MiB Qt payload with reproducible manifests and verified
archives. Focused FEATool numerical, MEX, embedded CPython, Tk, plotting, and
waitbar qualification has passed against development inputs. Production
PyRuntime selection and strict isolation are represented in the builder, and
the authenticated hosted qualification gate is defined. Publishing the immutable
production FEATool/PyRuntime bundle, final application assembly/launcher
qualification, helper packaging, and corresponding-source compliance remain
external release-input tasks.
