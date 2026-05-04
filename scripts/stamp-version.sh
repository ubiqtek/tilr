#!/usr/bin/env bash
set -euo pipefail

# stamp-version.sh — writes a build/Generated/Version.xcconfig with the dynamic
# version suffix so Xcode can interpolate it into both targets' Info.plist.
#
# In Xcode build phase: SRCROOT, MARKETING_VERSION, TILR_RELEASE are set by Xcode.
# With --print: prints what would be stamped without writing any file.

print_only=0
if [ "${1:-}" = "--print" ]; then
    print_only=1
    # Use sensible defaults for manual invocation
    SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    MARKETING_VERSION="${MARKETING_VERSION:-0.0.1}"
    TILR_RELEASE="${TILR_RELEASE:-0}"
fi

base="${MARKETING_VERSION:-0.0.1}"
out="${SRCROOT}/build/Generated/Version.xcconfig"

is_release="${TILR_RELEASE:-0}"
if [ "$is_release" = "1" ]; then
    suffix=""
else
    git_hash="$(cd "${SRCROOT}" && git rev-parse --short=4 HEAD 2>/dev/null || echo nogit)"
    build_id="${TILR_BUILD_ID:-$(openssl rand -hex 2)}"
    suffix="-local-${git_hash}-${build_id}"
fi

build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$print_only" = "1" ]; then
    echo "${base}${suffix}"
    exit 0
fi

mkdir -p "$(dirname "$out")"
cat > "$out" <<EOF
// AUTO-GENERATED — do not edit. Stamped by scripts/stamp-version.sh.
TILR_VERSION_SUFFIX = $suffix
TILR_BUILD_DATE = $build_date
EOF
