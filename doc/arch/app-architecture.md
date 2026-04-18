# App Architecture

Collaborator map for the Tilr macOS app. This document describes the
**target** structure after the domain-layer refactor (not the current
`AppDelegate`-does-everything shape). See `doc/plan.md` for delta status.

## Shape

Ports and adaptors. One pure domain service, many adaptors around it.

- **`SpaceService`** is the domain. Commands go in, events come out, state
  is private. It does no I/O other than persisting its own state.
- Everything else is an **adaptor**. Input adaptors (hotkeys, CLI) translate
  user actions into commands. Output adaptors (window management, popup,
  menu bar) subscribe to domain events and do one job each.
- Adaptors don't know about each other. They all know `SpaceService`.

## Goals

- One code path for every space change — regardless of whether a hotkey,
  a CLI command, or a config reload triggered it.
- Domain knows nothing about UI or window APIs. Adaptors know nothing
  about each other.
- All domain logging happens in one place (`SpaceService`).
- Config is a live, observable value — runtime changes take effect
  without re-wiring.

## Collaborator diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│                             AppDelegate                                 │
│                         (lifecycle + wiring)                            │
└────────────────────────────────────────────────────────────────────────┘

──── INPUT ADAPTERS (translate user actions → domain commands) ───────────

    ┌──────────────────┐                    ┌──────────────────┐
    │   HotKeyManager  │                    │  CommandHandler  │
    │  (Carbon events) │                    │  (socket / CLI)  │
    └─────────┬────────┘                    └─────────┬────────┘
              │       switchToSpace(name, reason)     │
              └───────────────────┬───────────────────┘
                                  ▼  (command)

──── DOMAIN (pure — commands in, events out, state private) ──────────────

          ┌────────────────────────────────────────────┐
          │                SpaceService                │     ┌──────────────┐
          │                                            │read │ ConfigStore  │
          │   Commands:                                │────►│ @Published   │
          │     switchToSpace(name, reason)            │     │   current    │
          │     applyConfig(reason)                    │     └──────────────┘
          │                                            │
          │   Read-only state:                         │
          │     activeSpace: String?                   │
          │                                            │
          │   ┌────────────────────────────────────┐   │
          │   │  private StateStore                │   │
          │   │   - in-memory activeSpace          │   │
          │   │   - load/save state.toml           │   │
          │   └────────────────────────────────────┘   │
          │                                            │
          │   Events (out):                            │
          │     onSpaceActivated(name, reason) ────┐   │
          │     onNotification(message) ───────────┤   │
          └────────────────────────────────────────┼───┘
                                                   │ events
                      ┌────────────────────────────┼────────────────────────┐
                      │                            │                        │
                      ▼                            ▼                        ▼

──── OUTPUT ADAPTERS (subscribe to events; each does one job) ────────────

  ┌───────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
  │  AppWindowManager     │   │   UserNotifier       │   │ MenuBarController    │
  │  - hide non-space     │   │  - reads ConfigStore │   │  - updates menu bar  │
  │    apps               │   │    for popup policy  │   │    title             │
  │  - show space's apps  │   │  - owns PopupWindow  │   │                      │
  │  - apply layout       │   │                      │   │                      │
  │  (NSRunningApp + AX)  │   │                      │   │                      │
  └───────────────────────┘   └──────────┬───────────┘   └──────────────────────┘
                                         │ show(message)
                                         ▼
                                 ┌────────────────┐
                                 │   PopupWindow  │  (dumb view — no logic,
                                 └────────────────┘   no logging, no config)
