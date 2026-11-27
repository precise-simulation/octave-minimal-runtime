#!/usr/bin/env bash
set -euo pipefail

EXPECTED_GLIBC="2.17"
EXPECTED_GCC_MAJOR="10"

usage() {
  cat <<'EOF'
Usage: build_manylinux_deps.sh \
  --source-dir DIR --lock-file FILE --prefix DIR --work-dir DIR \
  --evidence-dir DIR [--jobs N]

Build the pinned native dependency stack for the FEATool GNU Octave runtime.
Source archives must already exist in --source-dir and match the SHA-256 values
in --lock-file.  This script does not download source code.
EOF
}

source_dir=""
lock_file=""
prefix=""
work_dir=""
evidence_dir=""
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir) source_dir="$2"; shift 2 ;;
    --lock-file) lock_file="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --work-dir) work_dir="$2"; shift 2 ;;
    --evidence-dir) evidence_dir="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for required_name in source_dir lock_file prefix work_dir evidence_dir; do
  if [[ -z "${!required_name}" ]]; then
    printf 'error: --%s is required\n' "${required_name//_/-}" >&2
    usage >&2
    exit 2
  fi
done

for command_name in bash cmake gcc g++ gfortran getconf ld make objdump patchelf perl pkg-config readelf realpath sha256sum tar xz; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

source_dir="$(realpath "$source_dir")"
lock_file="$(realpath "$lock_file")"
prefix="$(realpath -m "$prefix")"
work_dir="$(realpath -m "$work_dir")"
evidence_dir="$(realpath -m "$evidence_dir")"

if [[ ! -d "$source_dir" ]]; then
  printf 'error: source directory is missing: %s\n' "$source_dir" >&2
  exit 1
fi
if [[ ! -f "$lock_file" ]]; then
  printf 'error: dependency lock is missing: %s\n' "$lock_file" >&2
  exit 1
