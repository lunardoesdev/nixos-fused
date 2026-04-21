#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly NIX_EXPERIMENTAL_FLAGS=(
  --extra-experimental-features
  "nix-command flakes"
)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cd_repo_root() {
  cd -- "$REPO_ROOT"
}

require_secrets() {
  [[ -f "$REPO_ROOT/secrets.toml" ]] || die "missing $REPO_ROOT/secrets.toml"
}
