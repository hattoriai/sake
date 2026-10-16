#!/usr/bin/env bash
# The setup script of a Claude Code cloud environment (claude.ai/code).
# The cloud image has no Erlang or Elixir, so this installs the versions
# of .tool-versions from the precompiled builds of builds.hex.pm, then
# Hex and Rebar. The environment caches the result.
#
# Paste the line below into the "Setup script" field of the environment:
#
#   bash scripts/cloud-setup.sh
#
# The network access of the environment must be Custom, with the default
# list and these domains:
#
#   hex.pm
#   repo.hex.pm
#   builds.hex.pm
#
# .claude/hooks/session-start.sh then fetches the dependencies at the
# start of each session.
set -euo pipefail

cd "$(dirname "$0")/.."

tool_version() {
  awk -v tool="$1" '$1 == tool { print $2 }' .tool-versions
}

otp=$(tool_version erlang)
elixir=$(tool_version elixir)
otp_major=${otp%%.*}
elixir=${elixir%-otp-*}

if command -v elixir >/dev/null && elixir --version | grep -q "Elixir $elixir "; then
  echo "Elixir $elixir is already installed."
  exit 0
fi

. /etc/os-release
prefix=/opt/beam
mkdir -p "$prefix"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

arch=$(dpkg --print-architecture)

echo "Installing OTP $otp for $ID-$VERSION_ID ($arch)"
curl -fsSL "https://builds.hex.pm/builds/otp/$arch/$ID-$VERSION_ID/OTP-$otp.tar.gz" -o "$tmp/otp.tar.gz"
mkdir -p "$prefix/otp-$otp"
tar -xzf "$tmp/otp.tar.gz" -C "$prefix/otp-$otp" --strip-components=1
"$prefix/otp-$otp/Install" -minimal "$prefix/otp-$otp" >/dev/null

echo "Installing Elixir $elixir (OTP $otp_major)"
curl -fsSL "https://builds.hex.pm/builds/elixir/v$elixir-otp-$otp_major.zip" -o "$tmp/elixir.zip"
mkdir -p "$prefix/elixir-$elixir"
python3 -m zipfile -e "$tmp/elixir.zip" "$prefix/elixir-$elixir"
chmod +x "$prefix/elixir-$elixir"/bin/*

ln -sf "$prefix/otp-$otp"/bin/* /usr/local/bin/
ln -sf "$prefix/elixir-$elixir"/bin/* /usr/local/bin/

mix local.hex --force
mix local.rebar --force
elixir --version
