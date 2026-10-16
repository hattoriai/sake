#!/usr/bin/env bash
# Fetches and compiles the dependencies at the start of a Claude Code cloud
# session. Local sessions skip it. scripts/cloud-setup.sh installs Erlang
# and Elixir first, and the environment must allow hex.pm, repo.hex.pm and
# builds.hex.pm.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

# Without the setup script, the install runs here, at each session start.
if ! command -v mix >/dev/null; then
  bash scripts/cloud-setup.sh
fi

mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get
MIX_ENV=test mix deps.compile
