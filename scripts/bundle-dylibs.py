#!/usr/bin/env python3
"""Makes Mach-O files self-contained: copies every non-system library they need (recursively)
into one folder and rewrites the references, so the app runs on Macs without Homebrew.

    bundle-dylibs.py <lib dir> <file>[=<copied from>]...   (files already copied into the app)

Each file gets an rpath to <lib dir>; libraries are referenced as @rpath/<name>."""
import os, shutil, subprocess, sys

SYSTEM = ("/System/", "/usr/lib/")

def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in lines if l.strip()]

def rpaths(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True, check=True).stdout.splitlines()
    found = []
    for i, line in enumerate(out):
        if "cmd LC_RPATH" in line:
            found.append(out[i + 2].strip().split(" ")[1])
    return found

def own_id(path):
    out = subprocess.run(["otool", "-D", path], capture_output=True, text=True, check=True).stdout.splitlines()
    return out[1].strip() if len(out) > 1 else None

def resolve(ref, origin, origin_rpaths):
    """Real file for a load command, as seen from the original (Homebrew) location."""
    base = os.path.dirname(origin)
    if ref.startswith("@loader_path/") or ref.startswith("@executable_path/"):
        return os.path.realpath(os.path.join(base, ref.split("/", 1)[1]))
    if ref.startswith("@rpath/"):
        for rp in origin_rpaths:
            rp = rp.replace("@loader_path", base).replace("@executable_path", base)
            candidate = os.path.join(rp, ref[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise SystemExit(f"bundle-dylibs: {ref} not found for {origin}")
    return os.path.realpath(ref)

def run(*args):
    subprocess.run(args, check=True, stderr=subprocess.DEVNULL)

def main():
    libdir, files = sys.argv[1], sys.argv[2:]
    os.makedirs(libdir, exist_ok=True)
    copied = {}  # real source path -> bundled name
    # (file in the app, original location used to resolve relative refs)
    # "file=original" says where the file was copied from (relative references resolve there).
    queue = [tuple(f.split("=", 1)) if "=" in f else (f, f) for f in files]
    done = set()
    while queue:
        target, origin = queue.pop()
        if target in done:
            continue
        done.add(target)
        origin_rpaths = rpaths(origin)
        self_id = own_id(target)
        os.chmod(target, 0o755)
        if self_id and not self_id.startswith("@"):
            self_id = "@rpath/" + os.path.basename(target)
            run("install_name_tool", "-id", self_id, target)
        for ref in deps(target):
            if ref == self_id or ref.startswith(SYSTEM):
                continue
            real = resolve(ref, origin, origin_rpaths)
            name = os.path.basename(real)
            if real not in copied:
                if name in copied.values():
                    raise SystemExit(f"bundle-dylibs: two libraries named {name}")
                copied[real] = name
                dest = os.path.join(libdir, name)
                shutil.copy2(real, dest)
                os.chmod(dest, 0o755)
                run("install_name_tool", "-id", "@rpath/" + name, dest)
                queue.append((dest, real))
            run("install_name_tool", "-change", ref, "@rpath/" + name, target)
        # every file finds the libraries through an rpath relative to itself
        rel = os.path.relpath(libdir, os.path.dirname(target))
        wanted = "@loader_path" if rel == "." else "@loader_path/" + rel
        for rp in rpaths(target):
            if rp != wanted:
                subprocess.run(["install_name_tool", "-delete_rpath", rp, target], stderr=subprocess.DEVNULL)
        if wanted not in rpaths(target):
            run("install_name_tool", "-add_rpath", wanted, target)
    print(f"{len(copied)} bibliotecas em {libdir}")

main()
