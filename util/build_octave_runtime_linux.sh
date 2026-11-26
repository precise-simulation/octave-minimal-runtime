#!/usr/bin/env bash
set -euo pipefail

OCTAVE_VERSION="11.3.0"
PROFILE="headless-cli-featool"
CONFIGURED_PREFIX="/opt/featool-octave"

usage() {
  cat <<'EOF'
Usage: build_octave_runtime_linux.sh \
  --source-dir DIR --build-dir DIR --destination DIR \
  --source-archive NAME --source-sha256 SHA256 \
  --build-image IMAGE --glibc-baseline VERSION [--jobs N] [--validate]

Build GNU Octave 11.3.0 from source, install it into an isolated staging prefix,
prune development content, assemble a relocatable ELF dependency closure, and
write runtime-manifest.json.  The current checkpoint is headless-only.
EOF
}

source_dir=""
build_dir=""
destination=""
source_archive=""
source_sha256=""
build_image=""
glibc_baseline=""
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
validate=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir) source_dir="$2"; shift 2 ;;
    --build-dir) build_dir="$2"; shift 2 ;;
    --destination) destination="$2"; shift 2 ;;
    --source-archive) source_archive="$2"; shift 2 ;;
    --source-sha256) source_sha256="$2"; shift 2 ;;
    --build-image) build_image="$2"; shift 2 ;;
    --glibc-baseline) glibc_baseline="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --validate) validate=1; shift ;;
    --graphics-support)
      printf 'error: --graphics-support is not implemented in the first Linux checkpoint\n' >&2
      exit 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for required_name in source_dir build_dir destination source_archive source_sha256 build_image glibc_baseline; do
  if [[ -z "${!required_name}" ]]; then
    printf 'error: --%s is required\n' "${required_name//_/-}" >&2
    usage >&2
    exit 2
  fi
done

for command_name in bash make python3 gcc g++ gfortran patchelf readelf objdump ldconfig ldd; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_tool="$script_dir/linux_runtime_tool.py"
if [[ ! -f "$runtime_tool" ]]; then
  printf 'error: runtime tool is missing: %s\n' "$runtime_tool" >&2
  exit 1
fi

source_dir="$(realpath "$source_dir")"
build_dir="$(realpath -m "$build_dir")"
destination="$(realpath -m "$destination")"

if [[ ! -x "$source_dir/configure" ]]; then
  printf 'error: GNU Octave configure script is missing: %s/configure\n' "$source_dir" >&2
  exit 1
fi

