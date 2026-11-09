#!/usr/bin/env bash
# Runs the plugin against real nginx, sudo and flock in a throwaway Debian container.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
exec docker run --rm --volume "$here:/plugin:ro" debian:bookworm-slim bash /plugin/test/integration-inner.sh
