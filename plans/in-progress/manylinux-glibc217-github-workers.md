---
kind: plan
title: GNU Octave glibc 2.17 runtime on GitHub-hosted workers
summary: Build and qualify the Linux x86-64 GNU Octave 11.3.0 runtime in a pinned manylinux2014 environment on GitHub-hosted Ubuntu runners, with a verified GLIBC_2.17 compatibility floor and reproducible release artifacts.
area: deployment
priority: P1
depends_on:
  - plans/in-progress/stripped-octave-runtime-featool.md
children: []
affected_files:
  - plans/in-progress/manylinux-glibc217-github-workers.md
  - .github/workflows/build-linux-runtime.yml
  - .github/workflows/release-runtime.yml
  - util/build_octave_runtime_linux.sh
  - util/linux_runtime_tool.py
  - util/build_manylinux_deps.sh
  - util/manylinux-deps.lock
  - README.md
---

## Goal

Produce the existing headless GNU Octave 11.3.0 Linux x86-64 runtime on GitHub
hosted runners with a maximum required glibc symbol version of `GLIBC_2.17`.
The artifact remains a standalone FEATool runtime archive rather than a Python
wheel.  The manylinux2014 image is used as the controlled glibc 2.17 build
environment; the release claim is that every delivered ELF object is compatible
with the selected glibc floor and that all non-host native dependencies required
by the runtime are packaged.

The existing Ubuntu 22.04/glibc 2.35 build remains available as a checkpoint
until the new lane has passed the complete compatibility matrix and release
artifacts have been compared.

## Definition of done

The manylinux lane is ready to become the Linux release producer when all of the
following are true:

- the build executes from a GitHub-hosted `ubuntu-24.04` runner;
- compilation, dependency staging, ELF patching, and ABI verification execute
  inside a digest-pinned `manylinux2014_x86_64` build environment;
- GNU Octave 11.3.0 and every packaged native dependency are built or selected
  from the controlled manylinux environment;
- the runtime manifest reports a maximum required `GLIBC` version no newer than
  `2.17` across every delivered ELF object;
- no delivered object depends on `libmvec.so.1` or another glibc component that
  is unavailable at the 2.17 baseline;
- compiler runtimes such as `libstdc++.so.6`, `libgcc_s.so.1`, `libgfortran`,
  and `libquadmath` resolve to the intended bundled copies;
- sparse linear algebra, ARPACK, FFTW, HDF5, Qhull, JSON, MEX loading, curl HTTPS,
  manifest verification, archive extraction, and relocation smoke tests pass;
- the extracted artifact passes on a clean glibc 2.17 environment and on a
  current newer Linux environment without relying on an installed Octave;
- two fresh hosted builds from identical pinned inputs produce identical runtime
  manifests and archive SHA-256 values, or any remaining nondeterminism is
  explicitly identified and removed before release promotion;
- `.github/workflows/release-runtime.yml` consumes the qualified manylinux
  artifact without changing the public Linux archive name.

## GitHub-hosted execution model

Do not set the GitHub job-level `container:` to the glibc 2.17 image.  Modern
JavaScript Actions run their own Node runtime inside a job container, and that
runtime may require a newer glibc than manylinux2014 provides.  Keep the outer
job on `ubuntu-24.04`, run checkout/cache/upload/release Actions on the host, and
invoke the manylinux environment explicitly with Docker.

The intended structure is:

```text
GitHub hosted ubuntu-24.04 runner
  |
  +-- actions/checkout
  +-- download and SHA-256 verify immutable source inputs
  +-- restore dependency cache, if enabled
  |
  +-- docker run <digest-pinned manylinux2014_x86_64>
  |     |
  |     +-- enable the GCC 10 toolchain supplied by the image
  |     +-- build pinned third-party dependencies into /opt/featool-deps
  |     +-- build GNU Octave 11.3.0
  |     +-- stage the relocatable ELF closure
  |     +-- enforce GLIBC <= 2.17
  |     +-- run numerical, MEX, HTTPS, and relocation checks
  |     +-- write runtime + manifest + build evidence to mounted output
  |
  +-- archive deterministically on the host or with a pinned archive tool
  +-- test extracted artifact in clean compatibility containers
  +-- actions/upload-artifact
```

