gen:
    @xcodegen generate

build:
    @xcodebuild -project Tilr.xcodeproj -scheme Tilr -configuration Debug build

logs:
    @/usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --level debug | awk 'NR>1 { type=$4; msg=""; for(i=8;i<=NF;i++) msg=msg (i==8?"":OFS) $i; cat=""; rest=msg; if (match(msg, /\[[^]]+\] /)) { cat=substr(msg,RSTART+1,RLENGTH-3); rest=substr(msg,RSTART+RLENGTH) } if (length(cat)>30) cat=substr(cat,1,30); printf "%-8s %-30s %s\n", type, cat, rest }'

run-dev: build
    @open "$(xcodebuild -project Tilr.xcodeproj -scheme Tilr -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/Tilr.app"
