gen:
    @xcodegen generate

build:
    @xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug build

build-cli:
    @xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug build

install-cli: build-cli
    #!/usr/bin/env bash
    set -euo pipefail
    dest="$(brew --prefix)/bin"
    src="$(xcodebuild -project Tilr.xcodeproj -scheme TilrCLI -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/tilr"
    cp "$src" "$dest/tilr"
    echo "installed $dest/tilr"

logs:
    #!/usr/bin/env bash
    trap 'kill 0' EXIT
    /usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --level debug --style compact | awk '$1 ~ /^[0-9]{4}-/ { abbr=$3; type=(abbr=="I"?"Info":abbr=="Db"?"Debug":abbr=="E"?"Error":abbr=="Fa"?"Fault":"Default"); msg=""; for(i=5;i<=NF;i++) msg=msg (i==5?"":OFS) $i; cat=""; rest=msg; if (match(msg, /\[[^]]+\] /)) { cat=substr(msg,RSTART+1,RLENGTH-3); rest=substr(msg,RSTART+RLENGTH) }; if (length(cat)>30) cat=substr(cat,1,30); printf "%-8s %-30s %s\n", type, cat, rest; fflush() }'

run-dev: build
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -x Tilr || true
    sleep 0.3
    app="$(xcodebuild -project Tilr.xcodeproj -scheme TilrApp -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/Tilr.app"
    open "$app"
