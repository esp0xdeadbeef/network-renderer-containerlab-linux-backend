#!/usr/bin/env bash
# GAMP-ID: FS-230-HDS-010-SDS-010-SMS-030
# Consumer integration: FS-260-HDS-010-SDS-010-SMS-010
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cd "${repo_root}"

PYTHONPATH="${repo_root}" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from copy import deepcopy

from clabgen.s88.CM.cpm_firewall_rules import rules_for_cpm_rule


RELATION = "FS-260-HDS-010-SDS-010-SMS-010__policy-required-access-return"

stateful_return = {
    "action": "accept",
    "connectionState": "established,related",
    "direction": "relation-reverse",
    "fromInterface": "destination",
    "relationId": RELATION,
    "returnRule": True,
    "toInterface": "source",
    "trafficType": "any",
}

rendered = rules_for_cpm_rule(stateful_return)
if len(rendered) != 2:
    raise AssertionError(f"expected one IPv4 and one IPv6 return rule: {rendered!r}")
for rule in rendered:
    if "ct state established,related" not in rule:
        raise AssertionError(f"stateful return widened to reverse new-flow authority: {rule}")
    if f'comment "{RELATION}"' not in rule:
        raise AssertionError(f"relation identity was not preserved: {rule}")

distinct_reverse_relation = deepcopy(stateful_return)
distinct_reverse_relation.pop("connectionState")
distinct_reverse_relation.pop("returnRule")
distinct_reverse_relation["direction"] = "relation-forward"
distinct_reverse_relation["relationId"] = f"{RELATION}__explicit-reverse"
ordinary_rules = rules_for_cpm_rule(distinct_reverse_relation)
if any("ct state" in rule for rule in ordinary_rules):
    raise AssertionError(
        "distinct modeled reverse new-flow relation was rewritten as stateful return"
    )

missing_state = deepcopy(stateful_return)
missing_state.pop("connectionState")
try:
    rules_for_cpm_rule(missing_state)
except ValueError as error:
    if "reverse-new-flow authority invention" not in str(error):
        raise
else:
    raise AssertionError("returnRule without connectionState did not fail closed")

unsupported_state = deepcopy(stateful_return)
unsupported_state["connectionState"] = "new"
try:
    rules_for_cpm_rule(unsupported_state)
except ValueError as error:
    if "unsupported connectionState" not in str(error):
        raise
else:
    raise AssertionError("unsupported connectionState did not fail closed")

print("PASS FS-230-HDS-010-SDS-010-SMS-030 CLAB stateful-return materialization")
PY
