#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export ASPNETCORE_ENVIRONMENT=Development
export Hisaab__DevAuth=true
export ASPNETCORE_URLS="${ASPNETCORE_URLS:-http://localhost:5080}"
exec dotnet run --project src/Hisaab.Api --no-launch-profile
