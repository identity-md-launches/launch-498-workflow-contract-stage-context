#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p docs/abi
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/GrantExecutor.sol:GrantExecutor abi --json > docs/abi/GrantExecutor.json
forge inspect src/CityRegistry.sol:CityRegistry abi --json > docs/abi/CityRegistry.json
