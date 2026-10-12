#!/usr/bin/env bash
# scripts/sabotage reanchor <n…> — see scripts/sabotage_reanchor.py. `exec` on the first command line.
exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sabotage_reanchor.py" "$@"
