from __future__ import annotations

from pathlib import Path
import json
import subprocess
import sys


FRR_DAEMONS = ["zebra", "bgpd", "staticd"]


def running(name: str) -> bool:
    result = subprocess.run(
        ["pgrep", "-x", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def start_daemon(name: str) -> None:
    if running(name):
        return
    daemon = f"/usr/lib/frr/{name}"
    subprocess.run(
        [daemon, "-d", "-F", "traditional", "-A", "127.0.0.1"],
        check=False,
    )


def daemon_lines(payload: dict) -> list[str]:
    lines: list[str] = []
    for daemon_name, enabled in payload["daemons"].items():
        lines.append(f"{daemon_name}={enabled}")
    return lines


def write_config(payload: dict) -> None:
    frr_dir = Path("/etc/frr")
    run_dir = Path("/var/run/frr")
    frr_dir.mkdir(parents=True, exist_ok=True)
    run_dir.mkdir(parents=True, exist_ok=True)
    (frr_dir / "daemons").write_text("\n".join(daemon_lines(payload)) + "\n")
    (frr_dir / "frr.conf").write_text(payload["frr_conf"])
    (frr_dir / "vtysh.conf").write_text(payload["vtysh_conf"])
    subprocess.run(["chown", "-R", "frr:frr", "/etc/frr", "/var/run/frr"], check=False)
    subprocess.run(
        [
            "chmod",
            "640",
            "/etc/frr/daemons",
            "/etc/frr/frr.conf",
            "/etc/frr/vtysh.conf",
        ],
        check=False,
    )


def main() -> None:
    payload = json.loads(Path(sys.argv[1]).read_text())
    write_config(payload)
    for daemon in FRR_DAEMONS:
        start_daemon(daemon)
    subprocess.run(["vtysh", "-b"], check=False)
    subprocess.run(["vtysh", "-c", "show bgp ipv4 summary"], check=False)
    subprocess.run(["vtysh", "-c", "show bgp ipv6 summary"], check=False)


if __name__ == "__main__":
    main()
