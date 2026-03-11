#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The runtime loop manages its own recoverable failures. Running it under
# the CLI wrapper's errexit mode makes incidental nonzero helper statuses
# terminate the whole dispatcher.
source "$SCRIPT_DIR/loop.sh"
main_loop
