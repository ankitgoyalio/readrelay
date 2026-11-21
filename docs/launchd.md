# Run ReadRelay on the Mac mini

Scheduled Gmail writes are disabled. The owner has yet to approve the dry-run report, and Dot’s normal digest is paused. Start with a preview job and keep its SQLite file separate from the state used for rollout.

The user agent runs at load and every 300 seconds in the owner’s graphical login session. An interval that falls during sleep or an active run can be missed. The next available run uses the same SQLite file. After reboot the job starts when the owner logs in. See `man launchd.plist` for the timing rules.

## Prepare the preview job

Run these Fish commands on the Mac mini from the repository checkout as the account that owns the existing ReadRelay Keychain entries. Use a logged-in graphical session and run each step after the previous one succeeds.

```fish
set relay_dir "$HOME/Library/Application Support/ReadRelay"
set relay_bin "$relay_dir/bin/readrelay"
set relay_config "$relay_dir/readrelay.json"
set relay_probe "$relay_dir/launchd-preview.sqlite"
set relay_logs "$relay_dir/logs/preview"
set relay_label io.ankitgoyal.readrelay
set relay_domain "gui/"(id -u)
set relay_service "$relay_domain/$relay_label"
set relay_staged "$relay_dir/$relay_label.plist"
set relay_agent "$HOME/Library/LaunchAgents/$relay_label.plist"

install -d -m 700 "$relay_dir" "$relay_dir/bin" "$relay_logs"
swift build -c release
```

