# Contributing to BackupCron

Thank you for helping improve BackupCron. Bug reports, translations,
documentation and pull requests are welcome.

## Development

Use macOS 14 or later and a Swift 6.1 or newer toolchain. Clone the repository
and open `Package.swift` or `BackupCron.xcodeproj` in Xcode.

```sh
swift test
zsh scripts/build-app.sh
```

The Swift package contains the automated tests. The Xcode project contains
the native app target. Run the packaged app to check notifications, login
items, file pickers and other macOS integrations.

## Reporting a problem

Include your macOS version, app version, backup type, connection mode and
steps to reproduce. Use a small disposable fixture when a database example
is needed. Remove passwords, SSH keys, access tokens, personal paths and
private database contents from logs and attachments.

## Pull requests

- Explain the problem and the resulting behavior.
- Keep unrelated changes separate.
- Add regression coverage for changes to backup correctness or persistence.
- Update every supported localization when adding interface text.
- Keep `BackupCron.xcodeproj` in sync when adding or removing Swift files.
- Run `swift test`, build the app and check the affected interface.

Database integration tests require explicitly marked disposable containers.
See [README.md](README.md#database-integration-tests) for the configuration.

Contributions are distributed under the project's [MIT license](LICENSE).
