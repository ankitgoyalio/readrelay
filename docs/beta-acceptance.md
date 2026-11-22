# Clean-login acceptance for the macOS beta

This opt-in checklist covers [issue #18](https://github.com/ankitgoyalio/readrelay/issues/18). Run it after the planned `v0.1.0` prerelease and Homebrew formula are public. Record one result per tested macOS version.

Use a clean login on an Apple silicon Mac with Homebrew, with no prior ReadRelay setup, state, Keychain grants, or service. Use a Google Cloud project you own, two distinct Gmail test mailboxes you control, and a separate sender account you control. Use synthetic message text and a secondary mailbox dedicated to the test. Google's **External / Testing** setup is suitable for this check. Finish within seven days of consent. The [production OAuth longevity check](../CONTRIBUTING.md#verify-production-oauth-past-day-seven) has its own evidence.

Follow the [public guide](../README.md#install-the-macos-beta) for all ReadRelay operations. Use this checklist to stage mail and collect observations. Record where you got stuck if the public guide is insufficient. Use the published executable throughout.

## Stage the initial backlog

1. Follow the public guide through install, OAuth client creation, and mailbox connection. Record both intended roles and the consent result. Create a primary Gmail filter with your test sender and both a unique run marker and the word `forward` in the Subject field, such as `RR20261122A forward`. Set the filter to apply the selected primary label and forward to the secondary mailbox. Keep mailbox-wide forwarding off. Stage all initial messages before running the first preview or starting the service, since the first successful preview saves the initial backlog.
2. Use a different subject for each row below. Record the subjects and raw Message-IDs privately. Use Gmail’s inbox or message menu to check or set unread status without opening the secondary copies. If you open a message to check its headers, restore its unread status before collecting the baseline.

| Fixture | Stage in Gmail | Expected initial preview |
| --- | --- | --- |
| Eligible | Send through the filter. Open the original to get its Message-ID for verification. Leave its uniquely forwarded copy unread. | `wouldMarkRead` |
| Control | Send through the filter. Leave the labeled original and its uniquely forwarded copy unread throughout the check. | `originalUnread` |
| Missing | Send to the primary using the run marker without the filter's forwarding keyword. Apply the primary label manually and mark the original read. Confirm its Message-ID has no match in the secondary, including Spam and Trash. | `missingCopy` |
| Ambiguous | Send through the filter, mark the original read, and leave its real forwarded copy unread. Insert an additional unread synthetic message into the secondary with that exact Message-ID using the steps below. | `ambiguousCopy` |
| Pause pending and reconnect pending | Send two separate messages through the filter. Keep each original and copy unread until its own recovery step. | `originalUnread` for each |

To stage the ambiguous copy, use a separately authorized Gmail API client for **only the secondary test mailbox**. Use the `gmail.insert` scope for the fixture and keep the authorization separate from ReadRelay’s Desktop OAuth client. With [Gmail’s messages.insert method](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/insert), insert a message as `userId=me` in the authenticated secondary mailbox. Supply a `raw` field containing the base64url-encoded MIME message and `"labelIds": ["INBOX", "UNREAD"]`. Gmail inserts the message directly into that mailbox without sending it. [Gmail raw message format](https://developers.google.com/workspace/gmail/api/guides/sending)

Save this example as `duplicate.eml` with your own test addresses, a current RFC 5322 Date, and the Message-ID copied from the original, including angle brackets. Give it a distinct subject and body so you can find it separately from the genuine forwarded copy.

```text
From: tester-sender@example.com
To: tester-secondary@example.com
Date: Sun, 22 Nov 2026 12:00:00 +0000
Subject: RR20261122A inserted duplicate
Message-ID: <exact-original-id@example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Synthetic ReadRelay acceptance fixture.
```

Produce the request body locally and pass it to your authorized client's `messages.insert` request. Keep the fixture and request private.

```fish
set -l raw (openssl base64 -A -in duplicate.eml | tr '+/' '-_' | tr -d '=')
printf '{"raw":"%s","labelIds":["INBOX","UNREAD"]}\n' "$raw"
```

Verify the two secondary messages are distinct messages with the shared RFC Message-ID and both are unread. If Gmail coalesces or rewrites the fixture, try again with a fresh original and a different inserted subject and body. If you still cannot establish the two matches, record the ambiguous check as blocked. Until the fixture is confirmed, keep its original unread and exclude it from approval by removing the test label before the first preview.

## Execute and record evidence

Record each check as **Pass**, **Fail**, **Blocked**, or **Not run**. Capture UTC times (`date -u`), the ReadRelay mode and last successful run from `readrelay status`, and the latest service log line when checking a background run. Read the log path from the public guide. The log is replaced each run, so note each timestamp as you go. Use `brew services list` to confirm registration. Record read states using the fixture names above. Compare the before and after states of both mailboxes and distinguish deliberate tester actions from service activity.

| Run details | Evidence |
| --- | --- |
| Release tag, installed version, and Homebrew executable path | |
| Mac architecture, macOS version and build | |
| OAuth publishing status and consent times (UTC) | |
| Test window (UTC) and overall result | |

| Check | Procedure and pass condition | Result and evidence |
| --- | --- | --- |
| Install | Use the tap from the public guide. Capture `uname -m`, `sw_vers`, `command -v readrelay`, and `readrelay --version`. Confirm `arm64`, the expected published version, and that Homebrew installs the prebuilt archive. | |
| Connect | Use your Desktop OAuth client. Confirm the two intended Gmail accounts and role-specific grants (`gmail.metadata` for primary and `gmail.modify` for secondary). Check the pair and label in status. | |
| Diagnose and verify | Record baseline read states. Use the Missing and Ambiguous originals' Message-IDs to check the diagnoses. Then use the Eligible original's Message-ID and confirm successful verification of the real forwarded pair. Confirm verification leaves the baseline unchanged. | |
| Foreground preview | Run the public preview and open its JSON report. Confirm the expected outcomes and that read states are unchanged. Before starting Homebrew, status should show no successful background run. | |
| Startup and recurring preview | Start Homebrew from the test login. Record start and first successful preview times and any Keychain intervention. If an initial prompt needs remediation, record it and observe a fresh unattended load. Stay awake and logged in with no restart for another successful run. Record both completion times, their spacing against the 15-minute schedule, and unchanged read states. Allow for run duration and record any delayed or missed runs. | |
| Explicit approval | Review a new foreground preview and run the approval command it prints. Check that mode changes to **Live**. After the next successful Homebrew run, only Eligible's copy should change to read. Check that Control, both Ambiguous candidates, and both pending copies remain unread. The Missing original should stay read and have no matching copy. Confirm the primary read states are unchanged. | |
| Future discovery | After the first live success, send a new message through the filter, read its original, and leave its copy unread. Wait for a later scheduled live run to mark its copy read. Check that the Control and Ambiguous copies still stay unread. | |
| Wake | Put the Mac to sleep across a scheduled interval. Record sleep and wake times and the pre-sleep success. After wake, stay logged in and allow a subsequent interval. Record the next success in **Live** mode without restarting the service or manually running sync. | |
| Login | Log out of the test login and log back in. Record logout and login times. Verify the job is still registered and succeeds on load in **Live** mode. Capture a fresh log timestamp after login, without starting the job by hand. | |
| Pause and resume | After a live success with Pause pending still unread, stop the Homebrew service using the public guide. Read its original while stopped and stay awake and logged in for at least one interval. Confirm the success timestamp stays fixed and the copy remains unread. Start the service again and await a new **Live** success. Confirm the pending copy becomes read using the same setup and approval. Record the stop, start, and success times. | |
| Disconnect and reconnect | Keep Reconnect pending unread until a live success. In one test account, remove the test project's Gmail access under [Google Account connections](https://support.google.com/accounts/answer/13533235). Wait for a scheduled failure before reading the pending original. Confirm the status names the role and gives the reconnect command, **Live** is retained, and the last success timestamp stays fixed. Then read the original and leave the copy unread. Run the suggested reconnect command with the same account and required permission. Verify a later successful Homebrew run in **Live** mode clears the pending copy without new approval. Record the role, failure and recovery times, and any Keychain steps. | |
| Revoke | Leave Homebrew registered and run `readrelay revoke` as documented. Stage a fresh eligible pair after revoke succeeds. Read its original and leave its copy unread. Verify a newer scheduled success in **Preview** mode and that the new copy and the Control and Ambiguous copies remain unread. Record the revoke and success times. | |

For a repeat attempt, use a clean login and a fresh run marker. Remove only your synthetic fixtures and test filter, or use a fresh dedicated mailbox pair so prior eligible originals cannot enter the new five-day backlog. At the end, stop the service and remove access for the dedicated test grants when finished. Coordinate cleanup separately from any ongoing production OAuth check.

Record the build version, macOS version and build, architecture, OAuth publishing status, time window, per-check evidence, and overall result in [issue #18](https://github.com/ankitgoyalio/readrelay/issues/18). Mark the workflow passed only when every check passes. Share fixture names and sanitized diagnostics. Keep credentials, review codes, email addresses, message data and IDs, and raw logs private. Use the release notes to list only the macOS versions actually verified.
