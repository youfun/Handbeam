# Persistent thread tools

Threads are existing durable conversations, not internal tasks or a second runtime.
The runtime supplies caller conversation/workspace/run identity. Tool arguments
cannot supply identity or a cross-workspace grant. Path-unsafe IDs, missing identity,
and metadata marked `visibility: internal` or `task` are rejected. The bounded
internal `task` tool remains separate: its conversations are excluded from these
persistent thread tools, and its run-scoped authorization and cleanup remain intact.

## Discovery

- `find_thread`: title substring, inclusive ISO-8601 `updated_after`, optional
  archived entries, maximum 20 results. Summary is explicitly title-derived, not
  an AI summary or body search. Metadata-only reads do not load transcripts.
- `read_thread`: inclusive zero-based message range; at most 16,000 Unicode
  codepoints and 50 message fragments per page. Stable message IDs and character
  offsets allow long single messages to continue without silently dropping tails.
  Only visible text and selected metadata are returned; tool details are omitted.
- Signed cursors bind caller, target/query and projected snapshot; expire in one
  hour. Changes to the projected result (including appends within the selected
  range) invalidate the cursor. Restart rather than silently skipping/repeating.
- `get_thread_status`: idle/running/awaiting_approval and available last result.
  No Session is required. Idle is not proof of successful completion.

## Handoffs and delegation

A human first enables bounded collaboration on each participating conversation.
This permits paid wakeups; turning it off rejects subsequent handoffs. Created
children inherit that consent and a persisted parent route, but cannot delegate
further or message arbitrary peers. `reply_to_parent_thread` takes no target.

`send_thread_message` always uses Coordinator; running conversations default to
`follow_up`, with `steer` only by explicit input. New runs inherit the caller's
provider/model, subject to existing workspace model policy. `create_thread`
creates a persistent read-only child in the same shared directory, **not an
isolated checkout or sandbox**. A runtime execution allowlist rejects mutating,
shell, browser, extension and unknown tools, including after approval/resume.

Current fixed limits are intentionally conservative: 3 children per root,
8 outbound handoffs across the root and its children, 3 turns per wakeup and
2,048 output tokens per provider request. These are request/token limits, not a
currency-price guarantee. Provider retry/compaction requests may also incur cost.
Quotas persist across restarts and are not reset by toggling permission.

Every send requires a caller-scoped `request_id`; identical retries return the
existing receipt and different content/target under that key is rejected.
Each independent send/delegation creates a runtime-owned `handoff_id`, returned
in the receipt and visible in `read_thread`. Continue an exchange by passing that
ID to `send_thread_message` or `reply_to_parent_thread`; it must already belong to
the authorized source/target pair. Omitting it on send starts a new exchange,
not a continuation based on peer identity. Retries keep the same request and
association. Both the source reservation and recipient's trusted origin retain
the association. Replies inherit the initiating run's association (or original
child delegation); replies to a different queued task must select its ID
explicitly. Terminal reports retain the initiating association too.
When multiple associations were consumed in one run, its unpartitioned assistant
text is not copied into a task-specific terminal report: only a run-status notice
is returned. Explicitly associated replies carry the individual results.
The source transcript holds a durable dispatch reservation before Coordinator is
called. This is **at-most-once dispatch**, not exactly-once delivery: a crash or
failure after reservation returns/leaves `delivery_unknown` and is never replayed
automatically. A human should inspect the task thread before deciding what to do.
No claim of consumption or completion follows from a started/enqueued receipt.
Target transcript `consumption` records actual runtime injection separately.

On normal Runner completion, a child sends a bounded final report unless that run
already explicitly replied. This callback is supervised but not a durable retry
worker: a host crash before the callback may require manual inspection. No
automatic acknowledgment is sent. Exhausted quotas leave results readable in the
task thread rather than initiating more work.

## UI

One compact entry per associated handoff (even with the same peer) expands existing persisted reports using native
`details`; there is no input box or separate channel/storage. Important parent
reports remain visible in the main timeline. Source titles/links come from
authorized metadata, never body text. Unavailable sources show a placeholder.
Human text cannot impersonate the report card. Known webhook/SNS/scheduler inputs
have a separate automatic-origin label. Opening, refreshing or expanding is
read-only and never dispatches or wakes an agent.
Older entries without association metadata remain separate rather than guessing
task membership from the peer or body text.
