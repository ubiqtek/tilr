# Code signing

Tilr uses XcodeGen — `project.yml` is the source of truth and `just gen`
fully regenerates `Tilr.xcodeproj`. Any signing setting configured manually
in Xcode is wiped on the next `just gen`.

## Why DEVELOPMENT_TEAM must be set in project.yml

macOS TCC ties Accessibility permission grants to a binary's code signature.
When no team is set, Xcode uses ad-hoc signing which produces a different
signature hash on every build. TCC sees a new app each time and revokes the
AX grant, forcing a re-approve after every rebuild.

Setting `DEVELOPMENT_TEAM` in `project.yml` gives every debug build a stable,
team-signed identity. AX permission is granted once and survives rebuilds.

## Sensitive values

Team IDs and developer email are stored in `ops/local/local.env` (gitignored).
See that file for the actual values.

## project.yml setting

```yaml
settings:
  base:
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: <value from ops/local/local.env TILR_DEVELOPMENT_TEAM>
```

`DEVELOPMENT_TEAM` must never be blanked out. If you see AX permission being
revoked on every build, check this setting first.

## Distribution builds

Distribution uses a separate Apple Distribution identity, configured at
archive time. The `DEVELOPMENT_TEAM` in `project.yml` covers development
builds only.
