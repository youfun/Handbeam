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

## JSONL compatibility

Legacy plain entries remain readable. Updates and deletions now append versioned
records with `$handbeam_journal: 1`; consumers must use the transcript APIs to
obtain materialized entries, not treat every physical line as a timeline item.
Cold reads replay the journal. A bounded cache avoids replay on each mutation.
An incomplete malformed final line is discarded before the next append; other
corruption fails the read instead of silently discarding history.

`replace_all/3` writes a synced temporary snapshot and atomically renames it.
This also compacts revisions, but automatic compaction and paginated history
reads are not implemented. Do not roll back to an older plain-JSONL-only reader
while journal records exist. Stop writers and export materialized snapshots
through the new APIs first; never rewrite live logs from an unlocked read.

## Limits and measurement

There is no promise to recover bytes the disk refused to write, an unacknowledged
provider chunk, or total disk loss. Persistence errors terminate the run; a
same-process retry retains its buffer, but this is not a persistent retry queue.
Startup recovery preserves successfully synced text, not the original exception
when even writing the exception failed. The journal assumes a single running
Handbeam instance owns the storage directory; it is not an inter-VM file lock.

Run `mix run --no-start scripts/benchmark_transcript_journal.exs 10000 500` for
a local comparison against a simulated whole-snapshot rewrite baseline. On the
development machine, 10,000 entries and 500 updates took 9346.7 ms for rewrites
and 363.9 ms for append updates (25.7×). This is a microbenchmark, not an
end-to-end throughput claim; listing and cold replay still scale with history.
