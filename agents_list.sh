#!/usr/bin/env zsh
# Which agent transcript stores Scrollback can read: name|available (1/0).
set -uo pipefail
source "${0:A:h}/paths.sh"
exec python3 "${BEAT_HOME}/core/scroll.py" agents
