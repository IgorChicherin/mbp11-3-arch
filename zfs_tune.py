#!/usr/bin/env python3
"""Interactive ZFS memory tuning: ARC size, faster memory return, metadata-only cache."""
import os
import subprocess
import sys

PARAMS = "/sys/module/zfs/parameters"
ARCSTATS = "/proc/spl/kstat/zfs/arcstats"
MODPROBE_CONF = "/etc/modprobe.d/zfs.conf"
GIB = 2**30


def arcstats():
    stats = {}
    with open(ARCSTATS) as f:
        for line in f.readlines()[2:]:
            name, _, value = line.split()
            stats[name] = int(value)
    return stats


def get_param(name):
    with open(f"{PARAMS}/{name}") as f:
        return f.read().strip()


def set_param(name, value):
    try:
        with open(f"{PARAMS}/{name}", "w") as f:
            f.write(str(value))
    except OSError as e:
        print(f"error: {name}={value}: {e}")
        return False
    return True


def persist(name, value):
    """Merge name=value into the `options zfs` line of MODPROBE_CONF."""
    other, opts = [], {}
    if os.path.exists(MODPROBE_CONF):
        with open(MODPROBE_CONF) as f:
            for line in f.read().splitlines():
                parts = line.split()
                if parts[:2] == ["options", "zfs"]:
                    for tok in parts[2:]:
                        k, _, v = tok.partition("=")
                        opts[k] = v
                else:
                    other.append(line)
    opts[name] = str(value)
    other.append("options zfs " + " ".join(f"{k}={v}" for k, v in opts.items()))
    with open(MODPROBE_CONF, "w") as f:
        f.write("\n".join(other) + "\n")
    print(f"saved to {MODPROBE_CONF} (root on ZFS: run `azfs-update-zbm`)")


def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        sys.exit(0)


def status():
    s = arcstats()
    print(f"\nARC size: {s['size'] / GIB:.2f} GiB  "
          f"(min {s['c_min'] / GIB:.2f}, max {s['c_max'] / GIB:.2f})")
    print(f"zfs_arc_shrinker_limit: {get_param('zfs_arc_shrinker_limit')}\n")


def set_arc_max():
    raw = ask("ARC max in GiB (e.g. 4 or 0.5): ")
    try:
        size = int(float(raw) * GIB)
    except ValueError:
        print("not a number")
        return
    if size <= 0:
        print("must be > 0")
        return
    if set_param("zfs_arc_max", size):
        try:
            with open("/proc/sys/vm/drop_caches", "w") as f:
                f.write("3")
        except OSError as e:
            print(f"error: drop_caches: {e}")
        print(f"zfs_arc_max={size}")
        persist("zfs_arc_max", size)


def set_shrinker():
    print("zfs_arc_shrinker_limit=0: kernel shrinker may reclaim ARC without per-call cap.")
    if ask("apply? [y/N] ").lower() != "y":
        return
    if set_param("zfs_arc_shrinker_limit", 0):
        persist("zfs_arc_shrinker_limit", 0)


def zfs(*args):
    return subprocess.run(["zfs", *args], capture_output=True, text=True)


def create_dataset(datasets):
    """Ask for a name (default <parent of root dataset>/metadata), create it unless it exists. Returns name or None."""
    root = subprocess.run(["findmnt", "-no", "SOURCE", "/"], capture_output=True, text=True).stdout.strip()
    default = f"{root.rpartition('/')[0]}/metadata" if "/" in root else ""
    name = ask(f"new dataset name [{default}]: ") or default
    if not name:
        return None
    if any(name == existing for existing, _ in datasets):
        return name
    if ask(f"create {name}? [y/N] ").lower() != "y":
        return None
    r = zfs("create", name)
    if r.returncode:
        print(r.stderr.strip())
        return None
    print(f"created {name}")
    return name


def set_primarycache():
    r = zfs("list", "-H", "-o", "name,primarycache")
    if r.returncode:
        print(r.stderr.strip())
        return
    datasets = [line.split("\t") for line in r.stdout.splitlines()]
    for i, (name, cache) in enumerate(datasets, 1):
        print(f"{i}) {name}  [primarycache={cache}]")
    print("0) create new dataset")
    pick = ask("dataset number (empty = cancel): ")
    if pick == "0":
        name = create_dataset(datasets)
        if not name:
            return
    elif pick.isdigit() and 1 <= int(pick) <= len(datasets):
        name = datasets[int(pick) - 1][0]
    else:
        return
    value = ask("value [metadata/all/none] (default metadata): ") or "metadata"
    if value not in ("metadata", "all", "none"):
        print("invalid value")
        return
    r = zfs("set", f"primarycache={value}", name)
    print(r.stderr.strip() or f"{name}: primarycache={value}")


MENU = {
    "1": ("Set ARC max size", set_arc_max),
    "2": ("Faster memory return (shrinker limit)", set_shrinker),
    "3": ("Cache metadata only on a dataset", set_primarycache),
}


def main():
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", "-k", sys.executable, *sys.argv])
    if not os.path.exists(ARCSTATS):
        sys.exit("zfs module not loaded")
    while True:
        status()
        for key, (label, _) in MENU.items():
            print(f"{key}) {label}")
        choice = ask("q) quit\n> ")
        if choice == "q":
            return
        if choice in MENU:
            MENU[choice][1]()
        else:
            print("invalid choice")


if __name__ == "__main__":
    main()
