#!/usr/bin/env bash
# AgentSync launcher for macOS and Linux.
# Requires PowerShell 7+ (pwsh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/Start-AgentSync-Bootstrap.ps1"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "Error: 'pwsh' (PowerShell 7+) is not installed." >&2
  echo "" >&2
  echo "macOS (Homebrew):" >&2
  echo "  brew install --cask powershell" >&2
  echo "" >&2
  echo "Linux (see https://learn.microsoft.com/powershell/scripting/install/installing-powershell):" >&2
  echo "  # Ubuntu/Debian example:" >&2
  echo "  # wget + apt install powershell" >&2
  exit 1
fi

# Use the folder the launcher lives in as the default. An external AGENTSYNC_HOME overrides this.
export AGENTSYNC_HOME="${AGENTSYNC_HOME:-$SCRIPT_DIR}"

exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$BOOTSTRAP" "$@"
