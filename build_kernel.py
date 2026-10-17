#!/usr/bin/env python3
"""Interactive: clone Arch linux-lts packaging, trim it to your loaded modules, build.

Produces .pkg.tar.zst files only. Never runs pacman -i/-s and never installs.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = "https://gitlab.archlinux.org/archlinux/packaging/packages/linux-lts.git"
NAME = "linux-lts-custom"

# Extra kernel options on top of `localmodconfig`, which keeps only loaded modules.
GROUPS = {
    "docker": ("Docker/containers (namespaces, cgroups, overlayfs, veth, bridge, nftables)", """
CONFIG_NAMESPACES=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_SCHED=y
CONFIG_CPUSETS=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
CONFIG_CFS_BANDWIDTH=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_KEYS=y
CONFIG_POSIX_MQUEUE=y
CONFIG_OVERLAY_FS=m
CONFIG_VETH=m
CONFIG_BRIDGE=m
CONFIG_BRIDGE_NETFILTER=m
CONFIG_VXLAN=m
CONFIG_MACVLAN=m
CONFIG_IPVLAN=m
CONFIG_DUMMY=m
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=m
CONFIG_NF_NAT=m
CONFIG_NF_TABLES=m
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_CT=m
CONFIG_NFT_NAT=m
CONFIG_NFT_MASQ=m
CONFIG_NFT_REDIR=m
CONFIG_NFT_COMPAT=m
CONFIG_NFT_LIMIT=m
CONFIG_NFT_LOG=m
CONFIG_NFT_REJECT=m
CONFIG_NF_REJECT_IPV4=m
CONFIG_NF_REJECT_IPV6=m
CONFIG_NETFILTER_XTABLES=m
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=m
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=m
CONFIG_NETFILTER_XT_MATCH_COMMENT=m
CONFIG_NETFILTER_XT_MATCH_MARK=m
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=m
CONFIG_NETFILTER_XT_MATCH_STATE=m
CONFIG_NETFILTER_XT_MATCH_IPVS=m
CONFIG_NETFILTER_XT_MARK=m
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=m
CONFIG_NETFILTER_XT_TARGET_REDIRECT=m
CONFIG_NETFILTER_XT_NAT=m
CONFIG_NETFILTER_XT_TARGET_CHECKSUM=m
CONFIG_NETFILTER_XT_TARGET_LOG=m
CONFIG_IP_NF_IPTABLES=m
CONFIG_IP6_NF_IPTABLES=m
CONFIG_IP_VS=m
CONFIG_IP_VS_NFCT=y
CONFIG_IP_VS_RR=m
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_FUSE_FS=y
CONFIG_ISO9660_FS=m
CONFIG_BPF_SYSCALL=y
CONFIG_CGROUP_BPF=y
"""),
    "vpn": ("VPN (tun, WireGuard, PPP/L2TP, IPsec/XFRM, tunnels)", """
CONFIG_TUN=m
CONFIG_WIREGUARD=m
CONFIG_PPP=m
CONFIG_PPP_ASYNC=m
CONFIG_PPP_DEFLATE=m
CONFIG_PPP_MPPE=m
CONFIG_PPPOE=m
CONFIG_L2TP=m
CONFIG_NET_IPIP=m
CONFIG_NET_IPGRE_DEMUX=m
CONFIG_IPV6_SIT=m
CONFIG_IPV6_TUNNEL=m
CONFIG_NET_KEY=m
CONFIG_INET_ESP=m
CONFIG_INET_AH=m
CONFIG_INET_IPCOMP=m
CONFIG_INET_XFRM_TUNNEL=m
CONFIG_INET_TUNNEL=m
CONFIG_XFRM_USER=m
CONFIG_XFRM_ALGO=m
CONFIG_XFRM_INTERFACE=m
CONFIG_CRYPTO_CHACHA20POLY1305=m
CONFIG_CRYPTO_LIB_CURVE25519=m
CONFIG_CRYPTO_GCM=m
CONFIG_CRYPTO_MD4=m
CONFIG_CRYPTO_SHA1=y
CONFIG_CRYPTO_HMAC=y
"""),
    "uinput": ("uinput (kanata, key remappers, virtual input devices)", """
