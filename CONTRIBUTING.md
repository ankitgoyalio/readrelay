# Contributing to ReadRelay

## Build and test locally

Build on macOS with Swift 6 or later. SwiftPM may download the dependency pinned in `Package.resolved`. The offline suite runs without Gmail credentials, Keychain grants, or a background service. The seeded Gmail tests skip unless you opt in.

```fish
swift build --force-resolved-versions
swift test --force-resolved-versions
.build/debug/readrelay --version
```

See [Release packaging](docs/releasing.md) for the Apple silicon archive and Homebrew formula.

## Preview the five-day backlog with a local build

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

The sync keeps unresolved matches and unread originals pending in SQLite. Once the full reviewed run has succeeded, a pending original can pick up its first unambiguous match, including a late copy. A saved match stays tied to the same copy. Before each Gmail write, sync refreshes the selected pair and checks Gmail History in both mailboxes for changes that could invalidate the match or read status. It rescans when mailbox membership may have changed and stops if it cannot verify the pair. Gmail provides no atomic check and write across mailboxes, so a concurrent change can still race the final write. If Gmail already cleared `UNREAD`, the retry records `copyAlreadyRead` without another write. The report uses `markedRead` for a successful write and `completed` for pairs already recorded as done. Subsequent runs leave completed pairs alone.

Pass `--original-id` and `--copy-id` together to apply only one saved pair, using the Gmail message IDs from the reviewed report. A run limited to one pair leaves the transition to discovery for the first successful full sync.

## Test the development launchd job

See the [development launchd runbook](docs/launchd.md) for the manually managed five-minute preview job, unattended Keychain checks, and the owner approval required for scheduled writes.

## Seeded Gmail check

### Verify the published beta

Use the opt-in [clean-login acceptance checklist](docs/beta-acceptance.md) for the full Homebrew and Gmail workflow. The checks below exercise additional cases with dedicated test mailboxes.

- To check review code freshness, run `readrelay preview` twice after verifying forwarding and seeing a successful Homebrew preview. Confirm approval with the first code is rejected. Review the current report and approve with the latest code.
- To check a changed scope, change the primary label or delete and recreate it with the same name. Confirm the previous approval leaves the new label's copies unread. Follow the [public guide](README.md#change-the-mailbox-pair-or-primary-label) to verify the new scope and review it before approval.
- To check reconnect rejection, use the checklist's disconnected-grant case. First reconnect with a separate test account outside the mailbox pair that has permission to authorize the test project. If Google offers granular consent, also try leaving the required permission unchecked for the configured account. Each attempt should fail. Confirm that the pending copy stays unread and no new success is recorded before reconnecting with the correct account and scope. Repeat with the other role and a fresh pending pair if testing both roles.
- To check review after revoke, let Live mode complete one read pair and discover a second pair whose original and copy are unread. After revoking, mark the completed copy unread again. Temporarily remove the label from the pending original and confirm `readrelay preview --json` reports it as `originalUnavailable`. Restore the label and read the pending original. Review a new preview and confirm it proposes that copy, omits the completed original, and leaves both copies unread. After a successful Homebrew preview, approve the unchanged report and confirm only the pending copy changes.
- To check proof after reconnect, obtain a foreground review code and a successful Homebrew preview in Preview mode, then stop the Homebrew job. Reconnect one mailbox successfully while stopped and confirm approval requires a newer unattended preview. A new foreground preview alone should still leave approval blocked. Start Homebrew and wait for its successful preview, then confirm the current review code can be approved if the reviewed messages have not changed.

### Verify a known forwarding pair

