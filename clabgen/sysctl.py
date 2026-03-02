# ./clabgen/sysctl.py
from typing import List


def render_sysctls() -> List[str]:
    # Match working fabric.clab.yml: only global rp_filter disable loop
    return [
        "sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > \"$i\"; done'",
    ]
