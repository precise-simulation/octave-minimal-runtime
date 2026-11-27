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
  --build-image IMAGE --glibc-baseline VERSION \
  [--dependency-prefix DIR] [--python COMMAND] \
  [--expected-build-glibc VERSION] [--expected-gcc-major N] \
  [--jobs N] [--validate]

Build GNU Octave 11.3.0 from source, install it into the disposable container's
configured prefix, prune development content, assemble a relocatable ELF
dependency closure, and write runtime-manifest.json.  The current checkpoint is
headless-only.
EOF
}

source_dir=""
build_dir=""
destination=""
source_archive=""
source_sha256=""
build_image=""
glibc_baseline=""
dependency_prefix=""
python_command="python3"
expected_build_glibc=""
expected_gcc_major=""
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
    --dependency-prefix) dependency_prefix="$2"; shift 2 ;;
    --python) python_command="$2"; shift 2 ;;
    --expected-build-glibc) expected_build_glibc="$2"; shift 2 ;;
    --expected-gcc-major) expected_gcc_major="$2"; shift 2 ;;
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

for command_name in bash make gcc g++ gfortran getconf patchelf readelf objdump ldconfig ldd; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done
if ! command -v "$python_command" >/dev/null 2>&1; then
  printf 'error: requested Python interpreter is missing: %s\n' "$python_command" >&2
  exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_tool="$script_dir/linux_runtime_tool.py"
if [[ ! -f "$runtime_tool" ]]; then
  printf 'error: runtime tool is missing: %s\n' "$runtime_tool" >&2
  exit 1
fi

source_dir="$(realpath "$source_dir")"
build_dir="$(realpath -m "$build_dir")"
destination="$(realpath -m "$destination")"
if [[ -n "$dependency_prefix" ]]; then
  dependency_prefix="$(realpath "$dependency_prefix")"
  if [[ ! -d "$dependency_prefix/include" ]]; then
    printf 'error: dependency prefix include directory is missing: %s/include\n' "$dependency_prefix" >&2
    exit 1
  fi
  if [[ ! -d "$dependency_prefix/lib" ]] && [[ ! -d "$dependency_prefix/lib64" ]]; then
    printf 'error: dependency prefix library directories are missing: %s\n' "$dependency_prefix" >&2
    exit 1
  fi
fi

build_glibc="$(getconf GNU_LIBC_VERSION)"
build_glibc="${build_glibc#glibc }"
gcc_version="$(gcc -dumpfullversion -dumpversion)"
gxx_version="$(g++ -dumpfullversion -dumpversion)"
gfortran_version="$(gfortran -dumpfullversion -dumpversion)"
if [[ -n "$expected_build_glibc" ]] && [[ "$build_glibc" != "$expected_build_glibc" ]]; then
  printf 'error: expected build glibc %s, found %s\n' "$expected_build_glibc" "$build_glibc" >&2
  exit 1
fi
if [[ -n "$expected_gcc_major" ]]; then
  for compiler_version in "$gcc_version" "$gxx_version" "$gfortran_version"; do
    if [[ "${compiler_version%%.*}" != "$expected_gcc_major" ]]; then
      printf 'error: expected compiler major %s, found %s\n' "$expected_gcc_major" "$compiler_version" >&2
      exit 1
    fi
  done
fi

if [[ ! -x "$source_dir/configure" ]]; then
  printf 'error: GNU Octave configure script is missing: %s/configure\n' "$source_dir" >&2
  exit 1
fi

# Configure through a stable source-tree alias.  Autoconf records the source
# auxiliary directory in fallback tool commands such as "build-aux/missing
# flex", and Octave embeds those configured build variables in liboctinterp.
# Keep the real source path for the forbidden-prefix audit while ensuring any
# configured source references use the same deterministic prefix as compiler
# file-prefix mapping.
canonical_source_dir="/usr/src/octave-$OCTAVE_VERSION"
if [[ -e "$canonical_source_dir" ]] || [[ -L "$canonical_source_dir" ]]; then
  canonical_source_target="$(realpath "$canonical_source_dir" 2>/dev/null || true)"
  if [[ "$canonical_source_target" != "$source_dir" ]]; then
    printf 'error: canonical source path already exists with a different target: %s\n' \
      "$canonical_source_dir" >&2
    exit 1
  fi
else
  mkdir -p "$(dirname "$canonical_source_dir")"
  ln -s "$source_dir" "$canonical_source_dir"
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
probe_dir="$build_dir/probe"
mkdir -p "$object_dir" "$probe_dir"

