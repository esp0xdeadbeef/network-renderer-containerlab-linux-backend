#!/usr/bin/env bash
# Test wrapper around the shared canonical-input helper.
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_here}/../../scripts/canonical-bundle.sh"