Follow the [Gmail forwarding guide](README.md#set-up-and-verify-gmail-forwarding) with dedicated test mailboxes. The opt-in executable tests copy `config.json` and `oauth-client.json` from a directory created by `readrelay setup` and use the corresponding Keychain grants. Each test creates a fresh local preview in a temporary directory.

For the recent-message check, use a label with exactly one original in the five-day window and mark both the original and its unique forwarded copy as read. For the empty-preview check, use a label whose only original is more than five days old and has a unique copy.

```fish
env READRELAY_FORWARDING_TEST_SETUP="/path/to/ReadRelay" READRELAY_FORWARDING_TEST_RECENT_MESSAGE_ID='<recent@example.com>' swift test --filter testVerifyForwardingAcceptsAnAlreadyReadPairAndPreservesItsLabels
env READRELAY_FORWARDING_TEST_SETUP="/path/to/ReadRelay" READRELAY_FORWARDING_TEST_OLDER_MESSAGE_ID='<older@example.com>' swift test --filter testVerifyForwardingFindsAPairOutsideAnEmptyPreview
```

With the same recent-message setup, the two beta preview tests stage an earlier failed scan and saved recurring work in temporary SQLite files. They check that a retry saves a fresh cutoff, later previews keep it, and recurring previews show missing pending originals while omitting completed ones.

```fish
env READRELAY_FORWARDING_TEST_SETUP="/path/to/ReadRelay" READRELAY_FORWARDING_TEST_RECENT_MESSAGE_ID='<recent@example.com>' swift test --filter testBetaPreview
```

### Preview and sync seeded pairs

The opt-in Gmail check uses known, labeled original messages in the five-day window and the existing copies in the secondary mailbox. Use a private expectations file containing an array of objects with `originalID`, `forwardedCopyID` (when a unique copy exists), and `outcome`. Include at least one read original with an unread copy and one unread original with an unread copy. Additional seeds can cover the other report outcomes.

```fish
env READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_EXPECTATIONS=/path/to/expectations.json swift test --filter testDryRunReportsSeededMatchesAndPreservesTheirGmailLabels
```

The test uses a temporary SQLite file and checks that two consecutive runs keep the same cutoff and report the same Gmail labels for the seeded messages.

The write check deliberately marks one seeded secondary copy read. After approval, use a configuration with `enableWrites` set to `true` and a separate expectations file with exactly one `wouldMarkRead` pair and at least one `originalUnread` pair whose copy is also unread. The check uses temporary SQLite files, compares the previewed labels before and after, and retries from both completed and still-pending state. To run the full check again, start with the target copy unread.

```fish
env READRELAY_SEEDED_APPLY=1 READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_WRITE_EXPECTATIONS=/path/to/write-expectations.json swift test --filter testSyncMarksOnlyTheSelectedSeededCopyAndCanBeRerun
```

To check a pair from an existing reviewed backlog, also set `READRELAY_SEEDED_REVIEWED_STATE` to the closed SQLite file from a successful dry run that has never run sync. The test copies that file into both temporary paths, preserving the reviewed backlog and cutoff. With the variable unset, both temporary states get fresh previews.

### Incremental sync with staged Gmail seeds

The incremental check runs full write-enabled syncs. Use dedicated seeded mailboxes and review all eligible messages before opting in, since any eligible read original can cause its copy to be marked read. Start with a successful dry-run SQLite file that has never run `sync`. Its preview must include a known unread original with an unread copy. After saving the preview, make a different real unread pair eligible by labeling its original `ReadRelay`. The original must be within the saved cutoff. Leave both copies unread. The test copies the closed SQLite file into a temporary directory and uses the same temporary state across separate CLI processes.

Create a private expectations file with `reviewedUnreadOriginalID`, `newUnreadOriginalID`, and `newUnreadCopyID`. If the original preview also captured a known unread original before its copy arrived, add `lateUnreadCopy` with `originalID` and `copyID` once that copy is present and unread. The test checks that the first run stays within the previewed batch, later runs find the newly labeled original, and the unread pairs stay pending across invocations. With a staged late copy it also checks that the first run skips the unreviewed match and the next run finds it.

```fish
env READRELAY_SEEDED_INCREMENTAL_APPLY=1 READRELAY_SEEDED_TEST_CONFIG=/path/to/readrelay.json READRELAY_SEEDED_REVIEWED_STATE=/path/to/reviewed.sqlite READRELAY_SEEDED_INCREMENTAL_EXPECTATIONS=/path/to/incremental-expectations.json swift test --filter testSyncDiscoversNewSeededOriginalsAfterApplyingTheReviewedBacklog
```

A static set of seeded Gmail messages does not establish when a copy arrived, when an original became read, or whether it was marked unread again between syncs. The staged check still needs a real delayed delivery to cover late arrival, and a changing primary read state over time to demonstrate a weeks-later read or an unread reminder before a retry. With the originals continuously labeled, the test also cannot distinguish saved pending work from rediscovery. That requires staging an original that temporarily loses its label and checking for `originalUnavailable` after a restart. The selected-pair write check covers a completed retry and the state left by an interrupted progress save. A crash during a Gmail write and a later primary read-state change after completion require separate staged checks. Missing headers and ambiguous matches require real seeds exhibiting those conditions.

## Verify production OAuth past day seven

**Status: Pending.** [Issue #17](https://github.com/ankitgoyalio/readrelay/issues/17) needs a published Homebrew release and a volunteer with a clean Apple silicon macOS login, a dedicated Google Cloud project they own, and two distinct Gmail accounts they control. Use test mailboxes and keep the service in preview mode throughout the check. The public guide uses **Testing** for initial verification while this result is pending.

1. Install the published build using the [Homebrew install guide](README.md#install-the-macos-beta). Record the release version and macOS version. Use a login with no previous ReadRelay configuration, state, or Keychain grants.
2. Enable the Gmail API and configure the scopes and one **Desktop app** client as in [Create your Google OAuth client](README.md#create-your-google-oauth-client). For this check, use a separate project dedicated to the two test mailboxes and set its **External** audience to **In production** before either authorization. Google makes the project available to Google Accounts in this mode. Keep the client JSON private and do not distribute it. Proceed only within Google's verification rules. If Google or the account administrator blocks authorization, record the block and end the attempt. [Google publishing status](https://support.google.com/cloud/answer/15549945), [Restricted-scope verification and exceptions](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)
3. Follow [Connect your mailboxes](README.md#connect-your-mailboxes) with the same client file for both accounts. Select the intended account at each consent prompt. Record each grant's consent time in UTC and any warning or error, with private details removed. Set up the test label and use the [forwarding guide](README.md#set-up-and-verify-gmail-forwarding) to verify one labeled original and its unique forwarded copy.

4. Follow [Run unattended previews](README.md#run-unattended-previews) to start the installed Homebrew service from the test login. Check `brew services list` for registration and use `readrelay status` to record a successful service preview in UTC on the day you authorize both accounts. If you grant Keychain access during setup, capture the baseline after that step.
5. Keep the same client, mailbox pair, and grants for the duration. After **more than 168 hours from the later consent time**, leave the Mac awake and logged in for a scheduled run. Use `readrelay status` and the latest service log to verify a new unattended preview completed after the deadline without browser or Keychain prompts. Use the success timestamp from the scheduled job as evidence that it refreshed and verified both mailbox grants. If either mailbox must reconnect or a grant is replaced, start a new attempt with fresh consent times.
6. Record the outcome in [issue #17](https://github.com/ankitgoyalio/readrelay/issues/17) and stop the test service with `brew services stop ankitgoyalio/readrelay/readrelay`. Share only the fields below. Keep credentials, tokens, mailbox addresses, message data, and raw logs private.

| Field | Result |
| --- | --- |
| Published release and macOS versions | Pending |
| External / In production confirmed before both grants | Pending |
| Primary `gmail.metadata` consent time (UTC), warning or block | Pending |
| Secondary `gmail.modify` consent time (UTC), warning or block | Pending |
| First successful Homebrew preview (UTC) | Pending |
| Post-deadline Homebrew preview (UTC), elapsed hours since later consent | Pending |
| Primary and secondary grant outcomes, prompts, or sanitized errors | Pending |
| Overall outcome | Pending |

Record a pass only when the original grants both support a scheduled preview beyond the deadline without intervention. If the run fails or the evidence is incomplete, record what happened and keep **Testing** as the guide's setup for initial verification.