configure_args=(
  "--prefix=$CONFIGURED_PREFIX"
  "--srcdir=$canonical_source_dir"
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

configure_flags="-O2 -g0 -fPIC"
compile_flags="$configure_flags \
-ffile-prefix-map=$source_dir=$canonical_source_dir \
-fmacro-prefix-map=$source_dir=$canonical_source_dir \
-fdebug-prefix-map=$source_dir=$canonical_source_dir \
-ffile-prefix-map=$build_dir=/usr/src/octave-build \
-fmacro-prefix-map=$build_dir=/usr/src/octave-build \
-fdebug-prefix-map=$build_dir=/usr/src/octave-build"
export CFLAGS="$configure_flags"
export CXXFLAGS="$configure_flags"
export FFLAGS="$configure_flags"
export FCFLAGS="$configure_flags"
if [[ -n "$dependency_prefix" ]]; then
  dependency_cppflags="-I$dependency_prefix/include"
  if [[ -d "$dependency_prefix/include/suitesparse" ]]; then
    dependency_cppflags="$dependency_cppflags -I$dependency_prefix/include/suitesparse"
  fi
  export CPPFLAGS="$dependency_cppflags"
  export LDFLAGS="-L$dependency_prefix/lib -L$dependency_prefix/lib64 -Wl,-rpath-link,$dependency_prefix/lib -Wl,-rpath-link,$dependency_prefix/lib64"
  export PKG_CONFIG_PATH="$dependency_prefix/lib/pkgconfig:$dependency_prefix/lib64/pkgconfig:$dependency_prefix/share/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
  export LD_LIBRARY_PATH="$dependency_prefix/lib:$dependency_prefix/lib64:${LD_LIBRARY_PATH:-}"
  export BLAS_LIBS="-lopenblas"
  export LAPACK_LIBS="-lopenblas"
else
  export CPPFLAGS="${CPPFLAGS:-} -I/usr/include/hdf5/serial -I/usr/include/suitesparse"
  export LDFLAGS="${LDFLAGS:-} -L/usr/lib/x86_64-linux-gnu/hdf5/serial"
fi
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1780272000}"
export TZ="UTC"
export LANG="C"
export LC_ALL="C"
export PYTHON="$python_command"

printf 'octave_version=%s\n' "$OCTAVE_VERSION"
printf 'build_image=%s\n' "$build_image"
printf 'glibc_baseline=%s\n' "$glibc_baseline"
printf 'build_glibc=%s\n' "$build_glibc"
printf 'gcc_version=%s\n' "$gcc_version"
printf 'gxx_version=%s\n' "$gxx_version"
printf 'gfortran_version=%s\n' "$gfortran_version"
printf 'python=%s\n' "$(command -v "$python_command")"
"$python_command" --version
printf 'dependency_prefix=%s\n' "${dependency_prefix:-none}"
printf 'source_dir=%s\n' "$source_dir"
printf 'canonical_source_dir=%s\n' "$canonical_source_dir"
printf 'build_dir=%s\n' "$build_dir"
printf 'destination=%s\n' "$destination"

pushd "$object_dir" >/dev/null
"$canonical_source_dir/configure" "${configure_args[@]}" 2>&1 | tee "$build_dir/configure.out"
make -j"$jobs" \
  CFLAGS="$compile_flags" \
  CXXFLAGS="$compile_flags" \
  FFLAGS="$compile_flags" \
  FCFLAGS="$compile_flags"

install_root="$CONFIGURED_PREFIX"
if [[ -e "$install_root" ]]; then
  printf 'error: configured install prefix already exists: %s\n' "$install_root" >&2
  exit 1
fi
if [[ ! -w "$(dirname "$install_root")" ]]; then
  printf 'error: configured install prefix parent is not writable: %s\n' "$(dirname "$install_root")" >&2
  exit 1
fi
make install
popd >/dev/null

if [[ ! -x "$install_root/bin/octave-cli" ]]; then
  printf 'error: installed octave-cli is missing: %s/bin/octave-cli\n' "$install_root" >&2
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
if [[ -n "$dependency_prefix" ]]; then
  install_ld_path="$install_ld_path:$dependency_prefix/lib:$dependency_prefix/lib64"
fi
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  install_ld_path="$install_ld_path:$LD_LIBRARY_PATH"
fi
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
rm -rf "$install_root"

