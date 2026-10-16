#!/usr/bin/env bash
# Runs the official MCP conformance suite (@modelcontextprotocol/conformance,
# the version pinned in package.json) against the development server.
#
#   ./run.sh              the core suite (what CI gates on)
#   ./run.sh extensions   the extension scenarios, against their own baseline
#
# The core suite runs, for each revision Sake speaks (2025-06-18,
# 2025-11-25 and 2026-07-28):
#
#   - the server scenarios against `/open/mcp`, the unauthenticated
#     endpoint of `SakeDev.ConformanceServer`. `--spec-version` picks both
#     the scenarios that apply to the revision and the wire they run at:
#     a legacy handshake for the first two, the stateless modern protocol
#     for 2026-07-28. `--suite all` includes the scenarios the suite still
#     marks pending (http-header-validation and others), not only the
#     active ones.
#   - the client scenarios, with `Sake.Client` driven by client.exs
#     against the suite's own reference servers.
#
# and then, once, the authorization-server scenarios against the dev
# server's own authorization server (authorization.sh plays the person who
# signs in and approves).
#
# expected-failures.yaml is the core baseline and
# expected-failures-extensions.yaml the extensions' one. A run fails on a
# scenario that fails and is not listed, and on a listed scenario that now
# passes; a warning counts as a failure. The extension scenarios (tasks-*,
# sep-2640-* and the auth extensions) belong to no revision and run at the
# 2026-07-28 wire. They are not part of the specification, so they have a
# baseline and a CI step of their own instead of gating the core run.
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm ci
cd ..
# Compiled up front, so that the wait below is for the server to start and
# not for a cold build, which can take longer than the wait.
mix compile
mix run --no-halt dev.exs > conformance/results.log 2>&1 &
PID=$!
trap 'kill $PID' EXIT
for _ in $(seq 1 60); do curl -fs http://localhost:4000/ > /dev/null && break; sleep 1; done
if ! curl -fs http://localhost:4000/ > /dev/null; then
  echo "the development server did not start; conformance/results.log:"
  cat conformance/results.log
  exit 1
fi
cd conformance

CONFORMANCE="npx @modelcontextprotocol/conformance"
URL=http://localhost:4000/open/mcp
STATUS=0

if [ "${1:-core}" = extensions ]; then
  BASELINE=expected-failures-extensions.yaml

  for scenario in $($CONFORMANCE list --server | sed -n 's/^  - \(.*\) \[extension\]$/\1/p'); do
    $CONFORMANCE server --url "$URL" --scenario "$scenario" --expected-failures "$BASELINE" ||
      STATUS=1
  done

  for scenario in $($CONFORMANCE list --client | sed -n 's/^  - \(.*\) \[extension\]$/\1/p'); do
    $CONFORMANCE client --command ./client.sh --scenario "$scenario" \
      --expected-failures "$BASELINE" || STATUS=1
  done
else
  for version in 2025-06-18 2025-11-25 2026-07-28; do
    $CONFORMANCE server --url "$URL" --suite all --spec-version "$version" \
      --expected-failures expected-failures.yaml || STATUS=1
  done

  for version in 2025-06-18 2025-11-25 2026-07-28; do
    $CONFORMANCE client --command ./client.sh --suite all --spec-version "$version" \
      --expected-failures expected-failures.yaml || STATUS=1
  done

  ./authorization.sh || STATUS=1
fi

# A scenario that fails because a request got no JSON-RPC answer at all
# (a crash, a dropped connection) says nothing more in the suite's own
# output: the development server's log is where the reason is.
if [ "$STATUS" -ne 0 ]; then
  echo "=== the development server's log (conformance/results.log), last 300 lines ==="
  tail -n 300 results.log
fi

exit $STATUS