The manylinux image must be pinned by immutable digest in the workflow.  Human
readable image tags may be recorded next to the digest for maintenance, but a
moving tag must not be the build identity.

## Phase 1: Add a compatibility lane without changing releases

Extend `.github/workflows/build-linux-runtime.yml` so the existing Ubuntu 22.04
lane remains intact and a second `manylinux2014` lane can be run on pull requests,
manual dispatches, and the feature branch used for qualification.

Initially give the new artifact a distinct Actions artifact name such as
`featool-octave-runtime-linux-x64-glibc217`.  Keep the archive filename inside
that artifact as `featool-octave-runtime-linux-x64.tar.zst` so promotion later
does not require changing downstream release naming.

The lane should perform these host-side steps before entering Docker:

1. check out the repository with the existing pinned/approved Action version;
2. download GNU Octave 11.3.0 and verify the existing pinned SHA-256;
3. download every source-built dependency from an immutable URL and verify a
   repository-recorded SHA-256 before compilation;
4. record the manylinux image digest and runner image metadata;
5. create mounted source, build, cache, evidence, and artifact directories under
   `$RUNNER_TEMP` or `$GITHUB_WORKSPACE`;
6. invoke the manylinux build with explicit mounts and environment variables;
7. verify that every expected artifact/evidence file exists before upload.

The Docker invocation should not depend on the runner's ambient compiler,
Python, pkg-config paths, or native libraries.  Only source files, verified input
archives, cache content, and output directories should cross the boundary.

## Phase 2: Build a pinned native dependency prefix

Add `util/build_manylinux_deps.sh`.  Its responsibility is to create a private
prefix such as `/opt/featool-deps` containing the runtime-linked dependencies
needed by the Octave configuration.  This removes the current Debian-specific
HDF5 and SuiteSparse include/library assumptions and avoids depending on EOL
CentOS 7 development packages.

Prefer source builds with explicitly pinned versions and SHA-256 values for the
runtime-linked stack.  The initial set should cover the dependencies currently
qualified by the Linux runtime:

- BLAS/LAPACK implementation selected for the portable x86-64 runtime;
- SuiteSparse;
- ARPACK-NG;
- FFTW;
- HDF5;
- Qhull;
- curl and its selected TLS backend;
- PCRE2;
- readline and required terminal libraries if they enter the runtime closure;
- zlib and other compression libraries required by the selected stack;
- RapidJSON when needed at build time;
- libtool/libltdl or other libraries that are linked into delivered objects.

Keep pure build tools separate from delivered runtime dependencies.  Build tools
may come from the pinned manylinux image when the image version is sufficient.
If a required build tool is missing or too old, pin it as a build-only input
rather than silently using a GitHub-host copy.

Each dependency build must use the same compiler family and glibc environment as
Octave.  Install `.pc` files into the private prefix and export, at minimum:

```bash
CPPFLAGS="-I/opt/featool-deps/include"
LDFLAGS="-L/opt/featool-deps/lib -L/opt/featool-deps/lib64"
PKG_CONFIG_PATH="/opt/featool-deps/lib/pkgconfig:/opt/featool-deps/lib64/pkgconfig"
```

Add dependency version, source URL, SHA-256, configure flags, compiler identity,
and resulting library hashes to the uploaded build evidence.  Do not treat the
GitHub Actions cache as provenance; the source lock and resulting evidence are
the provenance.

## Phase 3: Generalize the Octave Linux builder

Update `util/build_octave_runtime_linux.sh` so it can build against an explicit
dependency prefix instead of Debian filesystem paths.

Required changes:

- add a `--dependency-prefix` argument or equivalent environment contract;
- remove `/usr/include/hdf5/serial`, `/usr/include/suitesparse`, and
  `/usr/lib/x86_64-linux-gnu/hdf5/serial` assumptions;
- derive compiler/linker/pkg-config flags from the dependency prefix;
- use a locale known to exist in the manylinux environment, with `C` as the safe
  fallback for build and smoke-test execution;
- select the Python interpreter used by `linux_runtime_tool.py` explicitly from
  the manylinux image rather than assuming `/usr/bin/python3` has the required
  language version;
