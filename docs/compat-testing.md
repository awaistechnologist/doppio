# Adding and verifying a compatibility rule

A rule in `compat-db/rules.json` tells Doppio how to give one family of apps its
own identity and its own data. A rule that is wrong produces a Shot that crashes
on launch, so every rule needs testing before it ships.

## The rule format

```json
{
  "id": "some-app",
  "bundleIDPrefixes": ["com.vendor.SomeApp"],
  "frameworks": [],
  "strategy": "electron",
  "launchMode": "clone",
  "extraArgs": ["--user-data-dir=${dataDir}"],
  "extraEnv": {},
  "notes": "What you verified, and anything surprising.",
  "verifiedOn": "macOS 26.6",
  "contributor": "your-handle"
}
```

- `${dataDir}` is replaced with the Shot's data directory.
- `bundleIDPrefixes` match on a component boundary: `com.vendor.App` matches
  `com.vendor.App.beta` but not `com.vendor.Applet`.
- `frameworks` is for sniffing, so unknown apps in a known family work with no
  rule. `__SANDBOXED__` is a pseudo-entry matching any sandboxed app.
- Matching order: exact/longest bundle-ID prefix, then sandbox detection, then
  framework sniffing, then the `fallback` rule.

## Choosing a launch mode

Start with `clone`. It is verified for every family tested so far and costs
almost nothing thanks to APFS cloning.

Only use `link` if you have confirmed the app starts under it — it fails for
anything that spawns helper subprocesses, which includes all Chromium and
Electron apps. See `docs/mechanism.md`.

Use `direct` when the app cannot be given a separate identity at all, or when
running two copies is possible but isolation is not. Say so in `notes` — a
truthful `direct` rule is much better than a `clone` rule that crashes.

## The checklist

Most of it is automated. Run this and paste the output into your pull request:

```bash
doppio create --app "<App>" --name "<App> Test"
doppio verify "<App> Test"
```

`verify` covers everything mechanical: the bundle and its signature, Doppio's
provenance key, the launch plan, **the original app's signature**, clone
freshness, that the Shot launches *and stays running*, that it has its own Dock
identity, that helper processes are alive, that data lands in the Shot's own
location, that a sandboxed target actually received a container, and that no
crash reports appeared.

Two things it cannot check, which you must do by hand:

- [ ] **Log into a different account** in the Shot, and confirm the original app
      is still logged into the first one. This is the only real proof of
      isolation, and it needs credentials no tool should handle.
- [ ] **Survives a target update** (or is correctly reported stale by
      `doppio doctor` for a `clone` Shot).

Then remove it: `doppio remove "<App> Test" --data`.

### If you prefer to check by hand

- [ ] **It launches** and stays running for at least a minute.
- [ ] **No crash reports** appeared:
      `ls -t ~/Library/Logs/DiagnosticReports/*.ips | head -3`
- [ ] **Helper processes are alive** (for Chromium/Electron apps — a main
      process with no helpers means the renderers are dying):
      `ps -Ao pid,command | grep "<App> Test.app" | grep -ci helper`
- [ ] **Its own Dock identity**, if the mode claims one:
      `lsappinfo info -only bundleid,name,bundlepath -pid <pid>`
      should report `org.doppio-mac.shot.<uuid>` and your Shot's name.
- [ ] **Data is isolated** — log into a different account in the Shot, confirm
      the original app is still logged into the first one, and check the Shot's
      data directory is populated: `doppio info "<App> Test"`.
- [ ] **Both run at once**, independently.
- [ ] **The original app is untouched** — this one is not optional:
      `codesign --verify --strict "/Applications/<App>.app"`
- [ ] **Delete cleans up**: `doppio remove "<App> Test" --data`.
- [ ] **Survives a target update** (if `link` or `direct`), or is correctly
      reported as stale by `doppio doctor` (if `clone`).

## Diagnosing a failure

Run the **stub** directly to see what the app prints — a GUI launch swallows
stderr. It must be `DoppioShot`, not the target binary beside it: the stub is
what reads `shot.json` and applies the isolation flags, so running the target
directly tells you nothing about the Shot.

```bash
"$HOME/Applications/Doppio/<App> Test.app/Contents/MacOS/DoppioShot"
```

Known signatures:

| Output | Meaning |
|---|---|
| `Unable to find helper app` | Electron cannot find its helpers. Use `clone`; check `CFBundleName` and `CFBundleExecutable` survived. |
| `Failed to get integrity for validatable asar archive` | `ElectronAsarIntegrity` was not inherited from the target plist. |
| `file system sandbox blocked open()` | Chromium helper reaching outside the bundle. Use `clone`. |
| Profile manager appears (Firefox) | The profile directory did not exist, or `-no-remote` is missing. |
| Runs but shares the original's account | The isolation flag is wrong or ignored. Try `home`, or find the app's own profile flag. |

Remember that `home` does **not** isolate Electron or Chromium apps: they read
the user directory from the password database, not `$HOME`.
