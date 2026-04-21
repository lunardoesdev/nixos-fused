#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"

require_secrets
cd_repo_root

exec nix build -v "path:.#nixosConfigurations.myhost.config.system.build.toplevel"
