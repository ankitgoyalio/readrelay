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

## Run unattended previews

After connecting both mailboxes, start the background service from your macOS login. Use Homebrew without `sudo`.

```fish
brew services start ankitgoyalio/readrelay/readrelay
readrelay status
```

ReadRelay runs a preview when the service loads, including when you log back in, and every 15 minutes while your Mac is awake and you’re logged in. An interval can be skipped while your Mac is asleep or a run is still active. After wake, ReadRelay picks up on a subsequent interval. Previews leave Gmail read status unchanged.

`readrelay status` shows the mode, when the background job last completed successfully, and the most recent failure. Homebrew reports whether the job is registered with `brew services list`. ReadRelay keeps the latest run log in `~/Library/Application Support/ReadRelay/logs/service.log`.

If status reports that Keychain access requires interaction, unlock your login Keychain and run `readrelay preview` in Terminal using the installed executable. If prompted, choose **Always Allow** for the refresh token. Then run `brew services restart ankitgoyalio/readrelay/readrelay` and check for a new successful run in `readrelay status`.

Pause background previews with `brew services stop ankitgoyalio/readrelay/readrelay`. Starting it again uses your saved configuration and SQLite state.

## Contribute

See [Contributing](CONTRIBUTING.md) for source builds, offline tests, and opt-in Gmail checks.
