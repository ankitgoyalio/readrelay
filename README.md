# ReadRelay

One-way read-status sync for forwarded Gmail messages.

## Install the macOS beta

After the beta is published, install on an Apple silicon Mac with [Homebrew](https://brew.sh/). The formula downloads a prebuilt executable from GitHub Releases. ReadRelay itself requires no Swift toolchain to install or run.

```fish
brew install ankitgoyalio/readrelay/readrelay
readrelay --version
```

The executable targets macOS 13 or later. See the [release notes](https://github.com/ankitgoyalio/readrelay/releases) for macOS versions verified on a clean Apple silicon login. Clean-login verification is pending for the first beta.

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

## Set up and verify Gmail forwarding

1. In Gmail on the web, sign in to your primary mailbox. Under **Settings → See all settings → Forwarding and POP/IMAP**, add your secondary Gmail address as a forwarding address. Open the confirmation email in the secondary mailbox and confirm the address. For selective forwarding, keep mailbox-wide forwarding disabled. [Gmail forwarding help](https://support.google.com/mail/answer/10957)
2. In the primary mailbox, create or edit a filter for the messages you want to forward. Select **Forward it** and choose your secondary Gmail address. Also select **Apply the label** and choose the primary label you configured in `readrelay setup`. The default label is `ReadRelay`. Create the label in Gmail if needed, then save the filter. [Gmail filter help](https://support.google.com/mail/answer/6579)
3. Once the filter is saved, send a new email to the primary address from a sender that matches the filter. Include any subject or other details the filter requires. Confirm that Gmail applied the label to the original and that a copy arrived in the secondary mailbox.
4. In the primary mailbox, open the test email. Use the message’s **More → Show original** menu and copy the **Message ID** value. [Gmail message header help](https://support.google.com/mail/answer/29436)
5. Run the following command with that value in quotes. ReadRelay checks for one labeled original and exactly one matching forwarded copy, even if both are already read. The command leaves Gmail read status unchanged.

   ```fish
   readrelay verify-forwarding '<example-id@example.com>'
   ```

You can run `readrelay preview` before verification succeeds. If your earlier preview was empty, send a new message that matches the filter and verify it using the steps above.

## Run unattended previews

After connecting both mailboxes, start the background service from your macOS login. Use Homebrew without `sudo`.

```fish
brew services start ankitgoyalio/readrelay/readrelay
readrelay status
```

The service runs when it loads, including when you log back in, and every 15 minutes while your Mac is awake and you’re logged in. An interval can be skipped while your Mac is asleep or a run is still active. After wake, ReadRelay picks up on a subsequent interval. The service starts in preview mode and leaves Gmail read status unchanged until you approve writes.

`readrelay status` shows the mode, when the background job last completed successfully, and the most recent failure. Homebrew reports whether the job is registered with `brew services list`. ReadRelay keeps the latest run log in `~/Library/Application Support/ReadRelay/logs/service.log`.

If status reports that Keychain access requires interaction, unlock your login Keychain and run `readrelay preview` in Terminal using the installed executable. If prompted, choose **Always Allow** for the refresh token. Then run `brew services restart ankitgoyalio/readrelay/readrelay` and check for a new successful run in `readrelay status`.

## Approve recurring sync

After verifying forwarding and seeing a successful background preview in `readrelay status`, run `readrelay preview`. Review the mailbox pair, primary label, and proposed changes. The preview also gives you the path to the detailed JSON report.

Copy the `readrelay approve` command printed by the preview, including its review code. This approves the saved five-day backlog and future eligible messages for the displayed pair and label. If ReadRelay reports that the preview changed, run `readrelay preview` and review the new report before approving it.

Check `readrelay status` for **Live** mode. The first live run handles the saved backlog. Later runs also discover eligible originals and retry pending work, including originals you leave unread for more than five days.

Pause background sync with `brew services stop ankitgoyalio/readrelay/readrelay`. Starting the service again preserves approval and pending work. To withdraw approval while leaving the schedule in place, run `readrelay revoke`. If a run is active, wait for it to finish and retry the revoke command. Once revoke succeeds, the service runs in **Preview** mode.

If status says a mailbox needs reconnecting, run `readrelay authorize primary` or `readrelay authorize secondary` for that mailbox. In your browser, choose the same Gmail account. ReadRelay verifies the account and scope before saving the grant. The next service run uses the saved mode and pending work.

## Change the mailbox pair or primary label

To switch labels, run `readrelay set-label 'New label'` and update the Gmail forwarding filter. Use the same command with the current label name if you deleted and recreated that label in Gmail.

To switch mailboxes, run setup with `--replace` and authorize both accounts.

```fish
readrelay setup --replace --oauth-client-file '/path/to/client.json' --primary-email 'primary@example.com' --secondary-email 'secondary@example.com' --primary-label 'ReadRelay'
```

Either change starts a fresh backlog in preview mode. Verify forwarding for the new scope, wait for its first successful background preview, then review it before approving writes. ReadRelay retains the previous scope’s files on disk.

## Contribute

See [Contributing](CONTRIBUTING.md) for source builds, offline tests, and opt-in Gmail checks.