# Ship the qualification MEX with the runtime so the exact archived payload can
# exercise MEX loading again in clean compatibility containers.
qualification_dir="$destination/share/featool/qualification"
mkdir -p "$qualification_dir"
cp "$probe_dir/octave_runtime_mex_probe.mex" \
  "$qualification_dir/octave_runtime_mex_probe.mex"

# Keep interpreter runtime content and remove development/documentation surfaces.
rm -rf \
  "$destination/include" \
  "$destination/share/doc" \
  "$destination/share/info" \
  "$destination/share/man" \
  "$destination/share/applications" \
  "$destination/share/icons" \
  "$destination/share/metainfo" \
  "$destination/share/octave/$OCTAVE_VERSION/doc" \
  "$destination/share/octave/$OCTAVE_VERSION/etc/tests" \
  "$destination/share/octave/$OCTAVE_VERSION/fonts" \
  "$destination/share/octave/$OCTAVE_VERSION/locale"
rm -f \
  "$destination/share/octave/$OCTAVE_VERSION/etc/CITATION" \
  "$destination/share/octave/$OCTAVE_VERSION/etc/NEWS"
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
if [ -z "${CURLOPT_CAINFO:-}" ] && [ -z "${CURLOPT_CAPATH:-}" ]; then
  for candidate in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/ca-bundle.pem
  do
    if [ -r "$candidate" ]; then
      export CURLOPT_CAINFO="$candidate"
      break
    fi
  done
fi
exec "$runtime_root/bin/octave-cli" --no-window-system --no-init-all "$@"
EOF
chmod 0755 "$destination/bin/featool-octave"

runtime_prepare_args=(
  "$runtime_tool" prepare
  --runtime-root "$destination" \
  --source-archive "$source_archive" \
  --source-sha256 "$source_sha256" \
  --configured-prefix "$CONFIGURED_PREFIX" \
  --build-image "$build_image" \
  --glibc-baseline "$glibc_baseline" \
  --configure-args-file "$build_dir/configure-args.txt" \
  --octave-source-prefix "$source_dir" \
  --forbidden-prefix "$source_dir" \
  --forbidden-prefix "$build_dir" \
  --qualification-elf "$qualification_dir/octave_runtime_mex_probe.mex"
)
if [[ -n "$dependency_prefix" ]]; then
  runtime_prepare_args+=(--dependency-prefix "$dependency_prefix")
fi
"$python_command" "${runtime_prepare_args[@]}"

if [[ "$validate" -eq 1 ]]; then
  validation_home="$build_dir/validation-home"
  mkdir -p "$validation_home"
  runtime_launcher="$destination/bin/featool-octave"
  octave_probe_dir="${qualification_dir//\\//}"
  octave_probe_dir="${octave_probe_dir//\'/\'\'}"
  eval_code="assert(strcmp(OCTAVE_VERSION,'11.3.0')); A=sparse([4 -1;-1 4]); b=[1;2]; x=A\\b; assert(norm(A*x-b)<1e-12); e=eigs(sparse(diag(1:5)),1); assert(abs(e-5)<1e-8); f=fft([1 2 3 4]); assert(numel(f)==4); p=[0 0;1 0;0 1;1 1]; k=convhull(p(:,1),p(:,2)); assert(numel(k)>=4); t=delaunay(p(:,1),p(:,2)); assert(rows(t)>=2); fn=[tempname() '.h5']; q=magic(3); save('-hdf5',fn,'q'); clear q; load(fn); assert(isequal(q,magic(3))); unlink(fn); fn=tempname(); fid=fopen(fn,'w'); fputs(fid,'curl-ok'); fclose(fid); txt=urlread(['file://' fn]); unlink(fn); assert(strcmp(strtrim(txt),'curl-ok')); assert(~isempty(jsonencode(struct('a',1)))); disp('LINUX_NUMERICAL_RUNTIME=pass');"
  env -i \
    HOME="$validation_home" \
    PATH="/usr/bin:/bin" \
    LANG="C" \
    LC_ALL="C" \
    "$runtime_launcher" --quiet --eval "$eval_code"

  mex_eval="addpath('$octave_probe_dir'); y=octave_runtime_mex_probe(41); assert(y==42); disp('LINUX_MEX_RUNTIME=pass');"
  env -i \
    HOME="$validation_home" \
    PATH="/usr/bin:/bin" \
    LANG="C" \
    LC_ALL="C" \
    "$runtime_launcher" --quiet --eval "$mex_eval"

  tls_probe_dir="$build_dir/tls-probe"
  mkdir -p "$tls_probe_dir"
  if [[ -n "$dependency_prefix" ]]; then
    openssl_command="$dependency_prefix/bin/openssl"
    openssl_env="$dependency_prefix/lib:$dependency_prefix/lib64:${LD_LIBRARY_PATH:-}"
    if [[ ! -x "$openssl_command" ]]; then
      printf 'error: HTTPS validation requires the private OpenSSL command: %s\n' "$openssl_command" >&2
      exit 1
    fi
  else
    openssl_command="$(command -v openssl || true)"
    openssl_env="${LD_LIBRARY_PATH:-}"
    if [[ -z "$openssl_command" ]]; then
      printf 'error: HTTPS validation requires an OpenSSL command\n' >&2
      exit 1
    fi
  fi
  cat > "$tls_probe_dir/openssl.cnf" <<'EOF'
