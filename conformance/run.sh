#!/usr/bin/env bash
# Runs the official MCP conformance suite against the development server.
#
# The published @modelcontextprotocol/conformance CLI (as of the version
# pinned in package.json) takes `--spec-version`, not `--requirements`, and
# recognises 2025-03-26, 2025-06-18 and 2025-11-25 (plus draft/extension) —
# not the 2026-07-28 revision Sake's modern era speaks over the same
# endpoint. The server suite still exercises that endpoint fully: Sake's
# dual-era handshake means every one of these scenarios (an `initialize`
# request) reaches the same handlers a 2026-07-28 client would reach after
# `server/discover`.
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm ci
cd ..
mix run --no-halt dev.exs > conformance/results.log 2>&1 &
PID=$!
trap 'kill $PID' EXIT
for _ in $(seq 1 60); do curl -fs http://localhost:4000/ > /dev/null && break; sleep 1; done
cd conformance
npx @modelcontextprotocol/conformance server --url http://localhost:4000/open/mcp --suite active --spec-version 2025-06-18 --expected-failures expected-failures.yaml
npx @modelcontextprotocol/conformance server --url http://localhost:4000/open/mcp --suite active --spec-version 2025-11-25 --expected-failures expected-failures.yaml
npx @modelcontextprotocol/conformance client --command "./client.sh" --suite core --expected-failures expected-failures.yaml