```

## Layer responsibilities

| Role | Component | Responsibility |
|---|---|---|
| Wiring | `AppDelegate` | Construct all collaborators; wire subscriptions; signal handling. |
| Shared store | `ConfigStore` | Single source of truth for `TilrConfig`. `@Published current`. Reloads on demand. |
| Input adaptor | `HotKeyManager` | Carbon key events → `SpaceService` commands. Holds `ConfigStore` to know which keys to register; re-registers when config changes. |
| Input adaptor | `CommandHandler` | Socket commands → `SpaceService` / `ConfigStore`. No UI references. |
| Domain | `SpaceService` | The only place space changes happen. `@MainActor`. Owns `StateStore` privately (in-memory + `state.toml` persistence). Exposes `activeSpace` read-only. Emits events. Does no I/O besides state persistence. Owns all domain logging. |
| Output adaptor | `AppWindowManager` | Subscribes to `onSpaceActivated`. Reads the `Space` definition from `ConfigStore` and applies it: hides apps not in the space, shows apps that are, runs the layout engine to position windows. Talks to `NSRunningApplication` and Accessibility APIs. |
| Output adaptor | `UserNotifier` | Subscribes to `onSpaceActivated` and `onNotification`. Reads `ConfigStore.popups` to decide whether to show a popup per reason. Owns `PopupWindow`. Future home for sounds/haptics. |
| Output adaptor | `MenuBarController` | Subscribes to `onSpaceActivated`. Updates menu bar title. |
| Leaf view | `PopupWindow` | Pure view. No subscriptions, no config awareness, no logging. |

## Activation reasons

Every space change carries a reason. The reason travels through events for
observability (it ends up in the log line) and lets adaptors apply the right
policy per reason:

```swift
enum ActivationReason {
    case hotkey         // user-initiated switch
    case cli            // user-initiated switch
    case configReload   // system event
    case startup        // system event
}
```

`AppWindowManager` ignores the reason — a switch is a switch, windows are
applied the same way. `UserNotifier` and `MenuBarController` care.

**Popup policy (decided in `UserNotifier` only):**

| Reason | Popup shown? |
|---|---|
| `.hotkey` | if `config.popups.whenSwitchingSpaces` |
| `.cli`    | if `config.popups.whenSwitchingSpaces` |
| `.configReload` | always |
| `.startup`      | always |

Hotkey and CLI are both "user switched to a space" — they share the same
config-driven policy. The enum keeps them distinct for logs, not for policy.
If a new input source is added later (e.g. menu bar click), it joins the same
group: a new reason whose popup behaviour the presenter groups with the others.

## Event channels

`SpaceService` fires two distinct event types:

- **`onSpaceActivated(name, reason)`** — a real space is now active.
  Internal state is updated and persisted. All three output adaptors may react:
  `AppWindowManager` applies the space's apps and layout, `UserNotifier` may
  show a popup (per reason), `MenuBarController` updates the title.
- **`onNotification(message)`** — a user-visible message with no state
  change (e.g. `"↺ Config"` when config reload has no default space to
  activate). Only `UserNotifier` reacts. State and window layout are untouched.

This separation guarantees the service's `activeSpace` only ever holds real
space names — never `"Tilr"`, `"↺ Config"`, or any other transient UI string —
and that `AppWindowManager` never rearranges windows for a non-activation.

## Interaction flows

### Startup

```
AppDelegate → service.applyConfig(reason: .startup)
              ├─ service loads state.toml (if present)
              ├─ resolves space to activate:
              │     persisted activeSpace (if still in config)
              │     else display 1 default
              ├─ updates internal state + persists state.toml
              ├─ Logger.space.info("activating 'Coding' (startup)")
              └─ onSpaceActivated("Coding", .startup)
                      ├→ AppWindowManager applies the Space
                      ├→ UserNotifier shows popup (startup → always)
                      └→ MenuBarController sets title "[Coding]"
```

### Hotkey press (cmd+opt+1)

```
HotKey callback → service.switchToSpace("Coding", reason: .hotkey)
                  ├─ updates internal state + persists state.toml
                  ├─ Logger.space.info("switching to 'Coding' (hotkey)")
                  └─ onSpaceActivated("Coding", .hotkey)
                          ├→ AppWindowManager applies the Space
                          ├→ UserNotifier reads config.popups, shows popup
                          └→ MenuBarController updates title
