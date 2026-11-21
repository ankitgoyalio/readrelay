# Run as a local job with SQLite state

ReadRelay is a Swift command-line tool scheduled by a user `launchd` agent on the Mac mini. A single job can track pending message IDs and sync progress in SQLite without operating a separate database service. Gmail OAuth tokens live in macOS Keychain, and after a reboot the job can catch up once the user logs in.

The application and all automated tests are written in Swift and organized as a Swift package. The command-line interface uses Swift Argument Parser, and the test suite runs with `swift test`.
