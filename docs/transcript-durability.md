# Transcript durability and storage

`ConversationTranscriptStore.Journal` serializes mutations to the global
`~/.handbeam/conversations/items/<id>/messages.jsonl`. Visible assistant deltas
are appended and synced before delivery or Session broadcast. Runner persists
crash/cancel closure from the durable entries, scoped to the run ID, rather than
depending on the dead task's process dictionary.

At application startup, `TranscriptRecovery` marks orphaned streaming replies
and running tools as failed, retaining acknowledged text and adding one stable
error entry per run. It skips active Runners (including approval waits) and does
not rerun tools or redeliver old messages. Tests disable automatic startup
recovery and invoke it against isolated histories.

Recovery runs in a registered, supervised owner. Only that process identity (not
`source: :recovery` or a caller-supplied bypass flag) may read internal delegated
transcripts for orphan maintenance. The recovery API returns status, never
transcript contents; public reads of internal conversations remain restricted.

## JSONL compatibility

Legacy plain entries remain readable. Updates and deletions now append versioned
records with `$handbeam_journal: 1`; consumers must use the transcript APIs to
obtain materialized entries, not treat every physical line as a timeline item.
Cold reads replay the journal. A bounded cache avoids replay on each mutation.
An incomplete malformed final line is discarded before the next append; other
corruption fails the read instead of silently discarding history.

Revisions from the first journal release, without transaction IDs, remain
readable. New records carry monotonic transaction IDs. Compaction preserves
the transaction and sequence high-water marks, including deleted entries.
`replace_all/3` compacts immediately; incremental revisions compact after
`max(256, live_entry_count)` updates/deletions. Snapshots use synced temporary
files, atomic rename, and parent-directory sync.

`page/2` returns chronological entries, an exclusive `before` entry-ID cursor,
and `has_more?`; limits are 1–200. Deleted cursors return `:invalid_cursor`.
WorkspaceLive starts at the newest 100 entries and loads earlier pages without
replacing live messages. Sidebar metadata reads no longer load every transcript.
Paging enforces the same internal-conversation access checks as full reads.

Tool entries now write only `tool_name`, `tool_status`, `tool_duration_ms`, and
`tool_error`. Use `TranscriptEntry` to read legacy aliases. Presence of a
canonical key wins even when its value is nil, so clearing an error cannot
resurrect a stale legacy value. Assistant/system status fields are unchanged.

Do not roll back to an older plain-JSONL-only reader while journal records exist.
Stop writers and export materialized snapshots through the new APIs first;
never rewrite live logs from an unlocked read.

## Retry intent and OS ownership

Every mutation first writes a synced `messages.jsonl.pending` intent, then
appends/syncs its journal record and removes/syncs the intent. An intent left
after interruption is replayed before later operations; transaction IDs prevent
double application of a delta, including after compaction. Failed drains retry
every second. Host recovery also drains intents when it scans orphan histories.
Recovery never reruns tools or redelivers an old reply.

If an intent owns the delta, persistence reports `{:error, {:queued, reason}}`
and clears the process-local copy before terminating the run. A failed directory
sync after rename can leave a visible intent with uncertain power-loss durability;
that intent still owns the bytes to avoid duplicate retries. If no intent was
written, the same-process buffer remains available for retry.

Journal holds a native `flock` resource per storage root for its lifetime.
Metadata, index, editor files, pending intents, and transcript writes all pass
through that owner. A second VM gets `:locked` before changing those files.
Aliases of the same directory share its device/inode identity. The sidecar
`.handbeam-storage.lock` is permanent: **never delete it to bypass a live lock**.
Resource destruction or OS process exit releases ownership; there is no TTL,
lease stealing, or manual stale-lock recovery.

Dirty-IO NIF operations hold the same resource while writing, so owner death
cannot release the lock ahead of an independently running file writer. This is
local POSIX-filesystem coordination, not a distributed/NFS lease or a defense
against arbitrary processes ignoring advisory locks.

Desktop builds require `make`, a C compiler, and OTP headers (`mix compile`
builds the NIF). Android/iOS use the shared C source via the checked-in Mob
static-NIF template. Native device builds and cold-start behavior belong in the
queued real-host verification, not in claims based on desktop unit tests.

## Limits and measurement

There is no promise to recover bytes the disk refused to write, an unacknowledged
provider chunk, or total disk loss. Startup recovery preserves successfully
synced text, not the original exception when even writing the exception failed.

Run `mix run --no-start scripts/benchmark_transcript_journal.exs 10000 500` for
a local comparison against a simulated whole-snapshot rewrite baseline. On the
development machine (macOS arm64, 2026-09-20), 10,000 entries and 500 updates took
100461.6 ms for synced whole-snapshot replacements and 1302.7 ms for journal
updates (77.1×). Both paths include the retry intent and OS lock. This is a
microbenchmark, not an end-to-end throughput claim; cold replay still scales
with history, while warm paging traverses only the requested range.
