#!/usr/bin/env python3
"""Prepare and verify the relocatable FEATool GNU Octave Linux runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Iterable


ARTIFACT = "featool-octave-runtime-linux-x64"
PLATFORM = "linux-x64"
OCTAVE_VERSION = "11.3.0"
PROFILE = "headless-cli-featool"
MANIFEST_NAME = "runtime-manifest.json"
DEPENDENCY_DIR = Path("lib/runtime-deps")

# These libraries are supplied by the target glibc host.  Compiler runtimes and
# numerical libraries are intentionally absent from this list and are bundled.
HOST_LIBRARY_ALLOWLIST = (
    "ld-linux-x86-64.so.2",
    "libBrokenLocale.so.1",
    "libanl.so.1",
    "libc.so.6",
    "libdl.so.2",
    "libm.so.6",
    "libmvec.so.1",
    "libpthread.so.0",
    "libresolv.so.2",
    "librt.so.1",
    "libutil.so.1",
)

VERSION_RE = re.compile(r"\b(GLIBCXX|GLIBC|CXXABI|GCC)_([0-9]+(?:\.[0-9]+)*)\b")
NEEDED_RE = re.compile(r"Shared library: \[(.+?)\]")
RPATH_RE = re.compile(r"Library (?:rpath|runpath): \[(.*?)\]")


class RuntimeErrorWithContext(RuntimeError):
    pass


def run(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        command = " ".join(argv)
        raise RuntimeErrorWithContext(
            f"command failed ({result.returncode}): {command}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result


def require_commands(names: Iterable[str]) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        raise RuntimeErrorWithContext(
            "required command(s) are missing: " + ", ".join(sorted(missing))
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_elf(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open("rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False


def elf_files(root: Path) -> list[Path]:
    return sorted(
        (path for path in root.rglob("*") if is_elf(path)),
        key=lambda path: path.relative_to(root).as_posix(),
    )


def readelf_dynamic(path: Path) -> str:
    return run(["readelf", "-d", "--wide", str(path)]).stdout


def needed_libraries(path: Path) -> list[str]:
    return sorted(set(NEEDED_RE.findall(readelf_dynamic(path))))


def rpath_entries(path: Path) -> list[str]:
    entries: list[str] = []
    for match in RPATH_RE.findall(readelf_dynamic(path)):
        entries.extend(item for item in match.split(":") if item)
    return entries


def path_is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def internal_library_map(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    dependency_root = (root / DEPENDENCY_DIR).resolve()
    candidates = sorted(root.rglob("*"), key=lambda path: path.as_posix())
    for path in candidates:
        try:
            if path.is_symlink():
                target = path.resolve(strict=True)
                if not target.is_file() or not path_is_within(target, root) or not is_elf(target):
                    continue
            elif is_elf(path):
                target = path
            else:
                continue
        except OSError:
            continue

        current = result.get(path.name)
        if current is None:
            result[path.name] = target
            continue

        # Prefer Octave-owned libraries outside the flattened runtime-deps
        # directory over a copied dependency with the same basename.
        current_in_deps = path_is_within(current, dependency_root)
        target_in_deps = path_is_within(target, dependency_root)
        if current_in_deps and not target_in_deps:
            result[path.name] = target
    return result


def ldconfig_library_map() -> dict[str, Path]:
    output = run(["ldconfig", "-p"]).stdout
    result: dict[str, Path] = {}
    pattern = re.compile(r"^\s*(\S+)\s+\(([^)]*)\)\s+=>\s+(\S+)\s*$")
    for line in output.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        soname, attributes, raw_path = match.groups()
        if "x86-64" not in attributes and "x86_64" not in raw_path:
            continue
        path = Path(raw_path)
        if path.exists() and soname not in result:
            result[soname] = path
    return result


def ensure_relative_symlink(link: Path, target: Path) -> None:
    if link.is_symlink() or link.exists():
        try:
            if link.resolve(strict=True) == target.resolve(strict=True):
                return
        except OSError:
            pass
        raise RuntimeErrorWithContext(
            f"dependency name collision for {link.name}: {link}"
        )
    relative = os.path.relpath(target, link.parent)
    link.symlink_to(relative)


def copy_system_library(source: Path, requested_name: str, dependency_root: Path) -> bool:
    real_source = source.resolve(strict=True)
    destination = dependency_root / real_source.name
    copied = False
    if destination.exists():
        if not destination.is_file() or sha256_file(destination) != sha256_file(real_source):
            raise RuntimeErrorWithContext(
                f"dependency basename collision for {real_source.name}: {real_source}"
            )
    else:
        shutil.copy2(real_source, destination)
        copied = True

    requested = dependency_root / requested_name
    if requested_name != destination.name:
        ensure_relative_symlink(requested, destination)
    return copied


def stage_dependency_closure(root: Path) -> list[str]:
    dependency_root = root / DEPENDENCY_DIR
    dependency_root.mkdir(parents=True, exist_ok=True)
    host = set(HOST_LIBRARY_ALLOWLIST)
    system = ldconfig_library_map()
    bundled_sonames: set[str] = set()

    for _iteration in range(64):
        internal = internal_library_map(root)
        copied_any = False
        unresolved: set[str] = set()
        required: set[str] = set()
        for elf in elf_files(root):
            required.update(needed_libraries(elf))

        for soname in sorted(required):
            if soname in host:
                continue
            bundled_sonames.add(soname)
            flat = dependency_root / soname
            if flat.is_symlink() or flat.exists():
                continue
            internal_target = internal.get(soname)
            if internal_target is not None:
                ensure_relative_symlink(flat, internal_target)
                continue
            system_target = system.get(soname)
            if system_target is None:
                unresolved.add(soname)
                continue
            copied_any = copy_system_library(system_target, soname, dependency_root) or copied_any

        if unresolved:
            raise RuntimeErrorWithContext(
                "unresolved ELF dependencies: " + ", ".join(sorted(unresolved))
            )
        if not copied_any:
            return sorted(bundled_sonames)

    raise RuntimeErrorWithContext("ELF dependency closure did not converge")


def patch_relative_runpaths(root: Path) -> None:
    dependency_root = root / DEPENDENCY_DIR
    for elf in elf_files(root):
        relative = os.path.relpath(dependency_root, elf.parent).replace(os.sep, "/")
        entries = ["$ORIGIN"]
        if relative != ".":
            entries.append(f"$ORIGIN/{relative}")
        run(["patchelf", "--set-rpath", ":".join(entries), str(elf)])


def audit_architecture(root: Path) -> None:
    failures: list[str] = []
    for elf in elf_files(root):
        header = run(["readelf", "-h", str(elf)]).stdout
        if "Class:                             ELF64" not in header:
            failures.append(f"{elf.relative_to(root)} is not ELF64")
        if "Machine:                           Advanced Micro Devices X86-64" not in header:
            failures.append(f"{elf.relative_to(root)} is not x86-64")
    if failures:
        raise RuntimeErrorWithContext("\n".join(failures[:40]))


def audit_runpaths(root: Path) -> None:
    failures: list[str] = []
    for elf in elf_files(root):
        for entry in rpath_entries(elf):
            if entry == "$ORIGIN" or entry.startswith("$ORIGIN/"):
                continue
            failures.append(f"{elf.relative_to(root)} has non-relative RUNPATH/RPATH: {entry}")
    if failures:
        raise RuntimeErrorWithContext("\n".join(failures[:40]))


def audit_dependency_resolution(root: Path) -> None:
    failures: list[str] = []
    host = set(HOST_LIBRARY_ALLOWLIST)
    clean_env = os.environ.copy()
    for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "LD_DEBUG"):
        clean_env.pop(name, None)

    for elf in elf_files(root):
        needed = needed_libraries(elf)
        if not needed:
            continue
        result = run(["ldd", str(elf)], env=clean_env, check=False)
        combined = result.stdout + result.stderr
        if "not found" in combined:
            failures.append(f"{elf.relative_to(root)} has unresolved ldd output:\n{combined}")
            continue
        if result.returncode != 0:
            failures.append(
                f"ldd failed for {elf.relative_to(root)} ({result.returncode}):\n{combined}"
            )
            continue

        for line in result.stdout.splitlines():
            match = re.match(r"^\s*(\S+)\s+=>\s+(\S+)\s+\(", line)
            if match:
                soname, resolved = match.groups()
                if resolved == "not":
                    failures.append(f"{elf.relative_to(root)} cannot resolve {soname}")
                    continue
                if soname in host:
                    continue
                resolved_path = Path(resolved)
                if resolved_path.is_absolute() and not path_is_within(resolved_path, root):
                    failures.append(
                        f"{elf.relative_to(root)} resolves {soname} outside runtime: {resolved}"
                    )
                continue

            direct = re.match(r"^\s*(/\S+)\s+\(", line)
            if direct:
                resolved_path = Path(direct.group(1))
                if resolved_path.name not in host and not path_is_within(resolved_path, root):
                    failures.append(
                        f"{elf.relative_to(root)} resolves an external library: {resolved_path}"
                    )

    if failures:
        raise RuntimeErrorWithContext("\n\n".join(failures[:30]))


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def max_required_abi_versions(root: Path) -> dict[str, str | None]:
    found: dict[str, set[str]] = {name: set() for name in ("GLIBC", "GLIBCXX", "CXXABI", "GCC")}
    for elf in elf_files(root):
        result = run(["objdump", "-T", str(elf)], check=False)
        if result.returncode != 0:
            continue
        for line in result.stdout.splitlines():
            if "*UND*" not in line:
                continue
            for family, version in VERSION_RE.findall(line):
                found[family].add(version)

    maxima: dict[str, str | None] = {}
    for family, versions in found.items():
        maxima[family] = max(versions, key=version_key) if versions else None
    return maxima


def enforce_glibc_baseline(abi: dict[str, str | None], baseline: str) -> None:
    required = abi.get("GLIBC")
    if required is None:
        return
    if version_key(required) > version_key(baseline):
        raise RuntimeErrorWithContext(
            f"runtime requires GLIBC_{required}, exceeding selected baseline GLIBC_{baseline}"
        )


def scan_forbidden_prefixes(root: Path, prefixes: Iterable[str]) -> None:
    cleaned = [prefix for prefix in prefixes if prefix]
    if not cleaned:
        return
    matches: list[str] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink() or not path.is_file() or path.name == MANIFEST_NAME:
            continue
        if is_elf(path):
            # Compilers and Octave's build-info objects may retain source/build
            # paths as inert provenance strings.  The relocation contract is
            # concerned with loader-visible metadata, which is audited here
            # and separately by the RPATH/ldd checks.
            dynamic = readelf_dynamic(path)
            if any(prefix in dynamic for prefix in cleaned):
                matches.append(path.relative_to(root).as_posix())
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if any(prefix.encode() in data for prefix in cleaned):
            matches.append(path.relative_to(root).as_posix())
    if matches:
        raise RuntimeErrorWithContext(
            "runtime contains references to build/source paths: " + ", ".join(matches[:40])
        )


def manifest_entries(root: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if relative == MANIFEST_NAME:
            continue
        info = path.lstat()
        mode = f"{stat.S_IMODE(info.st_mode):04o}"
        if stat.S_ISLNK(info.st_mode):
            entries.append(
                {"path": relative, "type": "symlink", "mode": mode, "target": os.readlink(path)}
            )
        elif stat.S_ISDIR(info.st_mode):
            entries.append({"path": relative, "type": "directory", "mode": mode})
        elif stat.S_ISREG(info.st_mode):
            entries.append(
                {
                    "path": relative,
                    "type": "file",
                    "mode": mode,
                    "bytes": info.st_size,
                    "sha256": sha256_file(path),
                }
            )
        else:
            raise RuntimeErrorWithContext(f"unsupported payload entry type: {relative}")
    return entries


def first_line(argv: list[str]) -> str:
    result = run(argv, check=False)
    text = result.stdout.strip() or result.stderr.strip()
    return text.splitlines()[0] if text else ""


def os_release() -> dict[str, str]:
    result: dict[str, str] = {}
    path = Path("/etc/os-release")
    if not path.exists():
        return result
    for raw in path.read_text(encoding="utf-8").splitlines():
        if "=" not in raw or raw.startswith("#"):
            continue
        key, value = raw.split("=", 1)
        result[key] = value.strip().strip('"')
    return result


def build_provenance() -> dict[str, object]:
    release = os_release()
    return {
        "distribution": release.get("PRETTY_NAME", release.get("NAME", "")),
        "distribution_id": release.get("ID", ""),
        "distribution_version": release.get("VERSION_ID", ""),
        "machine": first_line(["uname", "-m"]),
        "glibc": first_line(["ldd", "--version"]),
        "gcc": first_line(["gcc", "--version"]),
        "gxx": first_line(["g++", "--version"]),
        "gfortran": first_line(["gfortran", "--version"]),
        "binutils": first_line(["ld", "--version"]),
    }


def read_configure_args(path: Path | None) -> list[str]:
    if path is None:
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines() if line]


def payload_totals(entries: list[dict[str, object]]) -> dict[str, int]:
    files = [entry for entry in entries if entry["type"] == "file"]
    symlinks = [entry for entry in entries if entry["type"] == "symlink"]
    directories = [entry for entry in entries if entry["type"] == "directory"]
    return {
        "payload_entries": len(entries),
        "payload_files": len(files),
        "payload_symlinks": len(symlinks),
        "payload_directories": len(directories),
        "payload_bytes": sum(int(entry["bytes"]) for entry in files),
    }


def ensure_internal_symlinks(root: Path) -> None:
    failures: list[str] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if not path.is_symlink():
            continue
        try:
            target = path.resolve(strict=True)
        except OSError:
            failures.append(f"broken symlink: {path.relative_to(root)} -> {os.readlink(path)}")
            continue
        if not path_is_within(target, root):
            failures.append(
                f"external symlink: {path.relative_to(root)} -> {os.readlink(path)}"
            )
    if failures:
        raise RuntimeErrorWithContext("\n".join(failures[:40]))


def write_manifest(args: argparse.Namespace, bundled_sonames: list[str]) -> dict[str, object]:
    root = args.runtime_root.resolve()
    entries = manifest_entries(root)
    totals = payload_totals(entries)
    abi = max_required_abi_versions(root)
    enforce_glibc_baseline(abi, args.glibc_baseline)

    manifest: dict[str, object] = {
        "format_version": 1,
        "artifact": ARTIFACT,
        "platform": PLATFORM,
        "profile": PROFILE,
        "octave_version": OCTAVE_VERSION,
        "source_archive": args.source_archive,
        "source_sha256": args.source_sha256.lower(),
        "configured_prefix": args.configured_prefix,
        "build_image": args.build_image,
        "selected_glibc_baseline": args.glibc_baseline,
        "abi_max_required": abi,
        "host_library_allowlist": list(HOST_LIBRARY_ALLOWLIST),
        "runtime_dependency_sonames": bundled_sonames,
        "configure_args": read_configure_args(args.configure_args_file),
        "build_provenance": build_provenance(),
        **totals,
        "files": entries,
    }
    manifest_path = root / MANIFEST_NAME
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def verify_manifest_identity(manifest: dict[str, object], expected_profile: str) -> None:
    expected = {
        "format_version": 1,
        "artifact": ARTIFACT,
        "platform": PLATFORM,
        "profile": expected_profile,
        "octave_version": OCTAVE_VERSION,
    }
    failures = [
        f"{key}: expected {value!r}, got {manifest.get(key)!r}"
        for key, value in expected.items()
        if manifest.get(key) != value
    ]
    if failures:
        raise RuntimeErrorWithContext("invalid runtime manifest identity: " + "; ".join(failures))


def verify_tree(root: Path, expected_profile: str, smoke: bool) -> dict[str, object]:
    root = root.resolve()
    manifest_path = root / MANIFEST_NAME
    if not manifest_path.is_file():
        raise RuntimeErrorWithContext(f"runtime manifest is missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    verify_manifest_identity(manifest, expected_profile)

    expected_entries = manifest.get("files")
    actual_entries = manifest_entries(root)
    if expected_entries != actual_entries:
        expected_by_path = {
            str(entry.get("path")): entry for entry in expected_entries if isinstance(entry, dict)
        }
        actual_by_path = {str(entry.get("path")): entry for entry in actual_entries}
        paths = sorted(set(expected_by_path) | set(actual_by_path))
        differences = [
            path
            for path in paths
            if expected_by_path.get(path) != actual_by_path.get(path)
        ]
        raise RuntimeErrorWithContext(
            "runtime payload differs from manifest at: " + ", ".join(differences[:40])
        )

    totals = payload_totals(actual_entries)
    for key, value in totals.items():
        if manifest.get(key) != value:
            raise RuntimeErrorWithContext(
                f"manifest {key} mismatch: expected {manifest.get(key)!r}, found {value!r}"
            )

    ensure_internal_symlinks(root)
    audit_architecture(root)
    audit_runpaths(root)
    audit_dependency_resolution(root)

    actual_abi = max_required_abi_versions(root)
    if manifest.get("abi_max_required") != actual_abi:
        raise RuntimeErrorWithContext(
            f"ABI requirements differ from manifest: {actual_abi!r}"
        )
    baseline = str(manifest.get("selected_glibc_baseline", ""))
    if baseline:
        enforce_glibc_baseline(actual_abi, baseline)

    if smoke:
        run_smoke(root)
    return manifest


def run_smoke(root: Path) -> None:
    launcher = root / "bin/featool-octave"
    if not launcher.is_file():
        raise RuntimeErrorWithContext(f"runtime launcher is missing: {launcher}")
    with tempfile.TemporaryDirectory(prefix="featool-octave-smoke-") as home:
        Path(home, ".octaverc").write_text(
            "error('ambient user startup file was loaded');\\n",
            encoding="utf-8",
        )
        env = {
            "HOME": home,
            "PATH": "/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        }
        expression = (
            "assert(strcmp(OCTAVE_VERSION,'11.3.0'));"
            "A=sparse([4 -1;-1 4]);b=[1;2];x=A\\b;assert(norm(A*x-b)<1e-12);"
            "disp('LINUX_RUNTIME_RELOCATION_SMOKE=pass')"
        )
        result = run(
            [
                str(launcher),
                "--quiet",
                "--eval",
                expression,
            ],
            env=env,
            check=False,
        )
        combined = result.stdout + result.stderr
        if result.returncode != 0 or "LINUX_RUNTIME_RELOCATION_SMOKE=pass" not in combined:
            raise RuntimeErrorWithContext(
                f"relocation smoke failed ({result.returncode})\n{combined}"
            )


def verify_archive(
    archive: Path,
    expected_profile: str,
    smoke: bool,
) -> None:
    archive = archive.resolve()
    if not archive.is_file():
        raise RuntimeErrorWithContext(f"archive is missing: {archive}")
    with tempfile.TemporaryDirectory(prefix="featool-octave-archive-") as temp:
        root = Path(temp)
        run(["tar", "--zstd", "-xf", str(archive), "-C", str(root)])
        verify_tree(root, expected_profile, smoke)


def prepare(args: argparse.Namespace) -> int:
    root = args.runtime_root.resolve()
    if not root.is_dir():
        raise RuntimeErrorWithContext(f"runtime root is missing: {root}")
    require_commands(
        ["g++", "gcc", "gfortran", "ld", "ldconfig", "ldd", "objdump", "patchelf", "readelf"]
    )
    bundled = stage_dependency_closure(root)
    patch_relative_runpaths(root)
    ensure_internal_symlinks(root)
    audit_architecture(root)
    audit_runpaths(root)
    audit_dependency_resolution(root)
    scan_forbidden_prefixes(root, args.forbidden_prefix)
    manifest = write_manifest(args, bundled)
    print("runtime_prepare=pass")
    print(f"runtime_files={manifest['payload_files']}")
    print(f"runtime_bytes={manifest['payload_bytes']}")
    print(f"runtime_glibc_max={manifest['abi_max_required'].get('GLIBC')}")
    print(f"runtime_glibcxx_max={manifest['abi_max_required'].get('GLIBCXX')}")
    print(f"runtime_cxxabi_max={manifest['abi_max_required'].get('CXXABI')}")
    print(f"runtime_gcc_max={manifest['abi_max_required'].get('GCC')}")
    return 0


def verify(args: argparse.Namespace) -> int:
    require_commands(["ldd", "objdump", "readelf", "tar"])
    manifest = verify_tree(args.runtime_root, args.expected_profile, args.smoke)
    print("runtime_tree=pass")
    print(f"runtime_profile={manifest['profile']}")
    print(f"runtime_files={manifest['payload_files']}")
    print(f"runtime_bytes={manifest['payload_bytes']}")
    abi = manifest["abi_max_required"]
    print(f"runtime_glibc_max={abi.get('GLIBC')}")
    if args.archive is not None:
        verify_archive(args.archive, args.expected_profile, args.smoke)
        print("runtime_archive=pass")
    print("verification=pass")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare", help="stage ELF closure and write manifest")
    prepare_parser.add_argument("--runtime-root", type=Path, required=True)
    prepare_parser.add_argument("--source-archive", required=True)
    prepare_parser.add_argument("--source-sha256", required=True)
    prepare_parser.add_argument("--configured-prefix", required=True)
    prepare_parser.add_argument("--build-image", required=True)
    prepare_parser.add_argument("--glibc-baseline", required=True)
    prepare_parser.add_argument("--configure-args-file", type=Path)
    prepare_parser.add_argument("--forbidden-prefix", action="append", default=[])
    prepare_parser.set_defaults(func=prepare)

    verify_parser = subparsers.add_parser("verify", help="verify runtime tree and optional archive")
    verify_parser.add_argument("--runtime-root", type=Path, required=True)
    verify_parser.add_argument("--expected-profile", default=PROFILE)
    verify_parser.add_argument("--archive", type=Path)
    verify_parser.add_argument("--smoke", action="store_true")
    verify_parser.set_defaults(func=verify)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except RuntimeErrorWithContext as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
