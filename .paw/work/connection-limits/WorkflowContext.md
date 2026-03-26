# WorkflowContext

Work Title: Connection Limits
Work ID: connection-limits
Base Branch: main
Target Branch: pinodeca/connection-limits
Execution Mode: current-checkout
Repository Identity: github.com/microsoft/pg_durable@173843327748d154367f457293036cfe75fb04ab
Execution Binding: none
Workflow Mode: full
Review Strategy: local
Review Policy: milestones
Session Policy: continuous
Final Agent Review: enabled
Final Review Mode: multi-model
Final Review Interactive: smart
Final Review Models: gpt-5.4, gemini-3-pro-preview, claude-opus-4.6
Final Review Specialists: all
Final Review Interaction Mode: parallel
Final Review Specialist Models: none
Final Review Perspectives: auto
Final Review Perspective Cap: 2
Implementation Model: none
Plan Generation Mode: single-model
Plan Generation Models: gpt-5.4, gemini-3-pro-preview, claude-opus-4.6
Planning Docs Review: enabled
Planning Review Mode: multi-model
Planning Review Interactive: smart
Planning Review Models: gpt-5.4, gemini-3-pro-preview, claude-opus-4.6
Planning Review Specialists: all
Planning Review Interaction Mode: parallel
Planning Review Specialist Models: none
Planning Review Perspectives: auto
Planning Review Perspective Cap: 2
Custom Workflow Instructions: none
Initial Prompt: Study pg_durable's use of sqlx connections. How are they used in PG backends, how are they used in the background worker. Then create a spec that limits the total number of concurrent connections: 1 max per PG backend; N max for the background worker, split between a pool used for management tasks (authenticate as pg_durable.worker_role) and dynamically created connections that authenticate as other users to execute SQL with the permissions of those users.
Issue URL: none
Remote: origin
Artifact Lifecycle: commit-and-clean
Artifact Paths: auto-derived
Additional Inputs: none
