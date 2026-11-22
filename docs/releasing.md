# Release ReadRelay for Apple silicon

## Build the archive and formula

Set the release version in [ReadRelay.swift](../Sources/ReadRelay/ReadRelay.swift) and commit it with the release changes. The examples use `0.1.0`. Use the selected release commit for both the build and the eventual GitHub tag. Build from a clean checkout on Apple silicon with Xcode and Swift 6 or later. Keep the macOS build, Xcode build, and Swift version printed by the script with the release record. To reproduce the artifact, use the same checkout and toolchain on the same macOS build. Set `DEVELOPER_DIR` when you need to select a particular installed Xcode.

```fish
swift test --force-resolved-versions
./scripts/package-release.sh 0.1.0
cd .build/releases/v0.1.0
shasum -a 256 -c readrelay-0.1.0-macos-arm64.tar.gz.sha256
tar -tzf readrelay-0.1.0-macos-arm64.tar.gz
cd ../../..
```

The script builds a native release executable using the committed SwiftPM lockfile. It checks that the CPU architecture is arm64 and that `readrelay --version` matches the requested version. It creates a tarball, its SHA-256 checksum file, and the matching `Formula/readrelay.rb`. You can pass a separate output directory as the second argument and compare the two checksum files to check reproducibility.

## Publish the GitHub Release and update the tap

1. Create the `v0.1.0` tag at the build commit. Upload `readrelay-0.1.0-macos-arm64.tar.gz` and its `.sha256` file to the GitHub Release in `ankitgoyalio/readrelay`. The formula uses this release asset URL.
2. Use the project-owned public tap repository `ankitgoyalio/homebrew-readrelay`, which maps to the Homebrew tap `ankitgoyalio/readrelay`. On first publication, create the repository if needed and add the generated `Formula/readrelay.rb` at that path. On upgrades, apply the generated URL, version, and checksum to the existing formula and preserve its service block. Commit and push the formula in the tap repository. [Homebrew tap maintenance](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
3. Follow the clean-install checklist below before listing verified macOS versions. Run `brew test ankitgoyalio/readrelay/readrelay` to check that the installed executable reports the formula version.

The [formula template](../packaging/homebrew/readrelay.rb.in) includes the service definition. Keep its stable launchd label `homebrew.mxcl.readrelay`, the `opt_bin/"readrelay"` command, and the 900-second interval specified by the [Homebrew lifecycle ADR](adr/0005-use-homebrew-for-service-lifecycle.md).

## Verify a clean install

Use a clean Apple silicon macOS login with Homebrew and its prerequisites. Use only the public release and tap. Run the commands in the [install guide](../README.md), compare the reported version to the release tag without its `v` prefix, and confirm the executable comes from Homebrew with `command -v readrelay`. Check that installation downloads the archive and performs no Swift compilation.

Record the ReadRelay version, macOS version and build from `sw_vers`, and result in the GitHub Release notes. List only macOS versions verified this way. When testing a subsequent release, verify the documented upgrade from the previous release and confirm that uninstall leaves per-user data in place.

## Verify unattended previews

Use a clean Apple silicon login and the published Homebrew build with dedicated Gmail test mailboxes.

1. Connect both mailbox grants and label a known original with an unread forwarded copy. Confirm `readrelay status` reports no successful service run before starting the job, including after running `readrelay preview` in Terminal.
2. Start the job using the [unattended preview guide](../README.md#run-unattended-previews). Check that status shows **Preview** and a new successful run without a Keychain prompt. Confirm the forwarded copy stays unread.
3. Keep the Mac awake and logged in for at least one interval and check for a newer successful run. Sleep across an interval, then verify the job resumes on a subsequent interval after wake. Log out and back in and confirm the job runs on load. Stop and restart it through Homebrew and confirm it uses the same SQLite state.
4. Withhold Keychain access to one grant and confirm status identifies the affected mailbox and explains how to restore access. Restore it and confirm that the next Homebrew run advances the success timestamp. The last failure remains visible with its timestamp.
