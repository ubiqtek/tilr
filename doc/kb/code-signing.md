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
Verified working with `MX95X5U6HA` (Ubiqtek Ltd) for both dev and distribution builds as of 2026-05-02.
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

## Debugging signing problems

The `security find-identity` display is misleading. The `(...)` shown after the
developer name (e.g. `"Apple Development: James Barritt (467SK9M4UB)"`) is a
cosmetic legacy account-level identifier, **not** the team ID. xcodebuild
matches against the `OU` field in the certificate.

**Authoritative checks:**

- For a built binary: `codesign -dvv /path/to/app | grep TeamIdentifier`
- For raw certs in the keychain: `security find-certificate -c "Apple Development" -p -a | openssl pkcs7 -print_certs | grep subject=`
  and read the `OU` field (format: `OU=<TEAM_ID>, O=<COMPANY>`).

xcodebuild from the CLI needs `-allowProvisioningUpdates` to auto-fetch
provisioning profiles. This is already set in the `justfile`.

**Troubleshooting: "No signing certificate" / "No Account for Team"**

1. Check the actual cert OU with the openssl command above — does any cert have `OU=<your DEVELOPMENT_TEAM>`?
2. If not, the team ID in `project.yml` is wrong. Find the correct one and update both `project.yml` and `ops/local/local.env`, then `just gen`.
3. If yes but build still fails, ensure the relevant Apple ID is signed into Xcode → Settings → Accounts.

## Distribution builds

Distribution uses a separate Apple Distribution identity, configured at
archive time. The `DEVELOPMENT_TEAM` in `project.yml` covers development
builds only.