fi
if [[ -e "$prefix" ]] && [[ -n "$(find "$prefix" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  printf 'error: dependency prefix must be empty: %s\n' "$prefix" >&2
  exit 1
fi
if [[ -e "$work_dir" ]] && [[ -n "$(find "$work_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  printf 'error: work directory must be empty: %s\n' "$work_dir" >&2
  exit 1
fi

mkdir -p "$prefix" "$work_dir" "$evidence_dir"

glibc_version="$(getconf GNU_LIBC_VERSION)"
glibc_version="${glibc_version#glibc }"
gcc_version="$(gcc -dumpfullversion -dumpversion)"
if [[ "$glibc_version" != "$EXPECTED_GLIBC" ]]; then
  printf 'error: expected glibc %s, found %s\n' "$EXPECTED_GLIBC" "$glibc_version" >&2
  exit 1
fi
if [[ "${gcc_version%%.*}" != "$EXPECTED_GCC_MAJOR" ]]; then
  printf 'error: expected GCC major %s, found %s\n' "$EXPECTED_GCC_MAJOR" "$gcc_version" >&2
  exit 1
fi

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1780272000}"
export TZ=UTC
export LC_ALL=C
export LANG=C
export PATH="$prefix/bin:$PATH"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:$prefix/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export CPPFLAGS="-I$prefix/include"
export LDFLAGS="-L$prefix/lib -L$prefix/lib64 -Wl,-rpath-link,$prefix/lib -Wl,-rpath-link,$prefix/lib64"
export CFLAGS="-O2 -g0 -fPIC -ffile-prefix-map=$work_dir=/usr/src/featool-deps"
export CXXFLAGS="$CFLAGS"
export FFLAGS="$CFLAGS"
export FCFLAGS="$CFLAGS"
export CC=gcc
export CXX=g++
export FC=gfortran
export F77=gfortran
export LD_LIBRARY_PATH="$prefix/lib:$prefix/lib64:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$prefix"

declare -A dep_version dep_filename dep_sha256 dep_url
while IFS=$'\t' read -r name version filename digest url; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  dep_version["$name"]="$version"
  dep_filename["$name"]="$filename"
  dep_sha256["$name"]="$digest"
  dep_url["$name"]="$url"
done < "$lock_file"

dependencies=(
  zlib openssl ncurses readline pcre2 hdf5 qhull libtool rapidjson fast-float
  openblas fftw suitesparse arpack-ng curl
)

for name in "${dependencies[@]}"; do
  if [[ -z "${dep_filename[$name]:-}" ]]; then
    printf 'error: dependency is missing from lock: %s\n' "$name" >&2
    exit 1
  fi
  archive="$source_dir/${dep_filename[$name]}"
  if [[ ! -f "$archive" ]]; then
    printf 'error: source archive is missing: %s\n' "$archive" >&2
    exit 1
  fi
  printf '%s  %s\n' "${dep_sha256[$name]}" "$archive" | sha256sum --check --strict
done

{
  printf 'glibc=%s\n' "$glibc_version"
  gcc --version | sed -n '1p'
  g++ --version | sed -n '1p'
  gfortran --version | sed -n '1p'
  ld --version | sed -n '1p'
  cmake --version | sed -n '1p'
  make --version | sed -n '1p'
  perl -v | sed -n '2p'
  pkg-config --version | sed 's/^/pkg-config /'
} | tee "$evidence_dir/toolchain.txt"
cp "$lock_file" "$evidence_dir/manylinux-deps.lock"

printf 'name\tversion\tsha256\turl\n' > "$evidence_dir/dependencies.tsv"
for name in "${dependencies[@]}"; do
  printf '%s\t%s\t%s\t%s\n' \
    "$name" "${dep_version[$name]}" "${dep_sha256[$name]}" "${dep_url[$name]}" \
    >> "$evidence_dir/dependencies.tsv"
done

extract_source() {
  local name="$1"
  local destination="$work_dir/src/$name"
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xf "$source_dir/${dep_filename[$name]}" -C "$destination" --strip-components=1
  printf '%s\n' "$destination"
}

source_root_with_file() {
  local root="$1"
  local relative_file="$2"
  if [[ -f "$root/$relative_file" ]]; then
    printf '%s\n' "$root"
    return 0
  fi

  local best=""
  local best_depth=""
  local best_count=0
  while IFS= read -r candidate; do
    local parent="${candidate%/$relative_file}"
    local relative="${parent#"$root"/}"
    local separators="${relative//[^\/]/}"
    local depth=$(( ${#separators} + 1 ))
    if [[ -z "$best_depth" ]] || (( depth < best_depth )); then
      best="$parent"
      best_depth="$depth"
      best_count=1
    elif (( depth == best_depth )); then
      best_count=$((best_count + 1))
    fi
  done < <(find "$root" -mindepth 2 -maxdepth 4 -type f -path "*/$relative_file" -print | LC_ALL=C sort)

  if [[ -z "$best" ]] || [[ "$best_count" -ne 1 ]]; then
    printf 'error: expected one shallowest %s below %s, found %s at the shallowest depth\n' \
      "$relative_file" "$root" "$best_count" >&2
    find "$root" -mindepth 1 -maxdepth 3 -type d -print | LC_ALL=C sort >&2
    return 1
  fi
  printf '%s\n' "$best"
}

record_command() {
  local name="$1"
  shift
  {
    printf 'dependency=%s\n' "$name"
    printf 'version=%s\n' "${dep_version[$name]}"
    printf 'command='
    printf '%q ' "$@"
    printf '\n'
  } >> "$evidence_dir/build-commands.txt"
}

cmake_build_install() {
  local name="$1"
  local src="$2"
  shift 2
  local build="$work_dir/build/$name"
  mkdir -p "$build"
  local command=(
    cmake -S "$src" -B "$build"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_PREFIX_PATH="$prefix"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_SKIP_INSTALL_RPATH=ON
    "$@"
  )
  record_command "$name" "${command[@]}"
  "${command[@]}"
  cmake --build "$build" --parallel "$jobs"
  cmake --install "$build"
}

build_zlib() {
  local src
  src="$(extract_source zlib)"
  pushd "$src" >/dev/null
  record_command zlib ./configure --prefix="$prefix"
  ./configure --prefix="$prefix"
  make -j"$jobs"
  make install
  popd >/dev/null
}

build_openssl() {
  local src
  src="$(extract_source openssl)"
  pushd "$src" >/dev/null
  record_command openssl ./Configure linux-x86_64 shared --prefix="$prefix" --libdir=lib --openssldir=/etc/ssl no-tests no-legacy no-autoload-config
  ./Configure linux-x86_64 shared \
    --prefix="$prefix" --libdir=lib --openssldir=/etc/ssl \
    no-tests no-legacy no-autoload-config
  make -j"$jobs"
  make install_sw
  popd >/dev/null
}

build_ncurses() {
  local src
  src="$(extract_source ncurses)"
  pushd "$src" >/dev/null
  local base_command=(
    ./configure --prefix="$prefix" --with-shared --without-normal --without-debug
    --without-tests --without-ada --without-cxx --without-cxx-binding --without-gpm
    --enable-widec --enable-overwrite --with-termlib --enable-pc-files
    --with-pkg-config-libdir="$prefix/lib/pkgconfig"
  )
  record_command ncurses "${base_command[@]}"
  "${base_command[@]}"
  make -j"$jobs"
  make install

  # The CentOS 7 tic bundled in manylinux2014 is too old to compile all current
  # ncurses 6.5 fallback entries.  Bootstrap the matching tic/infocmp first,
  # then rebuild ncurses with those tools so fallback data is compiled into the
  # shared libraries rather than depending on a target-host terminfo database.
  make distclean
  local fallback_command=(
    "${base_command[@]}"
    --with-fallbacks=xterm,xterm-256color,screen,screen-256color,tmux,vt100,linux,dumb
    --with-tic-path="$prefix/bin/tic"
    --with-infocmp-path="$prefix/bin/infocmp"
  )
  record_command ncurses "${fallback_command[@]}"
  "${fallback_command[@]}"
  make -j"$jobs"
  make install
  popd >/dev/null
}

build_readline() {
  local src
  src="$(extract_source readline)"
  pushd "$src" >/dev/null
  record_command readline ./configure --prefix="$prefix" --enable-shared --disable-static --with-curses --with-shared-termcap-library
  ./configure --prefix="$prefix" --enable-shared --disable-static --with-curses --with-shared-termcap-library
  make -j"$jobs" SHLIB_LIBS="-L$prefix/lib -ltinfow"
  make install SHLIB_LIBS="-L$prefix/lib -ltinfow"
  popd >/dev/null
}

build_pcre2() {
  local src
  src="$(extract_source pcre2)"
  pushd "$src" >/dev/null
  local command=(
    ./configure --prefix="$prefix" --enable-shared --disable-static
    --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --enable-unicode --enable-jit
  )
  record_command pcre2 "${command[@]}"
  "${command[@]}"
  make -j"$jobs"
  make install
  popd >/dev/null
}

build_openblas() {
  local src
  src="$(extract_source openblas)"
  pushd "$src" >/dev/null
  local options=(
    CC=gcc CXX=g++ FC=gfortran HOSTCC=gcc BINARY=64 TARGET=GENERIC
    DYNAMIC_ARCH=1 DYNAMIC_OLDER=1 NUM_THREADS=64 USE_THREAD=1 USE_OPENMP=0
    NO_AFFINITY=1 USE_TLS=0 INTERFACE64=0 CONSISTENT_FPCSR=1 NO_STATIC=1
    COMMON_OPT="$CFLAGS"
  )
  record_command openblas make "${options[@]}" shared
  make -j"$jobs" "${options[@]}" shared
  make PREFIX="$prefix" "${options[@]}" install
  popd >/dev/null
}

build_fftw_variant() {
  local variant="$1"
  local src="$2"
  local build="$work_dir/build/fftw-$variant"
  mkdir -p "$build"
  pushd "$build" >/dev/null
  local command=(
    "$src/configure" --prefix="$prefix" --enable-shared --disable-static
    --enable-threads --disable-openmp --disable-mpi --disable-fortran --enable-sse2
  )
  if [[ "$variant" == "float" ]]; then
    command+=(--enable-float)
  fi
  record_command fftw "${command[@]}"
  "${command[@]}"
  make -j"$jobs"
  make install
  popd >/dev/null
}

build_fftw() {
  local src
  src="$(extract_source fftw)"
  build_fftw_variant double "$src"
  build_fftw_variant float "$src"
}

build_hdf5() {
  local src build
  src="$(extract_source hdf5)"
  src="$(source_root_with_file "$src" configure)"
  build="$work_dir/build/hdf5"
  mkdir -p "$build"
  pushd "$build" >/dev/null
  local command=(
    "$src/configure" --prefix="$prefix" --enable-shared --disable-static
    --disable-fortran --disable-cxx --with-zlib="$prefix"
  )
  record_command hdf5 "${command[@]}"
  "${command[@]}"

  # HDF5 generates both installed settings text and a C source that embeds the
  # same configure timestamp, container hostname, and runner kernel in
  # libhdf5.so.  Normalize only those volatile fields before compilation.
  local settings_file="$build/src/libhdf5.settings"
  local build_settings_source="$build/src/H5build_settings.c"
  for generated_file in "$settings_file" "$build_settings_source"; do
    if [[ ! -f "$generated_file" ]]; then
      printf 'error: HDF5 configure did not produce settings file: %s\n' "$generated_file" >&2
      exit 1
    fi
  done
  HDF5_SETTINGS_FILE="$settings_file" \
    HDF5_BUILD_SETTINGS_SOURCE="$build_settings_source" \
    perl -e '
    use strict;
    use warnings;

    sub read_file {
      my ($path) = @_;
      open my $input, "<", $path or die "cannot read $path: $!\n";
      local $/;
      my $text = <$input>;
      close $input or die "cannot close $path after read: $!\n";
      return $text;
    }

    sub write_file {
      my ($path, $text) = @_;
      open my $output, ">", $path or die "cannot write $path: $!\n";
      print {$output} $text;
      close $output or die "cannot close $path after write: $!\n";
    }

    my $settings_path = $ENV{HDF5_SETTINGS_FILE};
    my $settings = read_file($settings_path);
    my $settings_count = 0;
    $settings_count += ($settings =~ s/^[ \t]*Configured on:.*$/                  Configured on: SOURCE_DATE_EPOCH=$ENV{SOURCE_DATE_EPOCH}/m);
    $settings_count += ($settings =~ s/^[ \t]*Configured by:.*$/                  Configured by: featool-manylinux/m);
    $settings_count += ($settings =~ s/^[ \t]*Uname information:.*$/              Uname information: manylinux2014_x86_64/m);
    die "expected three volatile fields in $settings_path, replaced $settings_count\n"
      unless $settings_count == 3;
    write_file($settings_path, $settings);

    my $source_path = $ENV{HDF5_BUILD_SETTINGS_SOURCE};
    my $source = read_file($source_path);
    my $source_count = 0;
    $source_count += ($source =~ s/^[ \t]*"[ \t]*Configured on:.*\\n"$/    "                  Configured on: SOURCE_DATE_EPOCH=$ENV{SOURCE_DATE_EPOCH}\\n"/m);
    $source_count += ($source =~ s/^[ \t]*"[ \t]*Configured by:.*\\n"$/    "                  Configured by: featool-manylinux\\n"/m);
    $source_count += ($source =~ s/^[ \t]*"[ \t]*Uname information:.*\\n"$/    "              Uname information: manylinux2014_x86_64\\n"/m);
    die "expected three volatile fields in $source_path, replaced $source_count\n"
      unless $source_count == 3;
    write_file($source_path, $source);
  '
  cp "$settings_file" "$evidence_dir/hdf5-lib-settings.txt"
  cp "$build_settings_source" "$evidence_dir/hdf5-build-settings.c"

  make -j"$jobs"
  make install
  popd >/dev/null
}

build_suitesparse() {
  local src
  src="$(extract_source suitesparse)"
  cmake_build_install suitesparse "$src" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DSUITESPARSE_ENABLE_PROJECTS='suitesparse_config;amd;btf;camd;ccolamd;colamd;cholmod;cxsparse;klu;umfpack;spqr' \
    -DSUITESPARSE_USE_CUDA=OFF \
    -DSUITESPARSE_USE_OPENMP=OFF \
    -DSUITESPARSE_USE_PYTHON=OFF \
    -DSUITESPARSE_USE_64BIT_BLAS=OFF \
    -DSUITESPARSE_USE_STRICT=ON \
    -DCHOLMOD_PARTITION=OFF \
    -DBLA_VENDOR=OpenBLAS \
    -DBLAS_LIBRARIES="$prefix/lib/libopenblas.so" \
    -DLAPACK_LIBRARIES="$prefix/lib/libopenblas.so"
}

build_arpack_ng() {
  local src
  src="$(extract_source arpack-ng)"
  cmake_build_install arpack-ng "$src" \
    -DBUILD_SHARED_LIBS=ON \
    -DMPI=OFF \
    -DICB=OFF \
    -DINTERFACE64=OFF \
    -DPYTHON3=OFF \
    -DEXAMPLES=OFF \
    -DTESTS=OFF \
    -DBLA_VENDOR=OpenBLAS \
    -DBLAS_LIBRARIES="$prefix/lib/libopenblas.so" \
    -DLAPACK_LIBRARIES="$prefix/lib/libopenblas.so"
}

build_qhull() {
  local src
  src="$(extract_source qhull)"
  cmake_build_install qhull "$src" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DLINK_APPS_SHARED=ON \
    -DLIB_INSTALL_DIR=lib
}

build_libtool() {
  local src
  src="$(extract_source libtool)"
  pushd "$src" >/dev/null
  record_command libtool ./configure --prefix="$prefix" --enable-shared --disable-static --enable-ltdl-install
  ./configure --prefix="$prefix" --enable-shared --disable-static --enable-ltdl-install
  make -j"$jobs"
  make install
  popd >/dev/null
}

build_rapidjson() {
  local src
  src="$(extract_source rapidjson)"
  mkdir -p "$prefix/include"
  cp -a "$src/include/rapidjson" "$prefix/include/"
  record_command rapidjson cp -a include/rapidjson "$prefix/include/"
}

build_fast_float() {
  local src
  src="$(extract_source fast-float)"
  mkdir -p "$prefix/include"
  cp -a "$src/include/fast_float" "$prefix/include/"
  record_command fast-float cp -a include/fast_float "$prefix/include/"
}

build_curl() {
  local src
  src="$(extract_source curl)"
  cmake_build_install curl "$src" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_LIBCURL_DOCS=OFF \
    -DBUILD_MISC_DOCS=OFF \
    -DCURL_USE_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DCURL_ZLIB=ON \
    -DZLIB_ROOT="$prefix" \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_USE_LIBSSH2=OFF \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DUSE_LIBIDN2=OFF \
    -DUSE_NGHTTP2=OFF \
    -DUSE_NGTCP2=OFF \
    -DUSE_QUICHE=OFF \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_DICT=ON \
    -DCURL_DISABLE_TELNET=ON \
    -DCURL_DISABLE_TFTP=ON \
    -DCURL_DISABLE_POP3=ON \
    -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_SMTP=ON \
    -DCURL_DISABLE_GOPHER=ON \
    -DCURL_DISABLE_MQTT=ON \
    -DCURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG=ON \
    -DCURL_CA_BUNDLE=none \
    -DCURL_CA_PATH=none
}

build_one() {
  local name="$1"
  printf 'dependency_build_start=%s version=%s\n' "$name" "${dep_version[$name]}"
  case "$name" in
    zlib) build_zlib ;;
    openssl) build_openssl ;;
    ncurses) build_ncurses ;;
    readline) build_readline ;;
    pcre2) build_pcre2 ;;
    openblas) build_openblas ;;
    fftw) build_fftw ;;
    hdf5) build_hdf5 ;;
    suitesparse) build_suitesparse ;;
    arpack-ng) build_arpack_ng ;;
    qhull) build_qhull ;;
    libtool) build_libtool ;;
    rapidjson) build_rapidjson ;;
    fast-float) build_fast_float ;;
    curl) build_curl ;;
    *) printf 'error: no builder for dependency: %s\n' "$name" >&2; return 1 ;;
  esac
  printf 'dependency_build_pass=%s\n' "$name"
}