- continue recording the configured prefix and source/build prefix maps so no
  private runner paths leak into delivered loader metadata;
- keep the current MEX probe and numerical validation, then extend validation
  with a real HTTPS request through the packaged curl/TLS stack.

The builder should fail before compilation if the active C/C++/Fortran compilers
or `ldd --version` do not match the expected manylinux toolchain/glibc baseline.

## Phase 4: Make dependency closure deterministic under manylinux

Update `util/linux_runtime_tool.py` so dependency staging does not rely only on
`ldconfig -p`.  In a manylinux image the active GCC runtime may live outside the
base operating system library cache, and selecting an older CentOS library by
SONAME would make the packaged closure inconsistent with the compiler actually
used for Octave.

Dependency resolution should use an ordered search policy:

1. libraries already inside the Octave installation tree;
2. explicit private dependency-prefix library directories;
3. compiler runtime locations reported by `gcc`, `g++`, and `gfortran`, for
   example with `-print-file-name=<soname>`;
4. explicitly approved manylinux system library directories;
5. `ldconfig` only as a final discovery source for non-host libraries.

Record the source path and SHA-256 of every copied dependency in the manifest or
adjacent build evidence so a wrong runtime-library selection is diagnosable.

For the glibc 2.17 baseline, make the host-library allowlist baseline-aware.
`libmvec.so.1` must not be assumed to exist because it post-dates glibc 2.17.
The allowlist for the 2.17 artifact should include only libraries guaranteed by
the selected target contract.  Any unexpected dependency on a newer glibc
component must fail preparation.

Add explicit assertions that the packaged closure contains or internally
resolves the intended compiler runtimes used by delivered objects.  At minimum,
audit `libstdc++.so.6`, `libgcc_s.so.1`, `libgfortran`, and `libquadmath` when
they are referenced.

## Phase 5: Strengthen ABI and hermeticity checks

Keep the existing maximum-version scan and make `GLIBC_2.17` a hard acceptance
gate for the new lane.  The gate must scan all delivered ELF executables, shared
libraries, `.oct` files, and packaged MEX binaries after RPATH/RUNPATH rewriting.

Add or retain checks for:

- x86-64 ELF architecture only;
- no absolute build/source paths in loader-visible metadata;
- no external symlink targets;
- only `$ORIGIN`-relative RPATH/RUNPATH entries;
- every non-host `DT_NEEDED` edge resolves inside the packaged runtime;
- maximum required `GLIBC` is `2.17` or older;
- manifest records `GLIBCXX`, `CXXABI`, and `GCC` maxima for diagnostics;
- no dependency on `libmvec.so.1` in the glibc 2.17 artifact;
- no dependency resolves to the GitHub runner filesystem;
- all MEX and `.oct` modules are included in the ABI scan rather than only the
  main Octave binaries.

The existing `ldd` audit is useful inside the build environment, but the clean
target-container test is the final authority for whether the artifact is really
self-contained at the selected floor.

## Phase 6: Qualify TLS and non-ELF runtime data

The current curl smoke test uses `file://`, which proves Octave/curl integration
but does not prove HTTPS deployment.  Add a deterministic HTTPS probe against a
stable endpoint or a test TLS service created inside the workflow.  Prefer a
local test service when practical so release qualification does not depend on a
third-party site's availability.

Choose and document the certificate trust model:

- package an explicit CA bundle and point the runtime at it; or
- intentionally use the target host CA store and make that host dependency part
  of the runtime contract.

Also inspect libraries that use `dlopen` or runtime data directories.  `DT_NEEDED`
closure alone cannot discover every provider/plugin/data-file dependency.  Run
the qualification probes under `strace` or loader diagnostics in the clean
compatibility environment and reject unexpected file/library loads outside the
runtime except for the documented host contract.

## Phase 7: Deterministic archive production

Do not rely on archive options that happen to exist in the old manylinux base
userspace.  The current archive requires sorted entries, normalized timestamps,
numeric ownership, and zstd compression.

