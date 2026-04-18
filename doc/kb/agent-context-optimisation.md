# Agent context optimisation

Guidelines for reducing context burn during long coding sessions by
delegating work to subagents. Derived from real practice in the Tilr
project; intended to be portable to other projects.

## The principle

The primary session's context is the scarce resource. Every file read,
every tool result, every diff stays in that context until it's compressed
or the session ends. Subagents start cold — they see only their prompt,
not the conversation — and their result comes back as a short summary.

The trade: more total tokens (the subagent reads things too), but fewer
tokens in the primary context. For long sessions, that trade pays off
for any task a subagent can handle self-contained.

## Rule of thumb

> If editing this file would require me to `Read` it first, delegate.
> If the edit is a word or two I already have in mind, stay inline.

## Agent tier selection

Match the agent model to the task:

| Task | Agent type | Model | Why |
|---|---|---|---|
| Code changes, refactoring | general-purpose | **Sonnet** | Needs judgment; must not introduce bugs |
| Doc / plan / markdown edits | general-purpose | **Haiku** | Mechanical text manipulation |
| Codebase exploration | Explore | Sonnet (default) | Specialised for search |
| Multi-step research across files | general-purpose | Sonnet | Needs to reason across findings |
| Architecture planning | Plan | Sonnet (default) | Needs design judgment |

Override the model via the `model` parameter when spawning. Default is
inherited from the agent definition.

## Primary thread: Opus or Sonnet?

The same model-selection question applies to the primary conversation,
and it's harder than choosing a subagent model. The dilemma:

- Opus is the most capable model. Defaulting to it avoids the "I should
  have used the smarter model for this" regret.
- Opus is materially more expensive per turn. Over a long session full of
  routine turns, you're paying for capability you don't need.
- The decision often hits you *after* you've already started typing — at
  which point switching feels like friction and most people just send the
  message in whatever mode they're in.

There's no perfect rule. A few framings that help:

### The underlying tradeoff

The choice of default is really a choice of failure mode:

- **Default to Sonnet** — cheaper per turn, but costs *rework* when
  Sonnet gives a shallow or wrong answer and you have to re-ask in Opus.
  Rework is paid in time and context re-establishment, not just tokens.
- **Default to Opus** — pay upfront on every turn, including the many
  where Sonnet would have done fine.

The right default depends on how well you can predict in advance which
kind of turn is coming. That intuition takes practice: it's easy to
under-estimate how much routine execution Sonnet handles competently, and
equally easy to over-estimate how obvious it is in advance that a
question needs Opus. Until that intuition calibrates, leaning toward Opus
on any design-shaped turn tends to cost less in rework than leaning
toward Sonnet costs in regret — but the cost of being wrong shrinks as
you get better at recognising which kind of turn you're starting.

**Concrete heuristic to lean on while calibrating:** if you already know
the direction and you're about to do something mechanical — applying an
agreed plan, making a list of known edits, running through a checklist —
switch to Sonnet. You've already done the Opus-shaped thinking; the
remaining turns are execution, and Sonnet executes well and faster.
Updating a plan or a document to reflect a decision already made is a
clear example — no novel thinking required, just accurate transcription
of what was decided.

### What Opus actually gives you

Opus is worth the cost when the turn needs:

- **Tradeoff reasoning** — architecture design, comparing approaches,
  spotting subtle invariants.
- **Judgment under ambiguity** — when you don't yet know what you're
  asking for, or the "right" answer isn't obvious.
- **Deep debugging** — problems where the wrong hypothesis wastes an hour.
- **Critique** — reviewing designs, catching what you missed. Opus is
  notably better at "what about X?" than Sonnet.

Sonnet handles most other things competently, usually faster. If the
thinking is already done and you're executing, Sonnet is fine — and the
faster response loop often matters more than the extra capability.

### The real optimisation: subagents, not primary-thread switching

The cleanest answer to the dilemma is to stop treating it as "which model
runs everything" and structure work so the primary thread does thinking
and subagents do execution:

- **Opus primary + Sonnet subagents** — thinking happens in Opus, code
  gets written by Sonnet agents invoked from the Opus thread. Primary
  context stays focused on decisions.
- **Opus primary + Haiku subagents** — same idea, cheaper still for
  mechanical work.

This pattern makes the primary model choice less critical, because the
expensive turns are the ones where you genuinely need Opus-level
capability. Most of the "should I have used Sonnet for that?" regret
disappears when the mechanical work is delegated anyway.

### Session-level heuristic

Decide at session start based on intent, not turn by turn:

| Session intent | Primary model |
|---|---|
| Designing something / figuring out what to build | Opus |
| Reviewing a PR / critiquing an approach / deep debugging | Opus |
| Executing a plan already agreed on | Sonnet |
| Grinding through a known list of changes | Sonnet |
| Mixed design + execution | Opus, with Sonnet subagents for execution |

