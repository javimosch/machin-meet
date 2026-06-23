#!/usr/bin/env bash
set -euo pipefail
MACHIN="${MACHIN:-machin}"
"$MACHIN" encode machweb.src meet.src > app.mfl
"$MACHIN" build app.mfl -o machin-meet
echo "built ./machin-meet"
