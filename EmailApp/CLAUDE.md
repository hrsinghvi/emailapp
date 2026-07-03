# Model Routing

Orchestration lives in the main session (Sonnet 5). Implementation is delegated to subagents.

- Main session: Sonnet 5. Plans, breaks tasks into subtasks, reviews subagent output at merge points, resolves conflicts. Does not write code directly except trivial one-line fixes.
- `.claude/agents/worker-sonnet.md`: only implementation subagent. Handles everything, no escalation path.

All subtasks go to worker-sonnet. No opus.

## Workflow

1. Main session takes the full task, produces a breakdown: subtask list, complexity rating per subtask, dependencies, execution order.
2. For each subtask, invoke worker-sonnet or worker-opus per the rating (use `@worker-sonnet` / `@worker-opus` or let auto-routing match the subagent description).
3. Subagent output returns to main session only at merge points, not after every subtask.
4. Main session checks integration, not line-by-line code. Flags issues and specifies which worker fixes what.
5. Final pass: main session confirms coherence. Done.

Line-level code review is worker-opus's job when requested, not the main session's.

# Token Discipline

- Subagents don't see the other subtasks' full context, only what their own task needs.
- New subagent invocation per subtask. Don't drag unrelated context along.
- Run `/compact` past ~30 turns in the main session.

# Output Discipline

- No restating the request. No narrating the plan unless asked.
- No after-the-fact summaries unless something needs flagging: breaking change, assumption, tradeoff.
- Subagents ship working code, not drafts.
- If a task's scope is unclear enough that a wrong guess wastes a full planning pass, ask first.
