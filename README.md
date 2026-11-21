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

Keep the SQLite file for the first live run. The first preview saves a cutoff 120 hours before the run started, and later previews reuse that cutoff. A preview considers each labeled original at or after the cutoff and compares its `Message-ID` against the secondary mailbox. Both mailboxes are read through Gmail's metadata format. The dry run makes zero Gmail writes.

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

## Seeded Gmail check

Run `swift test` for the offline CLI checks. The opt-in Gmail check uses known, labeled original messages in the five-day window and the existing copies in the secondary mailbox. Use a private expectations file containing an array of objects with `originalID`, `forwardedCopyID` (when a unique copy exists), and `outcome`. Include at least one read original with an unread copy and one unread original with an unread copy. Additional seeds can cover the other report outcomes.

```fish
env READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_EXPECTATIONS=/path/to/expectations.json swift test --filter testDryRunReportsSeededMatchesAndPreservesTheirGmailLabels
```

The test uses a temporary SQLite file and checks that two consecutive runs keep the same cutoff and report the same Gmail labels for the seeded messages.