for name in "${dependencies[@]}"; do
  build_one "$name" 2>&1 | tee "$evidence_dir/build-$name.log"
done

find "$prefix" -type f \( -name '*.a' -o -name '*.la' \) -delete

# Some Autotools projects install helper executables with the configure-time
# prefix embedded as RPATH.  The dependency prefix is archived on the Ubuntu
# host and later remounted at /opt/featool-deps for the Octave build, so those
# absolute paths would make the intermediate artifact location-dependent.  The
# Octave builder already supplies the prefix libraries through LD_LIBRARY_PATH;
# remove only loader paths that point back into this build prefix or work tree.
: > "$evidence_dir/runpath-normalization.tsv"
while IFS= read -r -d '' candidate; do
  if ! readelf -h "$candidate" >/dev/null 2>&1; then
    continue
  fi
  runpath="$(patchelf --print-rpath "$candidate" 2>/dev/null || true)"
  if [[ -z "$runpath" ]]; then
    continue
  fi
  if [[ "$runpath" != *"$prefix"* && "$runpath" != *"$work_dir"* ]]; then
    continue
  fi
  relative="${candidate#"$prefix"/}"
  printf '%s\t%s\n' "$relative" "$runpath" >> "$evidence_dir/runpath-normalization.tsv"
  patchelf --remove-rpath "$candidate"
