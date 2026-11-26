#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: qualify_linux_runtime.sh \
  --runtime-root DIR --work-dir DIR --https-url URL --https-ca FILE \
  [--runtime-tool FILE --python COMMAND] [--expected-profile NAME]

Qualify an already-built FEATool GNU Octave Linux runtime.  The caller supplies
a deterministic HTTPS endpoint and its CA certificate.  When --runtime-tool and
--python are provided, manifest/ELF verification runs before the runtime probes.
EOF
}

runtime_root=""
work_dir=""
https_url=""
https_ca=""
runtime_tool=""
python_command=""
expected_profile="headless-cli-featool"
check_host_ca=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-root) runtime_root="$2"; shift 2 ;;
    --work-dir) work_dir="$2"; shift 2 ;;
    --https-url) https_url="$2"; shift 2 ;;
    --https-ca) https_ca="$2"; shift 2 ;;
    --runtime-tool) runtime_tool="$2"; shift 2 ;;
    --python) python_command="$2"; shift 2 ;;
    --expected-profile) expected_profile="$2"; shift 2 ;;
    --skip-host-ca-check) check_host_ca=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for required_name in runtime_root work_dir https_url https_ca; do
  if [[ -z "${!required_name}" ]]; then
    printf 'error: --%s is required\n' "${required_name//_/-}" >&2
    usage >&2
    exit 2
  fi
done
if [[ -n "$runtime_tool" && -z "$python_command" ]] || [[ -z "$runtime_tool" && -n "$python_command" ]]; then
  printf 'error: --runtime-tool and --python must be supplied together\n' >&2
  exit 2
fi

runtime_root="$(realpath "$runtime_root")"
work_dir="$(realpath -m "$work_dir")"
https_ca="$(realpath "$https_ca")"
launcher="$runtime_root/bin/featool-octave"
mex_dir="$runtime_root/share/featool/qualification"
mex_file="$mex_dir/octave_runtime_mex_probe.mex"

if [[ ! -x "$launcher" ]]; then
  printf 'error: runtime launcher is missing: %s\n' "$launcher" >&2
  exit 1
fi
if [[ ! -f "$mex_file" ]]; then
  printf 'error: packaged MEX qualification probe is missing: %s\n' "$mex_file" >&2
  exit 1
fi
if [[ ! -f "$https_ca" ]]; then
  printf 'error: HTTPS qualification CA is missing: %s\n' "$https_ca" >&2
  exit 1
fi

rm -rf "$work_dir"
mkdir -p "$work_dir/home"

if [[ -n "$runtime_tool" ]]; then
  runtime_tool="$(realpath "$runtime_tool")"
  if [[ ! -f "$runtime_tool" ]]; then
    printf 'error: runtime verification tool is missing: %s\n' "$runtime_tool" >&2
    exit 1
  fi
  if ! command -v "$python_command" >/dev/null 2>&1; then
    printf 'error: requested Python interpreter is missing: %s\n' "$python_command" >&2
    exit 1
  fi
  "$python_command" "$runtime_tool" verify \
    --runtime-root "$runtime_root" \
    --expected-profile "$expected_profile" \
    --smoke
fi

runtime_eval="assert(strcmp(OCTAVE_VERSION,'11.3.0')); A=sparse([4 -1;-1 4]); b=[1;2]; x=A\\b; assert(norm(A*x-b)<1e-12); e=eigs(sparse(diag(1:5)),1); assert(abs(e-5)<1e-8); f=fft([1 2 3 4]); assert(numel(f)==4); p=[0 0;1 0;0 1;1 1]; k=convhull(p(:,1),p(:,2)); assert(numel(k)>=4); t=delaunay(p(:,1),p(:,2)); assert(rows(t)>=2); fn=[tempname() '.h5']; q=magic(3); save('-hdf5',fn,'q'); clear q; load(fn); assert(isequal(q,magic(3))); unlink(fn); fn=tempname(); fid=fopen(fn,'w'); fputs(fid,'curl-ok'); fclose(fid); txt=urlread(['file://' fn]); unlink(fn); assert(strcmp(strtrim(txt),'curl-ok')); assert(~isempty(jsonencode(struct('a',1)))); disp('LINUX_NUMERICAL_RUNTIME=pass');"
env -i \
  HOME="$work_dir/home" \
  PATH="/usr/bin:/bin" \
  LANG=C \
  LC_ALL=C \
  "$launcher" --quiet --eval "$runtime_eval"

mex_eval="addpath('$mex_dir'); y=octave_runtime_mex_probe(41); assert(y==42); disp('LINUX_MEX_RUNTIME=pass');"
env -i \
  HOME="$work_dir/home" \
  PATH="/usr/bin:/bin" \
  LANG=C \
  LC_ALL=C \
  "$launcher" --quiet --eval "$mex_eval"

# The launcher must discover a supported target-host CA bundle when no explicit
# curl CA override is present.  Temporarily append the workflow-local test CA to
# that exact bundle so the real HTTPS request proves the default host-CA path.
if [[ "$check_host_ca" -eq 1 ]]; then
  host_ca_bundle=""
  for candidate in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/ca-bundle.pem
  do
    if [[ -r "$candidate" && -w "$candidate" ]]; then
      host_ca_bundle="$candidate"
      break
    fi
  done
  if [[ -z "$host_ca_bundle" ]]; then
    printf 'error: no writable supported host CA bundle was found\n' >&2
    exit 1
  fi
  cp "$host_ca_bundle" "$work_dir/host-ca-backup.pem"
  restore_host_ca() {
    cp "$work_dir/host-ca-backup.pem" "$host_ca_bundle"
  }
  trap restore_host_ca EXIT
  printf '\n' >> "$host_ca_bundle"
  cat "$https_ca" >> "$host_ca_bundle"

  host_ca_eval="ca=getenv('CURLOPT_CAINFO'); assert(strcmp(ca,'$host_ca_bundle')); assert(exist(ca,'file')==2); disp(['LINUX_HOST_CA=' ca]);"
  env -i \
    HOME="$work_dir/home" \
    PATH="/usr/bin:/bin" \
    LANG=C \
    LC_ALL=C \
    "$launcher" --quiet --eval "$host_ca_eval"
fi

https_eval="txt=urlread('$https_url'); assert(strcmp(strtrim(txt),'https-ok')); disp('LINUX_HTTPS_RUNTIME=pass');"
if [[ "$check_host_ca" -eq 1 ]]; then
  env -i \
    HOME="$work_dir/home" \
    PATH="/usr/bin:/bin" \
    LANG=C \
    LC_ALL=C \
    "$launcher" --quiet --eval "$https_eval"
  restore_host_ca
  trap - EXIT
else
  env -i \
    HOME="$work_dir/home" \
    PATH="/usr/bin:/bin" \
    LANG=C \
    LC_ALL=C \
    CURLOPT_CAINFO="$https_ca" \
    "$launcher" --quiet --eval "$https_eval"
fi

printf 'qualification=pass\n'