On first setup, install the release binary at the stable path below. On repeat setup, reuse the installed binary and existing configuration and state. For an intentional binary update, first stop the job as described below, replace the binary, and repeat the Keychain checks. macOS may require fresh trust for the updated binary. [Apple Keychain Access](https://support.apple.com/guide/keychain-access/if-a-trusted-app-asks-for-keychain-access-kyca1331/mac)

```fish
if not test -e "$relay_bin"
    install -m 700 .build/release/readrelay "$relay_bin"
end
```

Place the private configuration at `$relay_config` with `enableWrites` omitted or set to `false`. Use the same mailbox addresses and Desktop OAuth client IDs as the existing Keychain entries. Make sure any relative client paths resolve from the new configuration location and restrict access to the configuration and client files. The primary mailbox needs the `ReadRelay` label and the `gmail.metadata` grant. The secondary mailbox needs the `gmail.modify` grant. For unattended use beyond seven days, confirm that neither Gmail refresh token was issued by an external OAuth app in Testing mode. [Google OAuth token expiration](https://developers.google.com/identity/protocols/oauth2#expiration)

Try the exact installed binary with the existing tokens and no terminal input. A successful report means the CLI refreshed both grants, verified both configured Gmail accounts and their scopes, and read Gmail metadata. This preview writes only to the separate local probe SQLite file.

```fish
umask 077
"$relay_bin" dry-run --unattended --config "$relay_config" --state "$relay_probe" < /dev/null
```

If Keychain access requires interaction, unlock the login Keychain and allow this installed executable to read each `io.ankitgoyal.readrelay.oauth` entry. The account names identify the mailbox role, email and OAuth client ID. Use Keychain Access to grant access to the specific binary, or run the same dry run once without `--unattended` and select **Always Allow** for the expected ReadRelay prompts. Rerun with `--unattended` before proceeding. If Google rejects an expired or revoked grant, authorize that mailbox again with the installed binary. [Apple Keychain access controls](https://support.apple.com/guide/mac-help/kychn002/mac)

Generate and lint a staged plist. This step can be repeated and leaves any installed job untouched.

```fish
"$relay_bin" launch-agent --executable "$relay_bin" --config "$relay_config" \
    --state "$relay_probe" --log-directory "$relay_logs" > "$relay_staged.new"
and plutil -lint "$relay_staged.new"
and mv -f "$relay_staged.new" "$relay_staged"
plutil -p "$relay_staged"
```

Confirm that `ProgramArguments` contains the absolute paths and `dry-run --unattended`, and that `RunAtLoad` is true and `StartInterval` is 300.

## Load and verify the preview job

When the owner is ready to test on the Mac mini, use the commands below. If this label is already loaded, use `launchctl print "$relay_service"` to inspect it and reuse it if its arguments match. To change the loaded definition, stop it first. The plist persists under the user’s LaunchAgents directory for future logins.

```fish
if launchctl print "$relay_service" > /dev/null 2>&1
    launchctl print "$relay_service"
else
    mkdir -p "$HOME/Library/LaunchAgents"
    and install -m 600 "$relay_staged" "$relay_agent.new"
    and mv -f "$relay_agent.new" "$relay_agent"
    and launchctl bootstrap "$relay_domain" "$relay_agent"
end
```

Check the first RunAtLoad invocation and at least one subsequent interval without using `kickstart`. After each invocation finishes, check that the last exit code is zero, the stdout log has a fresh JSON report, and stderr has no new errors. The logs contain message identifiers. Keep them private and archive or rotate them while the job is stopped.

```fish
launchctl print "$relay_service"
stat -f '%Sm %z %N' "$relay_logs/stdout.log"
tail -n 30 "$relay_logs/stdout.log"
tail -n 30 "$relay_logs/stderr.log"
```

Record the saved cutoff and a known original ID from the preview. Sleep the Mac across a scheduled interval, wake it, and check for a fresh completed report on the next available interval with the same cutoff and original ID. Reboot, log back into the same graphical account, and check for a fresh RunAtLoad report with the same cutoff and original ID. Both runs must complete without a browser, a Keychain prompt or terminal input. These checks establish that launchd can use the existing grants and reopen SQLite. The pending-write checks below require owner approval.

## Owner gate for scheduled writes

Keep the preview job in place or stopped until the owner approves the dry-run report and explicitly authorizes write rollout. Prepare the actual report using a dedicated rollout SQLite file and keep that exact file. The probe file has its own cutoff and backlog.

Before enabling recurring writes, record all of the following.

1. A successful unattended preview in the real launchd session, including after wake and after reboot and login.
2. A successful comparison in Dot’s normal digest flow. A previously included unread control should recur while the copy marked read is omitted. With the digest paused or the result inconclusive, keep scheduled writes disabled pending the maintainer’s decision.
3. The owner's approval of the rollout report, a successful explicitly approved selected-pair write and retry, and a successful manual full catch-up using the same reviewed SQLite file. Follow [Apply the reviewed backlog](../README.md#apply-the-reviewed-backlog) and check the unread comparison copy remains unread. Record the owner's explicit approval to enable the recurring job.

After the gate passes, set `relay_state` to the absolute path of that same rollout SQLite file and keep `"enableWrites": true` in its configuration. Stop the preview job and stage the replacement. The CLI checks `enableWrites` on every write run.

```fish
set relay_logs "$relay_dir/logs/sync"
install -d -m 700 "$relay_logs"
and "$relay_bin" launch-agent --enable-scheduled-writes --executable "$relay_bin" \
    --config "$relay_config" --state "$relay_state" --log-directory "$relay_logs" > "$relay_staged.new"
and plutil -lint "$relay_staged.new"
and mv -f "$relay_staged.new" "$relay_staged"
```

Confirm the arguments include `sync --apply --unattended` and the reviewed state path. Install and bootstrap the staged replacement using the same commands as for the preview. Check its first report and the next interval.

For each of the sleep and reboot tests, start with a different known pending pair. Record an `originalUnread` result for the pair in the scheduled sync log while its forwarded copy is still unread. To prove SQLite retained that original, temporarily remove its `ReadRelay` label before sleep or reboot. After wake or login, verify the next report has the same cutoff and lists that original as `originalUnavailable`. Restore the label, read the original, and verify a later scheduled run reports `markedRead` for the expected copy and that the unread comparison copy remains unread. Check that a subsequent run reports the target as `completed`. Record which checks ran and when.

## Stop or return to previews

Move the installed plist out of LaunchAgents so a future login cannot reload it. Boot out the loaded job and confirm it is absent. For an active write job, also set `enableWrites` to `false` before restarting any verification. Keep the configuration, SQLite state and logs for a later retry.

```fish
if test -f "$relay_agent"
    mv -f "$relay_agent" "$relay_dir/$relay_label.disabled"
end
if launchctl print "$relay_service" > /dev/null 2>&1
    launchctl bootout "$relay_service"
end
launchctl print "$relay_service"
```

The final `print` should report that the service is absent. Wait for any terminating process to exit before replacing the executable or copying SQLite. To resume previews, regenerate the default plist with the probe SQLite path and the preview log directory.
