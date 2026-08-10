# Custom Shortcuts UI Overhaul - Operating Index

This is the entrypoint for the compact recursive plan. The workflow is complete; a later Codex run should use the root documents as historical context and create a new scoped task before adding more implementation work.

## Read Order

1. [`PROJECT_BRIEF.md`](PROJECT_BRIEF.md) - stable intent, scope, boundaries, and final goal prompt.
2. [`TASK_MODEL.md`](TASK_MODEL.md) - approved definition, detailed execution plan, expected outputs, approvals, and task trace.
3. [`TASK_ARCHITECTURE.md`](TASK_ARCHITECTURE.md) - hierarchy, node ownership, work-order gates, and closure rules.
4. [`MASTER_PROGRESS.md`](MASTER_PROGRESS.md) - live cursor, one hard approval gate, guardrails, evidence, and queue.
5. The node relevant to a newly scoped follow-up, if one is explicitly created.

## Root Document Map

| File | Purpose | Primary owner |
| --- | --- | --- |
| [`PROJECT_BRIEF.md`](PROJECT_BRIEF.md) | Stable user intent, inputs, scope, roles, and final prompt | Project brief |
| [`TASK_MODEL.md`](TASK_MODEL.md) | Approved definition, execution plan, outputs, decisions, and trace | Task model |
| [`TASK_ARCHITECTURE.md`](TASK_ARCHITECTURE.md) | Recursive hierarchy, gates, registry, and parent closure | Architecture |
| [`MASTER_PROGRESS.md`](MASTER_PROGRESS.md) | Current status, approvals, guardrails, evidence, and next action | Live cursor |

## Execution Cursor

- Status: Complete; no active stage or node.
- Historical stage nodes: `stages/01-discovery/STAGE.md`, `stages/02-design/STAGE.md`, `stages/03-research/STAGE.md`, `stages/04-implementation/STAGE.md`
- The closed cursor and explicit deferrals are recorded in `MASTER_PROGRESS.md`.
- Any new work must be scoped separately and must not silently reopen this completed plan.

## Update Protocol

1. Read the root documents and current source/README before planning a follow-up.
2. Keep this completed plan read-only unless correcting historical inaccuracies.
3. Create a new scoped task when the user requests new behavior, new research, or a new QA pass.
4. Record new approvals, evidence, and deferrals in the new task's cursor.
5. Do not expand scope silently.

## Final Goal Prompt

The copy-ready prompt is stored in [`PROJECT_BRIEF.md`](PROJECT_BRIEF.md#final-codex-goal-prompt) and reproduced in the setup handoff. It points to this index and the live cursor rather than duplicating the full plan.
