# GRID (flutter_mobile_ui)

Flutter app for GRID, the Smart Household Electrical Monitoring System.

## Versioning & releases

The app version lives in one place: `version:` in `pubspec.yaml`, written as
`MAJOR.MINOR.PATCH+BUILD` (e.g. `2.0.0+45`). Android uses it for the
installed app's version, and Settings → About shows it.

**Version name (`2.0.0`)**: bump it by hand before a release:

| Change | Bump | Example |
| --- | --- | --- |
| Bug fixes only | PATCH | 2.0.0 → 2.0.1 |
| New features | MINOR | 2.0.1 → 2.1.0 |
| Big or breaking changes | MAJOR | 2.1.0 → 3.0.0 |

**Build number (`+45`)**: don't edit it. `tool/build.ps1` sets it to the
git commit count, so every build from a newer commit is numbered higher and
can be traced back to its commit. (The `+1` in pubspec is only used by a
plain `flutter run`.)

### Making a release

1. Bump `version:` in `pubspec.yaml` and commit.
2. Build from `ui_revamp`, the app's main branch (the repo's `main` isn't
   used for the app):
   ```powershell
   ./tool/build.ps1 apk --release
   ```
   Always release from that same branch. The build number is the branch's
   commit count, and other branches have fewer commits, so a build from one
   of them would get a lower number. If the release branch ever changes,
   merge `ui_revamp` into the new one first so the count keeps going up.
   If PowerShell blocks the script, run
   `powershell -ExecutionPolicy Bypass -File tool/build.ps1 apk --release`.
3. Tag the commit and push the tag:
   ```powershell
   git tag v2.0.0
   git push --tags
   ```

Release APKs are currently signed with the building machine's debug key, so
an APK built on one PC can't update an install built on another. Have one
person build the APKs that get handed out.