if [[ -e "$build_dir" ]] && [[ -n "$(find "$build_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  printf 'error: build directory must be empty: %s\n' "$build_dir" >&2
  exit 1
fi
if [[ -e "$destination" ]] && [[ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  printf 'error: destination must be empty: %s\n' "$destination" >&2
  exit 1
fi

case "$build_dir/" in
  "$source_dir"/*) printf 'error: build directory must not be inside the source tree\n' >&2; exit 1 ;;
esac
case "$destination/" in
  "$source_dir"/*|"$build_dir"/*) printf 'error: destination must not be inside source/build trees\n' >&2; exit 1 ;;
esac

mkdir -p "$build_dir" "$destination"
object_dir="$build_dir/obj"
stage_dir="$build_dir/stage"
probe_dir="$build_dir/probe"
mkdir -p "$object_dir" "$stage_dir" "$probe_dir"

configure_args=(
  "--prefix=$CONFIGURED_PREFIX"
  "--disable-docs"
  "--disable-java"
  "--disable-static"
  "--enable-relocate-all"
  "--enable-shared"
  "--without-qt"
  "--without-fltk"
  "--without-opengl"
  "--without-magick"
)
printf '%s\n' "${configure_args[@]}" > "$build_dir/configure-args.txt"

common_flags="-O2 -g0 -fPIC -ffile-prefix-map=$source_dir=/usr/src/octave-$OCTAVE_VERSION -ffile-prefix-map=$build_dir=/usr/src/octave-build"
export CFLAGS="${CFLAGS:-$common_flags}"
export CXXFLAGS="${CXXFLAGS:-$common_flags}"
export FFLAGS="${FFLAGS:-$common_flags}"
export FCFLAGS="${FCFLAGS:-$common_flags}"
export CPPFLAGS="${CPPFLAGS:-} -I/usr/include/hdf5/serial -I/usr/include/suitesparse"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib/x86_64-linux-gnu/hdf5/serial"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1780272000}"
export TZ="UTC"
export LC_ALL="C.UTF-8"

printf 'octave_version=%s\n' "$OCTAVE_VERSION"
printf 'build_image=%s\n' "$build_image"
printf 'glibc_baseline=%s\n' "$glibc_baseline"
printf 'source_dir=%s\n' "$source_dir"
printf 'build_dir=%s\n' "$build_dir"
printf 'destination=%s\n' "$destination"

pushd "$object_dir" >/dev/null
"$source_dir/configure" "${configure_args[@]}" 2>&1 | tee "$build_dir/configure.out"
make -j"$jobs"
make DESTDIR="$stage_dir" install
popd >/dev/null

install_root="$stage_dir$CONFIGURED_PREFIX"
if [[ ! -x "$install_root/bin/octave-cli" ]]; then
  printf 'error: staged octave-cli is missing: %s/bin/octave-cli\n' "$install_root" >&2
  exit 1
fi

# Build a MEX probe while the development files still exist.  The probe itself
# stays outside the delivered runtime and is loaded after pruning.
cat > "$probe_dir/octave_runtime_mex_probe.c" <<'EOF'
#include "mex.h"
void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
  double x = nrhs ? mxGetScalar(prhs[0]) : 0.0;
  if (nlhs) plhs[0] = mxCreateDoubleScalar(x + 1.0);
}
EOF

install_ld_path="$(find "$install_root/lib" -type d -print | paste -sd: -)"
env \
  PATH="$install_root/bin:$PATH" \
  OCTAVE_HOME="$install_root" \
  OCTAVE_EXEC_HOME="$install_root" \
  LD_LIBRARY_PATH="$install_ld_path" \
  "$install_root/bin/mkoctfile" --mex \
    "$probe_dir/octave_runtime_mex_probe.c" \
    -o "$probe_dir/octave_runtime_mex_probe.mex"
if [[ ! -f "$probe_dir/octave_runtime_mex_probe.mex" ]]; then
  printf 'error: MEX probe was not produced\n' >&2
  exit 1
fi

cp -a "$install_root/." "$destination/"

# Keep interpreter runtime content and remove development/documentation surfaces.
rm -rf \
  "$destination/include" \
  "$destination/share/doc" \
  "$destination/share/info" \
  "$destination/share/man" \
  "$destination/share/applications" \
  "$destination/share/icons" \
  "$destination/share/metainfo"
find "$destination" -type f \( -name '*.a' -o -name '*.la' \) -delete
rm -rf "$destination/lib/pkgconfig" "$destination/lib/cmake"

if [[ -d "$destination/bin" ]]; then
  find "$destination/bin" -mindepth 1 -maxdepth 1 \
    ! -name 'octave-cli' \
    ! -name "octave-cli-$OCTAVE_VERSION" \
    -exec rm -rf {} +
fi

mkdir -p "$destination/licenses"
if [[ -f "$source_dir/COPYING" ]]; then
  cp "$source_dir/COPYING" "$destination/licenses/GNU-Octave-COPYING"
fi

cat > "$destination/bin/featool-octave" <<'EOF'
#!/bin/sh
set -eu
case "$0" in
  /*) launcher_path="$0" ;;
  *) launcher_path="$PWD/$0" ;;
esac
script_dir="$(CDPATH= cd -P -- "${launcher_path%/*}" && pwd)"
runtime_root="$(CDPATH= cd -P -- "$script_dir/.." && pwd)"
export OCTAVE_HOME="$runtime_root"
export OCTAVE_EXEC_HOME="$runtime_root"
export PATH="$runtime_root/bin:/usr/bin:/bin"
unset OCTAVE_PATH OCTAVE_SITE_INITFILE OCTAVE_VERSION_INITFILE LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
exec "$runtime_root/bin/octave-cli" --no-window-system --no-init-all "$@"
EOF
chmod 0755 "$destination/bin/featool-octave"

python3 "$runtime_tool" prepare \
  --runtime-root "$destination" \
  --source-archive "$source_archive" \
  --source-sha256 "$source_sha256" \
  --configured-prefix "$CONFIGURED_PREFIX" \
  --build-image "$build_image" \
  --glibc-baseline "$glibc_baseline" \
  --configure-args-file "$build_dir/configure-args.txt" \
  --forbidden-prefix "$source_dir" \
  --forbidden-prefix "$build_dir" \
  --forbidden-prefix "$stage_dir"

if [[ "$validate" -eq 1 ]]; then
  validation_home="$build_dir/validation-home"
  mkdir -p "$validation_home"
  runtime_launcher="$destination/bin/featool-octave"
  octave_probe_dir="${probe_dir//\\//}"
  octave_probe_dir="${octave_probe_dir//\'/\'\'}"
  eval_code="assert(strcmp(OCTAVE_VERSION,'11.3.0')); A=sparse([4 -1;-1 4]); b=[1;2]; x=A\\b; assert(norm(A*x-b)<1e-12); e=eigs(sparse(diag(1:5)),1); assert(abs(e-5)<1e-8); f=fft([1 2 3 4]); assert(numel(f)==4); fn=[tempname() '.h5']; q=magic(3); save('-hdf5',fn,'q'); clear q; load(fn); assert(isequal(q,magic(3))); unlink(fn); assert(~isempty(jsonencode(struct('a',1)))); disp('LINUX_NUMERICAL_RUNTIME=pass');"
  env -i \
    HOME="$validation_home" \
    PATH="/usr/bin:/bin" \
    LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    "$runtime_launcher" --quiet --eval "$eval_code"

  mex_eval="addpath('$octave_probe_dir'); y=octave_runtime_mex_probe(41); assert(y==42); disp('LINUX_MEX_RUNTIME=pass');"
  env -i \
    HOME="$validation_home" \
    PATH="/usr/bin:/bin" \
    LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    "$runtime_launcher" --quiet --eval "$mex_eval"

  python3 "$runtime_tool" verify \
    --runtime-root "$destination" \
    --expected-profile "$PROFILE" \
    --smoke
fi

printf 'build=pass\n'
