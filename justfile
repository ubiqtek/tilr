gen:
    @xcodegen generate

version:
    @scripts/stamp-version.sh --print

build:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD_ID=$(openssl rand -hex 2)
    SRCROOT="$(pwd)" TILR_BUILD_ID="$BUILD_ID" scripts/stamp-version.sh
    xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug build -allowProvisioningUpdates TILR_BUILD_ID=$BUILD_ID

build-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD_ID=$(openssl rand -hex 2)
    SRCROOT="$(pwd)" TILR_BUILD_ID="$BUILD_ID" scripts/stamp-version.sh
    xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug build -allowProvisioningUpdates TILR_BUILD_ID=$BUILD_ID

build-all:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD_ID=$(openssl rand -hex 2)
    echo "Build ID: $BUILD_ID"
    SRCROOT="$(pwd)" TILR_BUILD_ID="$BUILD_ID" scripts/stamp-version.sh
    xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug build -allowProvisioningUpdates TILR_BUILD_ID=$BUILD_ID
    xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug build -allowProvisioningUpdates TILR_BUILD_ID=$BUILD_ID

install-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-all
    dest="$(brew --prefix)/bin"
    src="$(xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/tilr"
    cp "$src" "$dest/tilr"
    echo "installed $dest/tilr"

logs:
    #!/usr/bin/env bash
    trap 'kill 0' EXIT
    /usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --level debug --style compact | awk '$1 ~ /^[0-9]{4}-/ { abbr=$3; type=(abbr=="I"?"Info":abbr=="Db"?"Debug":abbr=="E"?"Error":abbr=="Fa"?"Fault":"Default"); msg=""; for(i=5;i<=NF;i++) msg=msg (i==5?"":OFS) $i; cat=""; rest=msg; if (match(msg, /\[[^]]+\] /)) { cat=substr(msg,RSTART+1,RLENGTH-3); rest=substr(msg,RSTART+RLENGTH) }; if (length(cat)>30) cat=substr(cat,1,30); printf "%-8s %-30s %s\n", type, cat, rest; fflush() }'

logs-capture:
    #!/usr/bin/env bash
    trap 'kill 0' EXIT
    mkdir -p .tilr-logs
    : > .tilr-logs/session.log
    echo "capturing to .tilr-logs/session.log — Ctrl-C to stop"
    /usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --level debug --style compact | awk '$1 ~ /^[0-9]{4}-/ { ts=$2; sub(/\+[0-9]+$/, "", ts); sub(/\.[0-9]+$/, "", ts); abbr=$3; type=(abbr=="I"?"Info":abbr=="Db"?"Debug":abbr=="E"?"Error":abbr=="Fa"?"Fault":"Default"); msg=""; for(i=5;i<=NF;i++) msg=msg (i==5?"":OFS) $i; cat=""; rest=msg; if (match(msg, /\[[^]]+\] /)) { cat=substr(msg,RSTART+1,RLENGTH-3); rest=substr(msg,RSTART+RLENGTH) }; if (length(cat)>30) cat=substr(cat,1,30); printf "%s %-8s %-30s %s\n", ts, type, cat, rest; fflush() }' >> .tilr-logs/session.log

local-logs:
    tail -f ~/.local/share/tilr/tilr.log

run-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    # Kill any running instances first
    pkill -x Tilr || true
    sleep 0.3
    BUILD_ID=$(openssl rand -hex 2)
    echo "Build ID: $BUILD_ID"
    SRCROOT="$(pwd)" TILR_BUILD_ID="$BUILD_ID" scripts/stamp-version.sh
    xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug build -allowProvisioningUpdates TILR_BUILD_ID=$BUILD_ID
    xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug build -allowProvisioningUpdates TILR_BUILD_ID=$BUILD_ID
    # Install CLI from the just-built binary so system tilr matches the app
    dest="$(brew --prefix)/bin"
    cli_src="$(xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/tilr"
    cp "$cli_src" "$dest/tilr"
    echo "installed $dest/tilr"
    # Now launch the app
    sleep 0.3
    app="$(xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/Tilr.app"
    open "$app"
    echo ""
    echo "Launched Tilr build ID: $BUILD_ID"
    echo "App: $app"

install: build
    #!/usr/bin/env bash
    set -euo pipefail
    src="$(xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/Tilr.app"
    pkill -x Tilr || true
    sleep 0.3
    rm -rf /Applications/Tilr.app
    cp -R "$src" /Applications/Tilr.app
    echo "installed /Applications/Tilr.app — launch via 'open -a Tilr' or Spotlight"
