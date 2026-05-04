# Delta 13: Rearchitect to Pipeline

**See also:** [Tilr Delta Progress](plan.md) for full project roadmap

**Status: PLANNING**

Refactor Tilr's core architecture to the **Input → Plan → Execute → Record** pipeline model defined in `doc/arch/tilr-arch-v2.md`. This eliminates redundant state diffing, preserves command intent through all phases, and makes state a trailing record of what AX actually achieved (crucial for Zen hide and other AX quirks).

The pipeline has three core phases:
1. **Plan**: Translate input (Command or Event) + current state → ExecutionPlan (what actions to take)
2. **Execute**: Run the plan, collect outcomes (succeeded/failed/timeout for each action)
3. **Record**: `StateCoordinator.record(plan:, outcomes:)` — create immutable snapshot from outcomes, append to history (state mirrors what AX confirmed, not what was predicted)

## Deltas

- [Delta 13-1: State Initialization and Observability](deltas/13-1-state-initialization.md)
- [Delta 13-2: State Persistence and Pipeline Phases](deltas/13-2-persistence-and-pipeline.md) — placeholder, to be designed
- [Delta 13-3: ...](deltas/13-3-...) — future
