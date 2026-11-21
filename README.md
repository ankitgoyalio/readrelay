# readrelay
One-way read-status sync for forwarded Gmail messages.

## Preview the five-day backlog

Build on macOS with Swift 6 using `swift build`. The executable is `.build/debug/readrelay`.

Enable the Gmail API for your Google Desktop OAuth clients. Keep the downloaded client files and the ReadRelay configuration outside the repository. Use the Gmail addresses returned by Google for the two mailbox accounts.

```json
{
  "primaryEmail": "primary@example.com",
  "secondaryEmail": "secondary@example.com",
  "primaryOAuthClientFile": "primary-client.json",
  "secondaryOAuthClientFile": "secondary-client.json"
}
```

Relative client paths are resolved from the configuration file. Run authorization separately for each mailbox. The browser flow requests `gmail.metadata` for the primary mailbox and `gmail.modify` for the secondary mailbox. Refresh tokens are stored in separate Keychain entries under the `io.ankitgoyal.readrelay.oauth` service.

```fish
.build/debug/readrelay authorize primary --config /path/to/readrelay.json
.build/debug/readrelay authorize secondary --config /path/to/readrelay.json
```

To import an existing refresh token, add `--import-token` and redirect standard input from a private JSON file with the `email`, `clientID`, and `refreshToken` keys. ReadRelay verifies the client, Gmail account, and granted scope before saving the token.

```fish
.build/debug/readrelay authorize primary --config /path/to/readrelay.json --import-token < /path/to/primary-token.json
```

Once the primary mailbox has a `ReadRelay` label on the originals you want to preview, run the dry run with a SQLite path in an existing directory.

```fish
.build/debug/readrelay dry-run --config /path/to/readrelay.json --state /path/to/rollout.sqlite
```

Keep the SQLite file for the first live run. The first preview saves a cutoff 120 hours before the run started. The first successful preview saves the backlog of labeled originals at or after that cutoff and their unambiguous forwarded-copy matches. Later previews recheck the saved originals against current Gmail metadata. Both mailboxes are read through Gmail's metadata format. The dry run makes zero Gmail writes.

The JSON report contains the cutoff in Unix epoch milliseconds and one entry per eligible original. Each entry includes Gmail message and label IDs for the original and, when unambiguous, for the forwarded copy.

| Outcome | Meaning |
| --- | --- |
| `wouldMarkRead` | The original is read and its unique forwarded copy is unread. |
| `originalUnread` | The original is still unread and its forwarded copy was found. |
| `copyAlreadyRead` | The original and its forwarded copy are both read. |
| `missingMessageID` | The original has no usable Message-ID. |
| `missingCopy` | The original has a usable Message-ID, but there is no matching copy. |
| `ambiguousOriginal` | Multiple originals or Message-ID values prevent a unique match. |
| `ambiguousCopy` | Secondary mailbox metadata does not establish a unique match. |
| `originalUnavailable` | A saved original is no longer eligible for this backlog. |
| `matchChanged` | Current Gmail metadata identifies a different pair from the saved preview. |

## Apply the reviewed backlog

After reviewing a successful dry run, add `"enableWrites": true` to the configuration and explicitly run `sync --apply` with the same SQLite state file. If the state came from a version that stored only the cutoff, rerun `dry-run` with that file and review the new report first. This preserves the original cutoff and records the backlog.

```fish
.build/debug/readrelay sync --apply --config /path/to/readrelay.json --state /path/to/rollout.sqlite
```

The first successful full sync applies only the reviewed batch and its saved matches. On later runs, the same command discovers labeled originals whose Gmail internal dates are at or after the saved cutoff. This includes messages received after the preview and messages within the cutoff that receive the label later. The cutoff stays fixed, so reading an original weeks later still counts. Keep using the same SQLite file across runs and restarts. A dry run against that file continues to show the reviewed backlog.

