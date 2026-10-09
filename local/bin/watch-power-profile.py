#!/usr/bin/env python3

import re
import subprocess
import sys

SERVICE = "net.hadess.PowerProfiles"
PATH = "/net/hadess/PowerProfiles"
INTERFACE = "net.hadess.PowerProfiles"

COMMANDS = {
    "power-saver": [
        ["sudo", "-n", "/usr/local/bin/reclockctl", "dgpu-off"],
    ],
    "balanced": [
        ["sudo", "-n", "/usr/local/bin/reclockctl", "dgpu-auto"],
    ],
    "performance": [
        ["sudo", "-n", "/usr/local/bin/reclockctl", "dgpu-on"],
    ],
}

last_profile = None


def run_commands(profile):
    global last_profile

    if profile == last_profile:
        return

    commands = COMMANDS.get(profile)
    if commands is None:
        print(f"Unknown power profile: {profile}", flush=True)
        return

    last_profile = profile
    print(f"Active profile: {profile}", flush=True)

    for command in commands:
        try:
            result = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
            if result.stdout:
                print(result.stdout.strip(), flush=True)

        except subprocess.CalledProcessError as exc:
            print(
                f"Command failed ({exc.returncode}): "
                f"{' '.join(command)}\n{exc.stderr.strip()}",
                file=sys.stderr,
                flush=True,
            )
        except OSError as exc:
            print(
                f"Could not execute {' '.join(command)}: {exc}",
                file=sys.stderr,
                flush=True,
            )


def get_current_profile():
    result = subprocess.run(
        [
            "busctl",
            "--system",
            "get-property",
            SERVICE,
            PATH,
            INTERFACE,
            "ActiveProfile",
        ],
        capture_output=True,
        text=True,
        check=True,
    )

    match = re.fullmatch(r's\s+"([^"]+)"\s*', result.stdout)
    if not match:
        raise RuntimeError(f"Unexpected busctl output: {result.stdout.strip()}")

    return match.group(1)


def main():
    monitor = subprocess.Popen(
        [
            "dbus-monitor",
            "--system",
            "type='signal',"
            "sender='net.hadess.PowerProfiles',"
            "interface='org.freedesktop.DBus.Properties',"
            "member='PropertiesChanged',"
            "path='/net/hadess/PowerProfiles',"
            "arg0='net.hadess.PowerProfiles'",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    try:
        # Apply the current profile once at startup.
        run_commands(get_current_profile())

        waiting_for_profile = False

        for line in monitor.stdout:
            if 'string "ActiveProfile"' in line:
                waiting_for_profile = True
                continue

            if waiting_for_profile:
                waiting_for_profile = False
                match = re.search(r'variant\s+string\s+"([^"]+)"', line)
                if match:
                    run_commands(match.group(1))

        raise RuntimeError("D-Bus monitor stopped unexpectedly")

    finally:
        monitor.terminate()
        monitor.wait()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(
            f"Power profile watcher failed: {exc}",
            file=sys.stderr,
            flush=True,
        )
        sys.exit(1)