```

### CLI `tilr switch Reference`

```
Socket → CommandHandler → service.switchToSpace("Reference", reason: .cli)
                          (same flow as hotkey, different reason —
                           UserNotifier groups .cli with .hotkey for popup policy)
```

### Config reload

```
CLI `tilr reload-config` → CommandHandler
    ├─ configStore.reload()                   → @Published fires
    │                                           └→ HotKeyManager re-registers
    └─ service.applyConfig(reason: .configReload)
         ├─ CASE A: display 1 has default
         │    ├─ updates internal state + persists state.toml
         │    └─ onSpaceActivated("Coding", .configReload)
         │           ├→ AppWindowManager re-applies the Space
         │           ├→ UserNotifier always shows popup for .configReload
         │           └→ MenuBarController updates title
         │
         └─ CASE B: no default configured
              └─ onNotification("↺ Config")
                      └→ UserNotifier shows popup
                      (state untouched; no window changes; menu bar unchanged)
```

## Reference graph

No component except `AppDelegate` sees everything. Each collaborator holds
only the references it needs:

| Holder | Holds |
|---|---|
| `AppDelegate` | Everything (wiring only) |
| `SpaceService` | `ConfigStore`, private `StateStore` |
| `HotKeyManager` | `ConfigStore`, `SpaceService` |
| `CommandHandler` | `ConfigStore`, `SpaceService` |
| `AppWindowManager` | `ConfigStore`, service subscription |
| `UserNotifier` | `ConfigStore`, `PopupWindow`, service subscriptions |
| `MenuBarController` | service subscription |
| `PopupWindow` | nothing — pure sink |

## Invariants

1. Every space change goes through `SpaceService.switchToSpace` —
   one log line, one state write, one event.
2. `SpaceService.activeSpace` is only ever the name of a real configured
   space, or `nil`. Never a UI string.
3. Only `SpaceService` mutates active-space state. Every other
   component reads it through events or the read-only property.
4. The domain has no UI or window-API knowledge. It emits events; adaptors
   translate events into side effects.
5. Each output adaptor has exactly one job (windows / notifications / menu
   bar). They don't know about each other.
6. Popup visibility is decided in exactly one place (`UserNotifier`).
7. Config is read live via `ConfigStore`, so runtime config changes take
   effect with no re-wiring.
8. `PopupWindow` is a leaf — it has no upward dependencies and no logging.

## Logger categories

| Category | Purpose |
|---|---|
| `Logger.app` | Lifecycle (launch, terminate, signal handling). |
| `Logger.space` | Domain events: space switches, config apply. **All space-change logging lives here.** |
| `Logger.hotkey` | Hotkey registration and warnings. No per-press logging. |
| `Logger.socket` | Socket server lifecycle and command dispatch. |
| ~~`Logger.popup`~~ | **Removed.** The popup is a pure view. |

## Live config reload

`ConfigStore.current` is `@Published`. Collaborators that depend on config
subscribe to it and react to changes automatically. No manual re-wiring.

- **`HotKeyManager`** subscribes to `ConfigStore.current`. On change, it
  unregisters all existing hotkeys and re-registers from the new config.
  Adding/removing/renaming spaces in the config takes effect immediately on
  `tilr reload-config`.
- **`UserNotifier`** reads `ConfigStore.current.popups` lazily each time a
  space event arrives — toggling `popups.whenSwitchingSpaces` in config and
  reloading takes effect for the next key press with no subscription logic.
- **`SpaceService`** reads `ConfigStore.current` lazily when resolving
  spaces or display defaults.

The reload flow:

```
CLI `tilr reload-config` → CommandHandler
    ├─ configStore.reload()          → @Published fires
    │                                  └→ HotKeyManager re-registers hotkeys
    └─ service.applyConfig(reason: .configReload)
         └─ activates display 1 default (or fires onNotification)
```
