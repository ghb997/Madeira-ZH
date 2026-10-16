#!/usr/bin/env python3
"""Small, checked portability fixes for Madeira's pinned native source trees.

The host Wine tools generate headers; they never become part of the IPA.
The diagnostic-only FEX fallback follows the Apple allocator configuration.
See docs/BUILDING-ZH.md for source provenance and build limitations.
"""
from pathlib import Path
import hashlib
import re
import sys


def cache_keys() -> None:
    """Invalidate each cache when its build recipe or shared helpers change."""
    source = Path("tools/build-native-ci.sh").read_text(encoding="utf-8")
    functions = dict(re.findall(r"(?ms)^(\w+)\(\) \{\n(.*?)^\}\n", source))
    shared = source.split("run_log()", 1)[0] + functions["run_log"] + functions["fetch_git"]
    patches = Path(__file__).read_text(encoding="utf-8")
    for stage in ("wine", "fex", "llvm", "dxmt", "mingw", "runtime"):
        recipe = shared + functions[stage]
        if stage in ("wine", "fex"):
            recipe += functions["prepare"] + patches
        if stage == "runtime":
            recipe += functions["mingw"]
        print(f"{stage}_recipe={hashlib.sha256(recipe.encode()).hexdigest()[:20]}")


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    if new in s:
        return
    if s.count(old) != 1:
        raise SystemExit(f"Portability patch no longer matches {path}; review upstream changes")
    p.write_text(s.replace(old, new))


def main() -> None:
    # Wine's makedep scans a PE-only generated include even though this build
    # only compiles the Unix side. Never use this placeholder for a PE build.
    p = Path("wine/dlls/ntdll/arm64ec_x64_export_iat.c")
    if not p.exists():
        p.write_text("/* CI header scan only; never compiled as a PE module. */\n")
    replace("wine/tools/makedep.c",
            'fatal_error( "%s must be included before other headers\\n", file->name );',
            'fprintf( stderr, "warning: %s should precede other headers (Madeira iOS shim)\\n", file->name );')
    replace("wine/tools/makedep.c",
            '    if (make->external) return NULL; /* ignore missing files in external libs */\n',
            '    if (make->external) return NULL; /* ignore missing files in external libs */\n'
            '    if (!strncmp( source->name, "ios_", 4 )) return NULL; /* external iOS shims */\n')

    # Apple builds explicitly disable rpmalloc. This function is diagnostic
    # only: zero means no snapshot, while a strong rpmalloc definition wins
    # on platforms that do link the allocator.
    replace("FEX/FEXCore/Source/Interface/Core/Core.cpp",
            "int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out);",
            "__attribute__((weak)) int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out) { (void)out; return 0; }")
    print("Native clean-build portability fixes applied")


if __name__ == "__main__":
    if sys.argv[1:] == ["--cache-keys"]:
        cache_keys()
    elif sys.argv[1:]:
        raise SystemExit("Usage: build-native-ci.py [--cache-keys]")
    else:
        main()