[req]
distinguished_name=req_dn
prompt=no

[req_dn]
CN=placeholder
EOF
  env LD_LIBRARY_PATH="$openssl_env" "$openssl_command" req \
    -x509 -newkey rsa:2048 -nodes \
    -config "$tls_probe_dir/openssl.cnf" \
    -keyout "$tls_probe_dir/ca.key" \
    -out "$tls_probe_dir/ca.crt" \
    -subj '/CN=FEATool Runtime Test CA' \
    -days 1
  env LD_LIBRARY_PATH="$openssl_env" "$openssl_command" req \
    -newkey rsa:2048 -nodes \
    -config "$tls_probe_dir/openssl.cnf" \
    -keyout "$tls_probe_dir/server.key" \
    -out "$tls_probe_dir/server.csr" \
    -subj '/CN=localhost'
  cat > "$tls_probe_dir/server.ext" <<'EOF'
subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EOF
  env LD_LIBRARY_PATH="$openssl_env" "$openssl_command" x509 \
    -req \
    -in "$tls_probe_dir/server.csr" \
    -CA "$tls_probe_dir/ca.crt" \
    -CAkey "$tls_probe_dir/ca.key" \
    -CAcreateserial \
    -out "$tls_probe_dir/server.crt" \
    -days 1 \
    -extfile "$tls_probe_dir/server.ext"

  cat > "$tls_probe_dir/https_server.py" <<'PY'
import http.server
from pathlib import Path
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"https-ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


certificate, private_key, port_file = sys.argv[1:4]
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate, private_key)
server.socket = context.wrap_socket(server.socket, server_side=True)
Path(port_file).write_text(str(server.server_address[1]), encoding="ascii")
server.serve_forever()
PY

  # The manylinux Python distribution carries its own OpenSSL runtime.  Do not
  # let the private Octave dependency prefix interpose its libcrypto/libssl on
  # Python's _ssl extension while the local qualification server is running.
  env -u LD_LIBRARY_PATH "$python_command" "$tls_probe_dir/https_server.py" \
    "$tls_probe_dir/server.crt" \
    "$tls_probe_dir/server.key" \
    "$tls_probe_dir/port" \
    > "$tls_probe_dir/server.log" 2>&1 &
  tls_server_pid=$!
  cleanup_tls_server() {
    kill "$tls_server_pid" >/dev/null 2>&1 || true
    wait "$tls_server_pid" >/dev/null 2>&1 || true
  }
  trap cleanup_tls_server EXIT
  for _ in $(seq 1 100); do
    if [[ -s "$tls_probe_dir/port" ]]; then
      break
    fi
    if ! kill -0 "$tls_server_pid" >/dev/null 2>&1; then
      cat "$tls_probe_dir/server.log" >&2 || true
      printf 'error: local HTTPS validation server exited early\n' >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ ! -s "$tls_probe_dir/port" ]]; then
    printf 'error: local HTTPS validation server did not publish a port\n' >&2
    exit 1
  fi
  tls_port="$(cat "$tls_probe_dir/port")"
  https_eval="txt=urlread('https://localhost:$tls_port/'); assert(strcmp(strtrim(txt),'https-ok')); disp('LINUX_HTTPS_RUNTIME=pass');"
  env -i \
    HOME="$validation_home" \
    PATH="/usr/bin:/bin" \
    LANG="C" \
    LC_ALL="C" \
    CURLOPT_CAINFO="$tls_probe_dir/ca.crt" \
    "$runtime_launcher" --quiet --eval "$https_eval"
  cleanup_tls_server
  trap - EXIT

  "$python_command" "$runtime_tool" verify \
    --runtime-root "$destination" \
    --expected-profile "$PROFILE" \
    --smoke
fi

printf 'build=pass\n'