The preferred design is to create the final archive on the Ubuntu host after the
manylinux container has produced and verified the exact runtime tree.  Use the
host's known GNU tar/zstd versions and retain the existing deterministic flags.
Then extract the archive into a different absolute path and rerun runtime
verification inside compatibility containers.

If archive creation is moved into the manylinux container instead, install or
build explicitly pinned archive tools and record their versions.  Do not depend
on CentOS 7's stock tar supporting `--sort=name` or `--zstd`.

## Phase 8: Compatibility validation matrix

Run the exact archive produced by the manylinux lane through at least these
environments:

| Environment | Purpose | Required result |
| --- | --- | --- |
| manylinux2014 / glibc 2.17 | Compatibility floor | Full manifest, relocation, numerical, MEX, HDF5, Qhull, FFTW, ARPACK, and HTTPS probes pass |
| fresh second glibc 2.17 container or equivalent minimal target | Detect build-image leakage | Same runtime probes pass after archive extraction at a different absolute path |
| Ubuntu 20.04 / glibc 2.31 | Representative older supported desktop/server | Smoke and numerical probes pass |
| Ubuntu 22.04 / glibc 2.35 | Current checkpoint comparison | Smoke and numerical probes pass |
| Ubuntu 24.04 / current runner glibc | Forward compatibility | Smoke and numerical probes pass |

Do not rebuild between these tests.  Every compatibility job must consume the
same archive produced by the manylinux build job.

Use an Actions artifact to transfer the archive between jobs when separate
runner environments are useful.  Keep retention short during development and
extend it only for release evidence as needed.

## Phase 9: Caching strategy

The initial qualification run should work with caching disabled so correctness
does not depend on cache contents.  Once the clean build passes, add caching for
source archives and expensive dependency build outputs.

Cache keys must include:

- manylinux image digest;
- architecture;
- compiler/toolchain identity;
- dependency lock/version hash;
- dependency build script hash;
- relevant compile/configure flags.

Never cache the final runtime as an input to the build lane.  The runtime and its
manifest remain outputs produced and verified on every canonical build.

## Phase 10: Build evidence and diagnostics

Upload enough evidence to diagnose compatibility regressions without rerunning a
two-hour native build.  In addition to the current runtime manifest and Octave
configure output, publish:

- manylinux image repository, tag, and immutable digest;
- `/etc/os-release` and `ldd --version` from the build environment;
- GCC, G++, GFortran, binutils, Python, patchelf, tar, and zstd versions;
- pinned dependency source/version/SHA-256 lock data;
- dependency configure/build summaries;
- complete Octave `configure.out`;
- mapping from bundled SONAME to source path and file SHA-256;
- maximum `GLIBC`, `GLIBCXX`, `CXXABI`, and `GCC` requirements;
- final runtime manifest, archive SHA-256, payload size, and file count;
- compatibility-test summaries for every target environment.

On ABI failure, print the delivered ELF files requiring the newest offending
symbol version rather than only the aggregate maximum.  On dependency-resolution
failure, print the requested SONAME, all candidate paths considered, and the
selected search tier.

## Phase 11: Release promotion

Keep `.github/workflows/release-runtime.yml` pointed at the existing Linux build
until the manylinux lane has passed qualification on at least two fresh hosted
runs with identical pinned inputs.

Promotion sequence:

1. make the manylinux lane a required part of the reusable Linux workflow;
2. compare payload contents and numerical behavior against the Ubuntu 22.04
   checkpoint;
3. publish a prerelease/test tag using the manylinux artifact;
4. download that release asset and repeat archive verification independently;
5. change the canonical Linux artifact producer to the glibc 2.17 lane;
6. retain the Ubuntu 22.04 lane temporarily as a non-release diagnostic lane;
7. remove the old lane after the glibc 2.17 artifact has completed normal FEATool
   integration qualification and there is no remaining diagnostic need.

The public filename remains `featool-octave-runtime-linux-x64.tar.zst`.  Record
the selected glibc floor and build-image digest in the embedded manifest so the
compatibility contract travels with the archive.

## Expected implementation order

Implement in this order so failures are attributable to one layer at a time:

1. add a minimal GitHub-hosted Docker smoke lane that proves the pinned
   manylinux image runs and reports glibc/toolchain identities;
