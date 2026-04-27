# Delta 11 — Release on App Store

**Goal:** Prepare Tilr for macOS App Store distribution and publish the initial release.

**Status:** planning

## Scope

- [ ] Create App Store Connect record and gather required metadata
- [ ] App Store compliance review (sandbox permissions, entitlements, privacy)
- [ ] Code signing and provisioning certificates
- [ ] Build and submit to App Store review
- [ ] Coordinate Homebrew cask deprecation (existing installation via ubiqtek/tap)
- [ ] User migration guide (config/state file location expectations)
- [ ] Release notes for initial public release

## Implementation notes

App Store distribution replaces the Homebrew cask as primary distribution channel. Current Homebrew installation remains available for users who prefer it, but marketing points to App Store.

Migration path: Users keep existing ~/.config/tilr/config.toml and ~/Library/Application Support/tilr/state.toml; App Store version reads the same locations.

## Open questions

1. Should we deprecate the Homebrew cask immediately on App Store launch, or keep both available?
2. What privacy disclosures are needed for Accessibility API usage?
