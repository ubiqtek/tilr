# Delta 14 — Release on App Store

**Goal:** publish Tilr 1.0 to the macOS App Store under Ubiqtek Ltd.

**Status:** backlog

**Depends on:** Delta 13 (polish) — features must be feature-complete and
stable before submission.

## Scope

### App Store Connect setup

- [ ] Create App Store Connect record under Ubiqtek Ltd team
- [ ] Bundle ID `io.ubiqtek.tilr` registered (already done per CLAUDE.md;
      verify in App Store Connect)
- [ ] Reserve app name "Tilr"
- [ ] Category: Productivity / Developer Tools (decide)
- [ ] Pricing: free / paid? (decide; affects review path)

### Compliance & sandboxing

- [ ] Audit current entitlements — App Store requires sandbox enabled
- [ ] Accessibility API access: requires user-prompted permission, must
      include `NSAccessibilityUsageDescription` with clear rationale
- [ ] AppleEvents (used by `setHiddenViaSystemEvents` fallback): may be
      blocked under sandbox — investigate alternatives
- [ ] File access: state.toml in `~/Library/Application Support/tilr/`
      sits inside the sandbox container automatically; config.toml in
      `~/.config/tilr/` is *outside* — needs user-selected file or
      `com.apple.security.files.user-selected.read-write` entitlement
- [ ] Hotkey registration: Carbon `RegisterEventHotKey` may need review
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`) — required for new
      submissions; declare API usage categories

### Code signing & build

- [ ] Ubiqtek Developer ID + Mac App Store distribution certificates on
      build machine
- [ ] Provisioning profiles for Mac App Store
- [ ] Notarization not required for App Store (App Store review handles
      it), but keep Developer ID build for direct distribution
- [ ] CI/CD: GitHub Actions or local script to produce signed `.pkg`
      ready for upload via Transporter

### App metadata & marketing

- [ ] App icon (1024×1024 + all required sizes)
- [ ] Screenshots: at least 1 for each required display size
- [ ] App description, keywords, support URL, marketing URL
- [ ] Privacy policy URL (required even if no data is collected)
- [ ] Release notes for 1.0

### Distribution coordination

- [ ] Decide: keep Homebrew cask `ubiqtek/tap/tilr` available alongside
      App Store, or deprecate?
- [ ] If keeping both: document migration path (config/state files are
      identical, but App Store version may have stricter file access)
- [ ] Update README and project landing page with App Store badge once
      live

### Submission & review

- [ ] Test build via TestFlight with 2–3 internal users
- [ ] Submit for review; expect 1–7 day turnaround
- [ ] Anticipate rejection reasons: AX permission rationale, sandbox file
      access, or "system utility" classification questions
- [ ] Plan a v1.0.1 hotfix slot for any review-driven changes

## Implementation notes

The biggest unknown is **whether App Store sandboxing breaks Tilr's
window-management features.** AX API works under sandbox with the right
entitlement; the riskier areas are:

- AppleEvents (used as a fallback when `app.hide()` fails)
- Reading config from `~/.config/tilr/` (outside sandbox container)
- Bundle ID lookups via `NSRunningApplication.runningApplications(...)`
  — should work but verify

If sandboxing proves incompatible, fallback is **Developer ID
distribution only** via Homebrew + direct download. Document this
decision before sinking too much time into App Store work.

## Open questions

1. Free or paid? Affects review scrutiny and user expectations.
2. App Store *and* Homebrew, or App Store only? Maintenance cost of two
   channels vs. user reach.
3. Does Apple consider Tilr a "system utility" requiring the special
   review track, or a normal productivity app?
4. Do we need a website (marketing URL, privacy policy host) before
   submission, or can we use GitHub Pages?

## Out of scope

- Paid features / IAP — keep 1.0 simple.
- Auto-update outside the App Store (Sparkle, etc.) — App Store handles
  updates.
- Localisation beyond English — defer to post-1.0.
