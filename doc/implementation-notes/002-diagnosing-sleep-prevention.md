# Diagnosing sleep prevention

## Symptoms

Machine fails to sleep when idle.

## Diagnostic command

```
pmset -g assertions
```

Shows all processes holding power assertions. Key fields to look for:

- `PreventUserIdleSystemSleep` — prevents idle sleep
- `PreventSystemSleep` — prevents all sleep
- `caffeinate command-line tool` — explicit caffeinate invocation
- Kernel assertions: `USB` — a USB device is holding sleep

## Known culprits found (2026-05-02)

### caffeinate process

A `caffeinate -i -t 300` process was running, spawned by the Claude Code CLI
session from the tilr project directory. `caffeinate` is a built-in macOS tool
(`/usr/bin/caffeinate`) — it can be called by any process or script.

To identify who spawned it:

```
ps aux | grep caffeinate          # get the PID
ps -o ppid= -p <PID> | xargs ps -p  # find parent process
```

To kill it:

```
kill <PID>
```

### USB device assertion

A connected USB device (e.g. webcam) can hold a `0x4=USB` kernel assertion
that prevents idle sleep. Visible in `pmset -g assertions` under
`Kernel Assertions`. Unplugging the device clears it.

## Summary

Run `pmset -g assertions` first. If `caffeinate` is listed, find and kill it.
If a USB kernel assertion is listed, identify the device and unplug it if
sleep is needed.
