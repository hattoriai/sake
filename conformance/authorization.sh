#!/usr/bin/env bash
# Runs the authorization-server scenarios of the official MCP conformance
# suite against the development server's own authorization server, which
# must already be running on http://localhost:4000 (run.sh starts it).
#
# The authorization-code-grant scenario prints an authorization URL and
# waits for a person to sign in and approve in a browser; this script is
# that person. It registers a public client through dynamic client
# registration (the suite needs a pre-registered client with its own
# callback as a redirect URI), then plays the browser with curl: it signs
# in as ana@example.com, approves the consent page, and follows the
# redirect back to the suite's callback server.
set -euo pipefail
cd "$(dirname "$0")"

AS=http://localhost:4000
PORT=${CONFORMANCE_CALLBACK_PORT:-3000}
LOG=$(mktemp)
JAR=$(mktemp)
trap 'rm -f "$LOG" "$JAR"' EXIT

CLIENT_ID=$(
  curl -fsS "$AS/oauth/register" \
    -H 'content-type: application/json' \
    -d "{\"client_name\":\"MCP conformance\",\"redirect_uris\":[\"http://127.0.0.1:$PORT/callback\"]}" |
    jq -r .client_id
)

# `--resource` names one of the dev server's protected endpoints: it
# serves three, so an authorization request without one is ambiguous and
# refused with `invalid_target`.
npx @modelcontextprotocol/conformance authorization --url "$AS" --client-id "$CLIENT_ID" \
  --resource "$AS/mcp" --port "$PORT" > "$LOG" 2>&1 &
SUITE=$!

URL=""
for _ in $(seq 1 60); do
  URL=$(grep -m1 -o "^$AS/oauth/authorize?.*" "$LOG" || true)
  [ -n "$URL" ] && break
  kill -0 "$SUITE" 2> /dev/null || break
  sleep 1
done

if [ -n "$URL" ]; then
  # Sign in; the login form sends the person back to the authorization URL.
  curl -fsS -c "$JAR" -b "$JAR" -o /dev/null "$AS/login" \
    --data-urlencode "email=ana@example.com" --data-urlencode "password=secret" \
    --data-urlencode "return_to=${URL#"$AS"}"

  # The consent page; approve it with the signed request it carries.
  REQUEST=$(curl -fsS -c "$JAR" -b "$JAR" "$URL" | sed -n 's/.*name="request" value="\([^"]*\)".*/\1/p')

  CALLBACK=$(
    curl -sS -c "$JAR" -b "$JAR" -o /dev/null -w '%{redirect_url}' "$AS/oauth/authorize" \
      --data-urlencode "request=$REQUEST" --data-urlencode "decision=approve" \
      --data-urlencode "_csrf_token="
  )

  curl -fsS -o /dev/null "$CALLBACK"
fi

STATUS=0
wait "$SUITE" || STATUS=$?
cat "$LOG"
exit "$STATUS"