2. make `linux_runtime_tool.py` work correctly with explicit dependency and
   compiler-runtime search roots, including the glibc 2.17 host allowlist;
3. add the private dependency-prefix builder and prove each dependency is
   compiled under glibc 2.17;
4. generalize `build_octave_runtime_linux.sh` and obtain the first complete
   Octave build in manylinux2014;
5. pass the existing numerical/MEX checks and hard `GLIBC <= 2.17` audit;
6. add HTTPS/TLS and runtime-data hermeticity checks;
7. produce the deterministic archive on the host and qualify the same archive
   across the compatibility matrix;
8. prove repeat-build identity;
9. update README compatibility documentation;
10. promote the manylinux artifact into the release workflow.

## Implementation progress

As of 2026-11-26, `feat/manylinux-glibc217-workers` contains the first two
implementation increments:

- `.github/workflows/build-linux-runtime.yml` has a host-level
  `manylinux-smoke` job on `ubuntu-24.04`.  It pulls a digest-pinned
  `manylinux2014_x86_64` image, activates the image's GCC 10 toolchain, asserts
  glibc 2.17 and GCC 10, records hosted-runner and container identities, and
  uploads the smoke evidence.  The existing Ubuntu 22.04 checkpoint build is
  unchanged.
- `util/linux_runtime_tool.py` resolves non-host ELF dependencies in the planned
  order: runtime tree, explicit dependency prefixes, active compiler runtime
  paths, approved manylinux system directories, then `ldconfig`.  The glibc host
  allowlist is baseline-aware, compiler runtimes cannot silently fall through to
  an ambient system copy, and copied-library provenance records the selected
  path, resolved source path, SHA-256, and search tier.

Hosted run `45818617122` at commit `42eb743` passed the `manylinux-smoke` job on
`ubuntu-24.04`.  The pinned image reported CentOS 7 with glibc 2.17, GCC/G++/
GFortran 10.2.1 from `/opt/rh/devtoolset-10`, and GNU ld 2.35.  Build and
qualification commands for this plan are run on GitHub-hosted Actions runners;
local execution is not used as acceptance evidence.

Hosted run `45819447121` at commit `e486a7f` resolved and recorded SHA-256 values
for all 14 immutable dependency source archives before the private-prefix build
was added.  These values are committed in `util/manylinux-deps.lock` and are
verified again on the host before any archive is mounted into the build
container.

## Acceptance checklist

- [x] manylinux image is pinned by digest.
- [x] outer GitHub job stays on `ubuntu-24.04`; modern Actions execute outside
      the glibc 2.17 container.
- [x] all downloaded source archives have repository-pinned SHA-256 values.
- [ ] dependency prefix is independent of Debian/Ubuntu include/library paths.
- [x] active GCC/G++/GFortran toolchain is recorded and verified before build.
- [ ] compiler-runtime closure is selected from the intended toolchain.
- [x] glibc 2.17 host allowlist excludes `libmvec.so.1`.
- [ ] every delivered ELF object requires `GLIBC_2.17` or older.
- [ ] all non-host `DT_NEEDED` dependencies resolve inside the runtime.
- [ ] sparse, ARPACK, FFTW, HDF5, Qhull, JSON, and MEX probes pass.
- [ ] real HTTPS/TLS probe passes under the documented CA trust model.
- [ ] clean glibc 2.17 extraction/relocation test passes.
- [ ] Ubuntu 20.04, 22.04, and 24.04 compatibility tests pass using the same
      archive.
- [ ] archive is deterministic across two fresh hosted builds.
- [ ] build evidence contains source locks, toolchain identity, dependency
      provenance, ABI maxima, manifest, and archive SHA-256.
- [ ] release workflow consumes the glibc 2.17 artifact without changing the
      public archive filename.

## Non-goals for this plan

This plan does not add Qt/native Octave graphics, package a Python wheel, claim
formal manylinux wheel-policy compliance, or complete the external FEATool and
PyRuntime qualification inputs described in the parent runtime plan.  Those are
separate release concerns.  The scope here is the standalone headless GNU Octave
Linux runtime, its native dependency closure, and a verified glibc 2.17 floor on
GitHub-hosted workers.