The sync keeps unresolved matches and unread originals pending in SQLite. Once the full reviewed run has succeeded, a pending original can pick up its first unambiguous match, including a late copy. A saved match stays tied to the same copy. Sync checks both messages' current metadata, fetching the original last before any Gmail write. If Gmail already cleared `UNREAD`, the retry records `copyAlreadyRead` without another write. The report uses `markedRead` for a successful write and `completed` for pairs already recorded as done. Subsequent runs leave completed pairs alone.

Pass `--original-id` and `--copy-id` together to apply only one saved pair, using the Gmail message IDs from the reviewed report. A run limited to one pair leaves the transition to discovery for the first successful full sync.

## Run on the Mac mini

See the [launchd runbook](docs/launchd.md) for the five-minute preview job, unattended Keychain checks, and the owner approval required for scheduled writes.

## Seeded Gmail check

Run `swift test` for the offline CLI checks. The opt-in Gmail check uses known, labeled original messages in the five-day window and the existing copies in the secondary mailbox. Use a private expectations file containing an array of objects with `originalID`, `forwardedCopyID` (when a unique copy exists), and `outcome`. Include at least one read original with an unread copy and one unread original with an unread copy. Additional seeds can cover the other report outcomes.

```fish
env READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_EXPECTATIONS=/path/to/expectations.json swift test --filter testDryRunReportsSeededMatchesAndPreservesTheirGmailLabels
```

The test uses a temporary SQLite file and checks that two consecutive runs keep the same cutoff and report the same Gmail labels for the seeded messages.

The write check deliberately marks one seeded secondary copy read. After approval, use a configuration with `enableWrites` set to `true` and a separate expectations file with exactly one `wouldMarkRead` pair and at least one `originalUnread` pair whose copy is also unread. The check uses temporary SQLite files, compares the previewed labels before and after, and retries from both completed and still-pending state. To run the full check again, start with the target copy unread.

```fish
env READRELAY_SEEDED_APPLY=1 READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_WRITE_EXPECTATIONS=/path/to/write-expectations.json swift test --filter testSyncMarksOnlyTheSelectedSeededCopyAndCanBeRerun
```

### Incremental sync with staged Gmail seeds

The incremental check runs full write-enabled syncs. Use dedicated seeded mailboxes and review all eligible messages before opting in, since any eligible read original can cause its copy to be marked read. Start with a successful dry-run SQLite file that has never run `sync`. Its preview must include a known unread original with an unread copy. After saving the preview, make a different real unread pair eligible by labeling its original `ReadRelay`. The original must be within the saved cutoff. Leave both copies unread. The test copies the closed SQLite file into a temporary directory and uses the same temporary state across separate CLI processes.

Create a private expectations file with `reviewedUnreadOriginalID`, `newUnreadOriginalID`, and `newUnreadCopyID`. If the original preview also captured a known unread original before its copy arrived, add `lateUnreadCopy` with `originalID` and `copyID` once that copy is present and unread. The test checks that the first run stays within the previewed batch, later runs find the newly labeled original, and the unread pairs stay pending across invocations. With a staged late copy it also checks that the first run skips the unreviewed match and the next run finds it.

```fish
env READRELAY_SEEDED_INCREMENTAL_APPLY=1 READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_REVIEWED_STATE=/path/to/reviewed.sqlite READRELAY_SEEDED_INCREMENTAL_EXPECTATIONS=/path/to/incremental-expectations.json swift test --filter testSyncDiscoversNewSeededOriginalsAfterApplyingTheReviewedBacklog
```

A static set of seeded Gmail messages does not establish when a copy arrived, when an original became read, or whether it was marked unread again between syncs. The staged check still needs a real delayed delivery to cover late arrival, and a changing primary read state over time to demonstrate a weeks-later read or an unread reminder before a retry. With the originals continuously labeled, the test also cannot distinguish saved pending work from rediscovery. That requires staging an original that temporarily loses its label and checking for `originalUnavailable` after a restart. The selected-pair write check covers a completed retry and the state left by an interrupted progress save. A crash during a Gmail write and a later primary read-state change after completion require separate staged checks. Missing headers and ambiguous matches require real seeds exhibiting those conditions.
