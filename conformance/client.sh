#!/usr/bin/env bash
cd "$(dirname "$0")/.." && exec mix run conformance/client.exs -- "$@"