done < <(find "$prefix" -type f -print0)

: > "$evidence_dir/elf-abi.tsv"
: > "$evidence_dir/elf-needed.tsv"
max_glibc=""
max_glibcxx=""
max_cxxabi=""
max_gcc=""
while IFS= read -r -d '' candidate; do
  if ! readelf -h "$candidate" >/dev/null 2>&1; then
    continue
  fi
  relative="${candidate#"$prefix"/}"
  dynamic="$(readelf -d --wide "$candidate" 2>/dev/null || true)"
  if grep -q 'Shared library: \[libmvec\.so\.1\]' <<< "$dynamic"; then
    printf 'error: dependency prefix contains libmvec dependency: %s\n' "$relative" >&2
    exit 1
  fi
  if grep -E 'Library (rpath|runpath): \[.*(/opt/featool-deps|/work)' <<< "$dynamic" >/dev/null; then
    printf 'error: dependency prefix contains build-path RPATH/RUNPATH: %s\n' "$relative" >&2
    grep -E 'Library (rpath|runpath):' <<< "$dynamic" >&2 || true
    exit 1
  fi
  while IFS= read -r needed; do
    [[ -z "$needed" ]] && continue
    printf '%s\t%s\n' "$relative" "$needed" >> "$evidence_dir/elf-needed.tsv"
  done < <(sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' <<< "$dynamic")
  required="$(
    objdump -T "$candidate" 2>/dev/null \
      | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
      | sed 's/^GLIBC_//' \
      | sort -Vu \
      | tail -n 1 \
      || true
  )"
  required_glibcxx="$(objdump -T "$candidate" 2>/dev/null | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBCXX_//' | sort -Vu | tail -n 1 || true)"
  required_cxxabi="$(objdump -T "$candidate" 2>/dev/null | grep -oE 'CXXABI_[0-9]+(\.[0-9]+)+' | sed 's/^CXXABI_//' | sort -Vu | tail -n 1 || true)"
  required_gcc="$(objdump -T "$candidate" 2>/dev/null | grep -oE 'GCC_[0-9]+(\.[0-9]+)+' | sed 's/^GCC_//' | sort -Vu | tail -n 1 || true)"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$relative" "${required:-none}" "${required_glibcxx:-none}" \
    "${required_cxxabi:-none}" "${required_gcc:-none}" \
    >> "$evidence_dir/elf-abi.tsv"
  if [[ -n "$required" ]]; then
    if [[ -z "$max_glibc" ]] || [[ "$(printf '%s\n%s\n' "$max_glibc" "$required" | sort -V | tail -n 1)" == "$required" ]]; then
      max_glibc="$required"
    fi
  fi
  for family in glibcxx cxxabi gcc; do
    case "$family" in
      glibcxx) value="$required_glibcxx" ;;
      cxxabi) value="$required_cxxabi" ;;
      gcc) value="$required_gcc" ;;
    esac
    [[ -z "$value" ]] && continue
    current_name="max_$family"
    current="${!current_name}"
    if [[ -z "$current" ]] || [[ "$(printf '%s\n%s\n' "$current" "$value" | sort -V | tail -n 1)" == "$value" ]]; then
      printf -v "$current_name" '%s' "$value"
    fi
  done
