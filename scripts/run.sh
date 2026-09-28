#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh
open "$PWD/dist/Keydance.app"