Session-level decisions cost less cognitive overhead than turn-level
decisions, and the "wrong" choice within a session is usually fine.

### When to switch mid-session

Switch **Opus → Sonnet** when:

- The design phase ended; the remaining turns are known execution.
- The user has said something like "ok, implement it".
- You're in a rapid iteration loop where response speed matters more
  than depth.

Switch **Sonnet → Opus** when:

- Sonnet is floundering on something — repeated wrong hypotheses, shallow
  answers, missing the point.
- A design question has surfaced that needs real judgment.
- You're about to make a high-stakes or hard-to-reverse decision.

### The "already typing" problem

You realise mid-message you're in the wrong mode. Options, least to most
disruptive:

1. **Send it anyway.** One suboptimal turn is cheap. Don't optimise at
   turn granularity.
2. **Finish typing, then switch before sending** if the UI preserves the
   draft.
3. **Cancel, switch, retype** — only for turns that are genuinely
   expensive (big analysis, big implementation).

Optimise at the session level; accept noise within the session.

### Start low, escalate as needed

Before prompting, think for a moment: what's the actual task? Then start
with the lowest-capability model that plausibly handles it, and escalate
only if it falters.

- "Show me the plan"? → Haiku.
- "Update the plan to reflect this decision"? → Haiku.
- "Explain this code to me"? → Sonnet.
- "Is this architecture pattern a good fit here?" → Opus.

Most requests that feel like they need Opus actually don't — they need
Sonnet. And many that feel like they need Sonnet can be done by Haiku.
The default bias should be *toward* cheaper, with escalation as a
deliberate move, not a starting point.

### Recommendation

- Default to Opus for sessions involving design, judgment, or critique.
- Default to Sonnet for sessions that are primarily execution.
- Use subagents aggressively — the primary thread rarely needs to be
  the one doing mechanical work, regardless of which model it's on.
- Don't agonise over mid-session switches. The session-level choice
  matters far more than any single turn.

## When to delegate

- You'd need to `Read` a file of 100+ lines to make the edit.
- The task is self-contained — inputs fit in a prompt, outputs fit in a
  summary.
- The work spans multiple files (broad codebase exploration) — agents
  parallelise and keep raw search results out of the primary context.
- The work is mechanical — pattern-matching, formatting, renumbering — and
  adds little to the primary thread's reasoning.

## When to stay inline

- The edit is 1–2 lines of content already in mind.
- You need to see the output to decide the next step — delegation adds a
  round trip.
- The task requires ongoing back-and-forth with the user.
- The content IS the synthesis — e.g. drafting a design doc from a
  conversation; the prompt would contain the whole doc anyway.

## Briefing agents well

A subagent is a smart colleague who just walked into the room. No prior
context, no conversation history, no assumed shared knowledge.

**Do:**

- State the goal and context in a self-contained prompt.
- Give absolute paths, not relative.
- Specify scope explicitly: "do X, not Y".
- Say what form of reply you want: "report under 200 words", "give me a
  diff summary".
- Tell agents when not to read: "don't read more of the file than you
  need to — jump straight to the relevant section".
- For doc edits: include the semantic content you want inserted; let the
  agent handle formatting to match the file's existing style.
- For code changes: include the architecture decisions you've already
  made (naming, scope, design) so the agent executes rather than
  designs.

**Don't:**

- Write "based on your findings, make the fix" — that delegates
  understanding. You do the synthesis; the agent does the execution.
- Assume the agent can see your conversation — it can't.
- Send terse command-style prompts — they produce shallow, generic
  work.

## Common patterns

**Doc/plan edits** — Brief a haiku agent with the content of the edit.
The agent reads the file, matches style, inserts. Returns a short
summary of changed lines.

**Code edits** — Brief a Sonnet agent with the design already decided
(architecture, naming, scope, files involved). The agent implements and
reports back files changed and build status. Review the diff yourself.

**Codebase questions** — Use Explore or general-purpose with a clear
research question. Don't run your own Grep in parallel — that defeats the
purpose.

**Background tasks** — For long-running work (build verification, test
runs), use `run_in_background: true`. You get notified on completion and
can do other work in the meantime.

## What never to delegate

- **Decisions.** Synthesise yourself.
- **Understanding what the user wants.** That's your job.
- **Final user-facing responses.** Agents' results come to you as tool
  output; you relay a summary to the user.
- **Tasks that need your conversation context.** The agent can't see it.

## The drift

It is easy to drift into doing "just one small change" inline. That one
`Read` costs 3–5% of context. Over a long session, dozens of small
inline edits compound into exhausted context or early compression. When
in doubt, delegate.

## Related memories

- `feedback_subagent_coding` — code changes go through a Sonnet subagent,
  never inline.
- `feedback_haiku_doc_edits` — structural doc/plan edits go through a
  haiku subagent, never inline.