done < <(find "$prefix" -type f -print0)

if [[ -n "$max_glibc" ]] && [[ "$(printf '%s\n%s\n' "$EXPECTED_GLIBC" "$max_glibc" | sort -V | tail -n 1)" != "$EXPECTED_GLIBC" ]]; then
  printf 'error: dependency prefix requires GLIBC_%s, exceeding GLIBC_%s\n' "$max_glibc" "$EXPECTED_GLIBC" >&2
  exit 1
fi

{
  printf 'max_required_glibc=%s\n' "${max_glibc:-none}"
  printf 'max_required_glibcxx=%s\n' "${max_glibcxx:-none}"
  printf 'max_required_cxxabi=%s\n' "${max_cxxabi:-none}"
  printf 'max_required_gcc=%s\n' "${max_gcc:-none}"
} | tee "$evidence_dir/abi-summary.txt"
(
  cd "$prefix"
  find . -type f \( -name '*.so' -o -name '*.so.*' \) -print0 \
    | sort -z \
    | xargs -0 -r sha256sum
) > "$evidence_dir/libraries.sha256"
(
  cd "$prefix"
  find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort
) > "$evidence_dir/installed-files.txt"

printf 'dependency_prefix=%s\n' "$prefix"
printf 'dependency_glibc_max=%s\n' "${max_glibc:-none}"
printf 'dependency_build=pass\n'
