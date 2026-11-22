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

## Contribute

See [Contributing](CONTRIBUTING.md) for source builds, offline tests, and opt-in Gmail checks.
