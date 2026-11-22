# ReadRelay

One-way read-status sync for forwarded Gmail messages.

## Install the macOS beta

After the planned `v0.1.0` prerelease is published, install on an Apple silicon Mac with [Homebrew](https://brew.sh/). The formula downloads a prebuilt executable from GitHub Releases. ReadRelay itself requires no Swift toolchain to install or run.

```fish
brew install ankitgoyalio/readrelay/readrelay
readrelay --version
```

The executable targets macOS 13 or later. See the [release notes](https://github.com/ankitgoyalio/readrelay/releases) for macOS versions verified on a clean Apple silicon login. Clean-login verification is pending for the first beta.

## Before you connect

Use two distinct Gmail accounts you control. The primary mailbox receives and keeps the originals. You’ll also need a sender account that matches your filter to send a test message. Dedicate the secondary mailbox to forwarded copies. ReadRelay supports one mailbox pair per macOS login.

ReadRelay makes Gmail API requests from your Mac. It stores refresh tokens in your login Keychain and keeps the OAuth client file, configuration, SQLite sync state, reports, and logs under `~/Library/Application Support/ReadRelay`. ReadRelay has no hosted sync service.

The primary grant covers headers and labels across the mailbox and excludes message bodies. The selected Gmail label determines which originals ReadRelay considers for sync. The secondary grant allows Gmail modifications. ReadRelay uses it to clear unread status on a unique matching forwarded copy after you approve writes. Keep the client file, preview reports, and logs private.

## Create your Google OAuth client

Use a Google Cloud project you own and start with **External** access in **Testing** for the initial beta verification.

1. Create a Google Cloud project and enable the **Gmail API** in it. [Google's Gmail API setup](https://developers.google.com/workspace/gmail/api/quickstart/go#enable_the_api)
2. In **Google Auth platform**, configure **Branding** with an app name, support email, and contact email. Select **External** under **Audience**, keep the publishing status at **Testing**, and add both Gmail addresses under **Test users**. [Google Auth platform setup](https://support.google.com/cloud/answer/15544987), [Audience and test users](https://support.google.com/cloud/answer/15549945)
3. Under **Data Access → Add or Remove Scopes**, add `https://www.googleapis.com/auth/gmail.metadata` and `https://www.googleapis.com/auth/gmail.modify`. ReadRelay requests the metadata scope for the primary mailbox and the modify scope for the secondary mailbox. [Configure consent and scopes](https://developers.google.com/workspace/guides/configure-oauth-consent), [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
4. Under **Clients → Create client**, select **Desktop app**, name the client, and download its JSON file. Keep that file private. Supply the same file to `readrelay setup` for both mailboxes and authorize each Gmail account separately when the browser prompts you. [Google's desktop client setup](https://developers.google.com/identity/protocols/oauth2/native-app#creatingcred)

In **Testing**, each refresh token expires seven days after its account grants consent because ReadRelay requests Gmail scopes. Run the initial checks within that window and reconnect the affected mailbox if authorization expires. Google may show a warning when you authorize an unverified project. Review the project name, account, and requested access before granting consent. [Refresh token expiration](https://developers.google.com/identity/protocols/oauth2#expiration), [Google's unverified app warning](https://support.google.com/cloud/answer/7454865)

## Connect your mailboxes

Replace the example path and both addresses. If you use a different label in your Gmail filter, replace `ReadRelay` with its exact name.

```fish
readrelay setup --oauth-client-file '/path/to/client.json' --primary-email 'primary@example.com' --secondary-email 'secondary@example.com' --primary-label 'ReadRelay'
```

ReadRelay prints the Gmail address to choose for each browser prompt. Authorize the primary mailbox with metadata access, then the secondary mailbox with modify access. Wait for Terminal to confirm that both mailboxes are connected.

## Set up and verify Gmail forwarding

1. In Gmail on the web, sign in to your primary mailbox. Under **Settings → See all settings → Forwarding and POP/IMAP**, add your secondary Gmail address as a forwarding address. Open the confirmation email in the secondary mailbox and confirm the address. Return to the primary mailbox and refresh Gmail settings. For selective forwarding, keep mailbox-wide forwarding disabled. [Gmail forwarding help](https://support.google.com/mail/answer/10957)
2. In the primary mailbox, create the label you selected in setup if it does not exist. Use **Show search options** in Gmail’s search bar to enter your criteria and choose **Create filter**. If you already have a filter, edit it under **Filters and Blocked Addresses** in Settings. Select **Forward it** and choose your secondary Gmail address. Select **Apply the label** and choose the same label, `ReadRelay` by default. Save the filter. [Gmail filter help](https://support.google.com/mail/answer/6579)
3. Send a new test email to the primary address from a sender that matches the filter. Include any subject text or other criteria your filter requires. Confirm that Gmail labeled the original and delivered a copy to the secondary mailbox. Leave the secondary copy unread so you can use it to check preview and live sync.
4. Open the original in the primary mailbox. In the message’s **More → Show original** menu, copy the **Message ID** value. [Gmail message header help](https://support.google.com/mail/answer/29436)
5. Replace the example with that value, keeping the quotes. ReadRelay checks for one labeled original and exactly one matching forwarded copy. The check works regardless of read status and makes no changes in Gmail.

   ```fish
   readrelay verify-forwarding '<example-id@example.com>'
   ```

If verification fails, follow the message in Terminal. Check that Gmail applied the selected label to the original and that the copy arrived at the intended address. If the match is ambiguous, check for overlapping forwarding filters and send a fresh test message.

## Review a preview

Once the primary label exists, you can preview even if you are still diagnosing forwarding.

```fish
readrelay preview
```

The first successful preview saves the labeled originals from the 120 hours before that attempt started. Until the backlog is saved, each retry starts with a fresh five-day window. The summary shows how many forwarded copies would be marked read and why other originals were skipped. Check the secondary inbox without opening the test copy to confirm it stays unread after preview. If its original was in the saved backlog when you opened it and its unique copy is unread, the report proposes a change. If you saved an empty backlog before staging test mail, you can still verify the new pair. Live runs discover eligible originals after processing the saved backlog.

ReadRelay prints the path to its detailed JSON report. To read the exact report you just reviewed, replace the example with the printed path, keeping the quotes.

```fish
less '/path/from-preview/preview-report.json'
```

For scripts, `readrelay preview --json` prints a fresh report to standard output. Each entry includes Gmail message and label IDs and an outcome such as `wouldMarkRead`, `originalUnread`, `missingCopy`, or `ambiguousCopy`. Use plain `readrelay preview` for the final review before approving, since it prints the approval command.

## Run unattended previews

After connecting both mailboxes and creating the primary label, start the background service from your macOS login. Use Homebrew without `sudo`.

```fish
brew services start ankitgoyalio/readrelay/readrelay
readrelay status
```

The service runs when it loads, including when you log back in, and every 15 minutes while your Mac is awake and you’re logged in. An interval can be skipped while your Mac is asleep or a run is still active. After wake, ReadRelay picks up on a subsequent interval. A new setup starts in preview mode and leaves Gmail read status unchanged until you approve writes.

`readrelay status` shows the mode, when the background job last completed successfully, and the most recent failure. Homebrew reports whether the job is registered with `brew services list`. ReadRelay keeps the latest run log in `~/Library/Application Support/ReadRelay/logs/service.log`.

If status reports that Keychain access requires interaction, unlock your login Keychain and run `readrelay preview` in Terminal using the installed executable. If prompted, choose **Always Allow** for the refresh token. Then run `brew services restart ankitgoyalio/readrelay/readrelay` and check for a new successful run in `readrelay status`.

## Approve recurring sync

After verifying forwarding and seeing a successful Homebrew preview in `readrelay status`, run `readrelay preview`. If the service has failed since its last preview or you’ve replaced either mailbox grant, wait for the Homebrew job to complete a new preview before approving. Review the mailbox pair, primary label, and proposed changes. The preview also gives you the path to the detailed JSON report.

Copy the `readrelay approve` command printed by the preview, including its review code. This approves the work shown and future eligible messages for the displayed pair and label. If ReadRelay reports that the preview changed, run `readrelay preview` and review the new report before approving it.

Check `readrelay status` for **Live** mode. Gmail updates begin on the next background run. The first live run handles the saved backlog. Later runs also discover eligible originals and retry pending work, including originals you leave unread for more than five days.

Pause background sync with `brew services stop ankitgoyalio/readrelay/readrelay`. Starting the service again preserves approval and pending work. To withdraw approval while leaving the schedule in place, run `readrelay revoke`. If a run is active, wait for it to finish and retry the revoke command. Once revoke succeeds, the service runs in **Preview** mode. If live sync has already processed the initial backlog, a new preview shows saved pending work and newly eligible originals. Completed pairs stay excluded even if their copies were marked unread again.

## Reconnect a Gmail mailbox

If `readrelay status` reports an expired or revoked grant, run the command it shows, `readrelay reconnect primary` or `readrelay reconnect secondary`. In your browser, choose the Gmail address shown in Terminal and grant the requested permission. ReadRelay uses the saved Desktop OAuth client and checks the account and scope before replacing that mailbox’s grant.

If another ReadRelay command is running, wait for it to finish and retry. With the service running, check `readrelay status` after the next interval for a new successful run. The service resumes its saved mode and pending work, including any existing write approval.

## Change the mailbox pair or primary label

To switch labels, run `readrelay set-label 'New label'` and update the Gmail forwarding filter. Use the same command with the current label name if you deleted and recreated that label in Gmail.

To switch mailboxes, run setup with `--replace` and authorize both accounts.

```fish
readrelay setup --replace --oauth-client-file '/path/to/client.json' --primary-email 'primary@example.com' --secondary-email 'secondary@example.com' --primary-label 'ReadRelay'
```

Either change starts a fresh backlog in preview mode. Verify forwarding for the new scope, wait for its first successful background preview, then review it before approving writes. ReadRelay retains the previous scope’s files on disk.

## Upgrade

```fish
brew update
brew upgrade ankitgoyalio/readrelay/readrelay
readrelay --version
```

An upgrade preserves your configuration, SQLite sync state, logs, and Keychain entries. macOS may ask you to reallow Keychain access for the upgraded executable.

## Uninstall

If you started ReadRelay through Homebrew services, stop it first with `brew services stop ankitgoyalio/readrelay/readrelay` from the same macOS login.

```fish
brew uninstall ankitgoyalio/readrelay/readrelay
```

Uninstalling removes the executable. Your per-user configuration, SQLite sync state, logs, OAuth client file, and Keychain entries stay on your Mac. To remove your local setup entirely, remove the ReadRelay files for your login and delete its `io.ankitgoyal.readrelay.oauth` entries in Keychain Access. Deleting SQLite state also discards pending sync work. To revoke ReadRelay’s Gmail access, remove the OAuth grant in each Google Account.

## Contribute

See [Contributing](CONTRIBUTING.md) for source builds, offline tests, and opt-in Gmail checks.