CONFIG_INPUT_UINPUT=m
"""),
}


def ask(question, default=True):
    hint = "Y/n" if default else "y/N"
    while True:
        a = input(f"{question} [{hint}] ").strip().lower()
        if not a:
            return default
        if a in ("y", "yes"):
            return True
        if a in ("n", "no"):
            return False


def ask_path(question, default):
    a = input(f"{question} [{default}] ").strip()
    return Path(a or default).expanduser().resolve()


def run(cmd, cwd=None, **kw):
    return subprocess.run(cmd, cwd=cwd, text=True, **kw)


def patch_pkgbuild(path, with_fragment):
    s = path.read_text()

    def sub(pat, rep, flags=0):
        nonlocal s
        s, n = re.subn(pat, lambda m: rep, s, count=1, flags=flags)
        if n != 1:
            sys.exit(f"Upstream PKGBUILD changed; pattern not found: {pat}")

    cfg = '  yes "" | make LSMOD="$startdir/mods.txt" localmodconfig || :\n'
    if with_fragment:
        cfg += '  ./scripts/kconfig/merge_config.sh -m .config "$startdir/extra.fragment"\n'

    sub(r"^pkgbase=linux-lts$", f"pkgbase={NAME}", re.M)
    sub(r"\n  # htmldocs\n(?:  [\w-]+\n)+", "\n")  # docs build deps
    sub(r"  make olddefconfig\n", cfg + "  make olddefconfig\n")
    sub(r"  make htmldocs SPHINXOPTS=-QT &\n  local pid_docs=\$!\n\n", "")
    sub(r"  wait \$pid_docs\n", "")
    # keep module provides/replaces from clashing with the stock linux-lts package
    sub(r"  provides=\(\n    KSMBD-MODULE.*?\n  \)\n  replaces=\(\n    wireguard-lts\n  \)\n", "", re.S)
    sub(r'  "\$pkgbase-docs"\n', "")
    path.write_text(s)


def missing_makedepends(workdir):
    out = run(["makepkg", "--printsrcinfo"], workdir, capture_output=True, check=True).stdout
    deps = sorted({m.group(1) for m in re.finditer(r"^\s*makedepends = ([\w.+-]+)", out, re.M)})
    return [d for d in deps if run(["pacman", "-Qi", d], capture_output=True).returncode]


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        sys.exit(__doc__)
    if hasattr(sys, "getuid") and __import__("os").getuid() == 0:
        sys.exit("Do not run as root (makepkg refuses).")
    for tool in ("git", "makepkg", "pacman"):
        if not shutil.which(tool):
            sys.exit(f"Missing tool: {tool}")

    print(f"== {NAME}: clone Arch linux-lts, trim to loaded modules, build ==\n")

    workdir = ask_path("Work directory", "~/linux-lts-custom-build")
    if workdir.exists():
        if not ask(f"{workdir} exists. Delete it and start fresh?", False):
            sys.exit("Aborted.")
        shutil.rmtree(workdir)

    print("\nExtra features (everything not loaded right now is otherwise dropped):")
    chosen = [k for k, (desc, _) in GROUPS.items() if ask(f"  {desc}?", True)]

    print("\nlocalmodconfig keeps only modules loaded right now.")
    print("Plug in USB devices, enable Wi-Fi/Bluetooth, start VMs, then continue.")
    snapshot = ask("Snapshot loaded modules now (lsmod)?", True)
    mods_src = None
    if not snapshot:
        mods_src = ask_path("Path to an existing lsmod file", "~/mods.txt")
        if not mods_src.is_file():
            sys.exit(f"{mods_src} not found")

    root_fs = run(["findmnt", "-no", "FSTYPE", "/"], capture_output=True).stdout.strip()
    if root_fs == "zfs":
        print("\nWARNING: root is ZFS. The prebuilt zfs-linux-lts module will not load on this kernel.")
        print("Install zfs-dkms (and remove zfs-linux-lts) before booting it, or the pool won't import.")

    print(f"\nPlan: clone -> {workdir}, features: {', '.join(chosen) or 'none'}, build only (no install).")
    if not ask("Proceed?", True):
        sys.exit("Aborted.")

    print("\nCloning...")
    run(["git", "clone", "--depth", "1", REPO, str(workdir)], check=True)

    mods = workdir / "mods.txt"
    if snapshot:
        mods.write_text(run(["lsmod"], capture_output=True, check=True).stdout)
    else:
        shutil.copy(mods_src, mods)
    print(f"Module list: {len(mods.read_text().splitlines()) - 1} modules")

    if chosen:
        (workdir / "extra.fragment").write_text("".join(GROUPS[k][1] for k in chosen))
    patch_pkgbuild(workdir / "PKGBUILD", bool(chosen))

    gone = missing_makedepends(workdir)
    if gone:
        print("\nMissing build dependencies:", " ".join(gone))
        print("Install them, then re-run the build in the work directory:")
        print("  sudo pacman -S --needed " + " ".join(gone))
        print(f"  cd {workdir} && makepkg -f --skippgpcheck")
        sys.exit(1)

    print("\nSource signatures are not verified (kernel keys usually missing from keyring).")
    print("This takes a long time and uses all cores.")
    if not ask("Start build?", True):
        sys.exit(f"Stopped. Build later: cd {workdir} && makepkg -f --skippgpcheck")

    if run(["makepkg", "-f", "--skippgpcheck"], workdir, stdin=subprocess.DEVNULL).returncode:
        sys.exit("makepkg failed")

    print("\nBuilt (not installed):")
    for p in sorted(workdir.glob("*.pkg.tar.zst")):
        print(f"  {p}  ({p.stat().st_size // 2**20} MiB)")
    print("Install with: sudo pacman -U <file>")


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        sys.exit("\nAborted.")
