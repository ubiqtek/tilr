# Terminal Tips

Collection of terminal utilities and tricks for better command-line ergonomics.

---

## Preventing line wrapping

Long lines in terminal output are often wrapped to fit the window width, which
can make output hard to read when you want to see the full line. Here are
three approaches to prevent wrapping.

### `tput rmam` / `smam` — disable automatic margins

Disables the terminal's automatic margin mode entirely, so text doesn't wrap
even if it exceeds the window width. Text continues off-screen; scroll
horizontally to see it.

```bash
# Disable wrapping
tput rmam

# ... run your command ...
my-long-output-command

# Re-enable wrapping when done
tput smam
```

**Use case:** When you want to see the full line and scroll horizontally to
read it. Useful for structured output like logs, diffs, or config dumps.

**Gotcha:** If you forget to re-enable (`tput smam`), the terminal stays in
no-wrap mode for the rest of your session. Easy to fix: type `tput smam` and
press Enter.

### `less -S` — chop long lines

Pass output to `less` with the `-S` flag, which truncates long lines instead
of wrapping them. Use arrow keys (left/right) to scroll horizontally within
the pager.

```bash
my-long-output-command | less -S
```

**Use case:** Interactive exploration of long-line output. Press `→` to scroll
right and see more of the current line; `←` to scroll back left.

**Why it's nicer than `rmam`:** You're in a pager (so you can search, navigate,
quit cleanly), and horizontal scrolling is built-in.

### One-liner: `tput rmam && <command> && tput smam`

Chain the commands so wrapping is restored automatically when the command
finishes:

```bash
tput rmam && my-long-output-command && tput smam
```

Or in a subshell to isolate side effects:

```bash
(tput rmam; my-long-output-command)
tput smam
```

---

## When to use which

| Scenario | Method | Why |
|---|---|---|
| Piping to a file or another command | `tput rmam` | No pager overhead; preserves raw output |
| Interactive exploration | `less -S` | Built-in navigation, search, easy exit |
| One-shot command, want auto-restore | `tput rmam && cmd && tput smam` | Clean, no dangling state |
| Debugging terminal output | `tput rmam` | See the exact output without re-wrapping |
