# Changelog

Notable changes to Doppio. Versions follow [semantic versioning](https://semver.org).
The version in `Sources/DoppioCore/Models/DoppioPaths.swift` is the source of
truth, and the release workflow refuses to build if a tag disagrees with it.

## [Unreleased]

## [0.5.0] — 2026-08-21

First release intended for anyone other than the author.

### Added
- Generate Shots from installed apps, websites, or documents, each with its own
  Dock icon, name and isolated data.
- `doppio verify` runs the compatibility checklist automatically: signature,
  provenance, the original app's signature, whether the Shot launches *and stays
  running*, helper processes, isolated data, and crash reports attributable to
  the Shot.
- `doppio uninstall` removes everything Doppio put on the machine — Shots, their
  data, website data, settings, the command line tool and the app — after
  showing exactly what will go. Data pointed somewhere of your own is left alone.
  Also available in the app as **Remove Everything…**.
- Universal builds via `./scripts/build-app.sh --universal`, so the app and the
  stub embedded in every Shot run on Intel as well as Apple Silicon.
- Compatibility database of 31 rules covering 53 bundle identifiers.
- Ephemeral Shots that erase their data on quit, optional menu-bar presence,
  icon tint and badge, and a CLI with `--json` output throughout.

### Known limitations
- **Sandboxed / Mac App Store apps cannot be isolated.** Tested: no container is
  created for a cloned bundle identifier and the clone exits on launch. Those
  rules fall back to `direct` mode, which shares the original's data.
- **Cloned Shots pin the app's version.** When the original updates, the Shot
  keeps running the version it was cloned from; `doppio doctor` reports it.
- **Only 4 of 31 rules are verified end-to-end** (Chrome, Claude, and two
  verified negatives). The rest carry `verifiedOn: null`.
- **Verified only on macOS 26.6, Apple Silicon.** macOS 13–15 and Intel are
  untested despite being declared supported.
- Builds are ad-hoc signed, not notarised: a build copied to another Mac needs
  the quarantine flag cleared, or to be rebuilt there.

[Unreleased]: https://github.com/OWNER/doppio/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/OWNER/doppio/releases/tag/v0.5.0
