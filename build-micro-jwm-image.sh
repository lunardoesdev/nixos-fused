#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"

require_secrets
cd_repo_root

rm -f ./*.raw

nix "${NIX_EXPERIMENTAL_FLAGS[@]}" build -v "path:.#nixosConfigurations.myhost-micro-jwm.config.system.build.diskoImagesScript"
exec ./result
