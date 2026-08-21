# How Doppio works, and what was actually measured

Everything here was tested on **macOS 26.6.2 (arm64, Mac15,10)** against real
applications. Where this contradicts `doppio-spec.md`, this document wins: the
spec was written before the mechanism had been tried.

## The problem

macOS treats an application as a singleton per bundle identifier. `open -n`
forces a second process, but both instances share one bundle ID, so they share
one Dock tile, one name, one set of TCC permissions, and one data directory.
Many apps also enforce their own single-instance lock.

To make a genuine second app you need two separate things, and it is worth
keeping them apart in your head:

| Axis | What it controls | Doppio calls it |
|---|---|---|
| Which bundle macOS attributes the process to | Dock icon, name, Cmd-Tab entry, TCC identity | **launch mode** |
| Where the app keeps its accounts and settings | separate logins | **isolation strategy** |

## What the spec got wrong

The spec's §3.2 claimed:

> Because the *process* was launched from the wrapper bundle, macOS attributes
> its Dock identity, app name, and permissions to the wrapper.

**This is false.** A wrapper whose stub `execve`s the target's real binary in
`/Applications` produces a working second instance with isolated data, but
macOS attributes it entirely to the original app:

```
$ lsappinfo info -only bundleid,name,bundlepath -pid <new instance>
"CFBundleIdentifier"="com.google.Chrome"
"LSDisplayName"="Google Chrome"
"LSBundlePath"="/Applications/Google Chrome.app"
```

Identity follows the **executable path**, not the launching bundle. Setting
`__CFBundleIdentifier` in the environment does not change it either — Chrome
re-registers itself as `com.google.Chrome` regardless.

So for a Shot to have its own identity, the binary it runs must live *inside the
Shot's own bundle*.

## The three launch modes

### `direct` — no separate identity

The stub `execve`s the target's real binary in place. Always works, always
survives target updates, and the data can still be isolated. But the instance
shares the original's Dock tile and name. This is the honest fallback.

### `link` — symlink farm

The wrapper mirrors the target's `Contents/` with symlinks and parks a symlink
to the target's binary inside its own `MacOS/`. Nothing is copied, so the Shot
keeps working when the target updates.

**Only suitable for apps that do not spawn helper subprocesses.** Both Chromium
and Electron fail, for the same underlying reason: their helper processes are
launched from the target's *real* path under `/Applications`, while the seatbelt
sandbox is scoped to the main bundle — the wrapper. The failures look different
but share a cause:

- Chromium: `dlopen(... /Google Chrome Framework): file system sandbox blocked open()`
- Electron: `FATAL:electron/shell/app/electron_main_delegate_mac.mm:66] Unable to find helper app`

No arrangement of symlinks fixes this, because the sandbox check happens on the
resolved real path.

### `clone` — APFS copy-on-write clone (the default)

The wrapper *is* a `cp -cR` clone of the target with a patched `Info.plist`.
Because APFS clones share their blocks until written to, this is effectively
free:

```
$ du -sh /Applications/Google Chrome.app        # 706 MB
$ time cp -cR "/Applications/Google Chrome.app" "Chrome Work.app"
real 0.39s                                     # ~0 bytes of new disk
```

Every file the app needs is now inside the Shot's own bundle at a path the
sandbox permits, so helper processes work. Verified working for Chromium,
Electron, and sandboxed App Store apps.

The one cost: a clone is pinned to the target's version at creation time. Doppio
compares `CFBundleShortVersionString` against the installed app and offers to
regenerate when they drift (`doppio doctor`, or the banner in the UI).

## The wrapper layout, and why it is shaped this way

```
Claude Personal.app/
  Contents/
    Info.plist                 # inherited from the target, identity overridden
    MacOS/
      DoppioShot               # the stub — CFBundleExecutable points here
      Claude                   # the target's binary, under its OWN name
                               #   (cloned, or a symlink in link mode)
    Doppio/shot.json           # the launch plan
    Resources/                 # a real directory, never a symlink
```

Four details are load-bearing, each learned from a specific failure:

1. **The target's binary keeps its own file name.** Chromium derives its
   framework path from the executable's *name* and aborts in `main()` if it
   cannot find `<name> Framework.framework`. Renaming the binary — even with
   `argv[0]` spoofed back to the original — breaks Chrome:

   ```
   dlopen(.../Google Chrome Framework): … not valid for use in process
   Abort trap: 6   (main + 2816)
   ```

   `argv[0]` does not help here because Chromium reads
   `_NSGetExecutablePath()`, not `argv[0]`.

2. **`CFBundleName` is preserved verbatim** from the target. Electron derives
   its helper app names from it.

3. **The whole target `Info.plist` is inherited**, with only identity keys
   overridden. Electron stores `ElectronAsarIntegrity` — a SHA-256 of
   `app.asar` — in the main bundle's plist and refuses to start without it:

   ```
   FATAL:…/asar/archive.cc:259]
   Failed to get integrity for validatable asar archive: Resources/app.asar
   ```

   `CFBundleURLTypes` and `CFBundleDocumentTypes` are deliberately *removed*, so
   a Shot does not fight the original app over deep links and file associations.

4. **The stub is a sibling, not a replacement.** `CFBundleExecutable` points at
   `DoppioShot`, which `execve`s the target binary next to it. That keeps the
   exec path inside the wrapper (so the identity is the wrapper's) while leaving
   the binary's name untouched (so the app can find its own parts).

> An earlier iteration had the stub *take* the target's executable name and
> parked the real binary as `<name>.doppio-target`, with `argv[0]` spoofed. That
> was a wrong turn: it was adopted to fix an Electron "Unable to find helper
> app" error that was actually caused by link mode's symlinked `Frameworks`, and
> it broke Chromium for the reason in (1). The layout above is verified for both
> families.

## Re-signing a clone: three traps

Changing the `Info.plist` invalidates the vendor's signature, so a clone has to
be re-signed ad-hoc. Doing that naively breaks things in three different ways.

**Entitlements must be carried over selectively.** `codesign --force --deep -s -`
strips them all, and Chromium/Electron renderers need
`com.apple.security.cs.allow-jit`. But carrying *all* of them over is worse:
`com.apple.application-identifier`, `com.apple.developer.*` and
`keychain-access-groups` are profile-bound, and an ad-hoc binary holding them is
refused by AMFI — the Shot then fails to launch from the Dock **with no crash
report at all**, while still running when exec'd from a terminal. Doppio filters
the target's entitlements to the ones that mean something without a provisioning
profile, and drops `embedded.provisionprofile` from the clone.

**Library validation must be disabled.** The re-signed binary is ad-hoc (no Team
ID) while the frameworks beside it keep the vendor's, so dyld refuses them:

```
Library not loaded: @rpath/Electron Framework.framework/Electron Framework
Reason: … mapping process and mapped file (non-platform) have different Team IDs
```

`com.apple.security.cs.disable-library-validation` is the entitlement for
exactly this, and it is not profile-bound.

**Code-directory flags must be set, not preserved.** This one is subtle: Chrome's
binary carries the `library-validation` *flag* in its CodeDirectory, and that
flag **outranks the entitlement**. Preserving flags therefore left Chrome unable
to load its own framework even with `disable-library-validation` present. Claude
has only `runtime` set, which is why it worked while Chrome did not — a good
example of why "it works for one app" proves very little here.

The working configuration for both is `adhoc,runtime`:

```
$ codesign -dv ".../Contents/MacOS/Google Chrome"
flags=0x10002(adhoc,runtime)
```

Nested helper `.app` bundles are left alone: they keep their vendor signature and
their own entitlements, and are validated independently.

## Never write through a symlink

An early version symlinked the wrapper's whole `Contents/Resources` at the
target's, then wrote the Shot's generated `AppIcon.icns` into it. That wrote
**into the original application bundle** and broke its code signature:

```
$ codesign --verify --strict /Applications/Claude.app
a sealed resource is missing or invalid
file added: /Applications/Claude.app/Contents/Resources/AppIcon.icns
```

For an app that ships its own `AppIcon.icns`, it would have overwritten it.

Two fixes, both in place:

- `link` mode mirrors `Contents/Resources` as a **real** directory of
  per-entry symlinks, so Doppio can add files without touching the target.
- `BundleForge.assertInside(_:_:)` resolves symlinks before every write and
  refuses anything landing outside the wrapper. `WrapperSafetyTests` reproduces
  the exact escape and asserts it is refused.

The lesson generalises: never symlink a directory you intend to write into.

## Isolation strategies

| Strategy | Mechanism | Notes |
|---|---|---|
| `chromium` | `--user-data-dir=<dir>` | Verified: separate profile and logins |
| `electron` | `--user-data-dir=<dir>` | Verified with Claude; VS Code also wants `--extensions-dir` |
| `firefox` | `--profile <dir> -no-remote` | `-no-remote` is mandatory; pre-create the profile dir |
| `home` | `HOME=<dir>` | Works only for apps that read `$HOME` *directly*. **Does not work for Electron or Chromium**, which go through `NSHomeDirectory()` |
| `env` | arbitrary vars (`XDG_CONFIG_HOME`, …) | JetBrains and Eclipse-platform IDEs |
| `none` | nothing | Shared data |

### `NSHomeDirectory()` ignores `$HOME` — measured

This is worth stating precisely, because it decides what the `home` strategy can
and cannot do. On macOS 26.6:

```
$ HOME=/tmp/fake-home ./homecheck
HOME env       : /tmp/fake-home
NSHomeDirectory: /Users/you          # the real home, not $HOME
FileManager    : /Users/you
```

So any app that resolves its support directory through Foundation or through
Chromium's own user-directory code is unaffected by a `HOME` override. Only apps
that read the `$HOME` variable themselves (shells, many Java and Eclipse-based
tools) are isolated by it.

`LSEnvironment` in `Info.plist` was tested as a way to set `HOME` without a stub.
Launch Services does apply it and the app starts cleanly, but it isolates
nothing for Electron, for the same reason.

### Web Shots store data where WebKit decides

There is no public API for pointing WebKit at an arbitrary directory, and — per
the measurement above — a `HOME` override does not move it either. With
`WKWebsiteDataStore.default()` a web Shot's cookies land in
`~/Library/WebKit/<wrapper bundle ID>/`, which *is* isolated per Shot (each
wrapper has its own bundle ID) but is not the Shot's declared data directory:

```
declared dataDir: …/Application Support/Doppio/Shots/<uuid>   (0 files)
actual storage:   ~/Library/WebKit/org.doppio-mac.shot.<uuid>  (populated)
```

Doppio now uses `WKWebsiteDataStore(forIdentifier:)` on macOS 14+ so the
location is explicit, falls back to `.default()` below that, and deletes
`~/Library/WebKit/<bundle ID>` when a web Shot is removed with its data.

## Sandboxed apps cannot be isolated — tested

The appealing theory: a sandbox container is keyed to the bundle identifier, so a
clone with a fresh identifier should get a fresh container and therefore a fresh
account. Tested with WhatsApp (Mac App Store, sandboxed) on macOS 26.6:

- the clone launches and registers its own Dock identity, then **exits within
  seconds**;
- **no container is created** at `~/Library/Containers/<wrapper bundle ID>`;
- the original app's container is not touched either, so nothing is written
  anywhere;
- a `HOME` override is ignored, as it is for any sandboxed process.

Note also that Mac App Store binaries carry the entitlement key
`application-identifier` — the *bare* key, not `com.apple.application-identifier`
— which an entitlement filter written for Developer ID apps will miss.

So sandboxed targets get `direct` mode: a second instance sharing the original's
data, honestly labelled. This is the same limitation the commercial alternative
documents, and it is a genuine platform constraint rather than a missing feature.

## Supervisor mode needs no `LSUIElement`

Ephemeral Shots and menu-bar Shots keep the stub alive as a parent instead of
`exec`ing. The obvious worry is two Dock tiles — one for the supervisor, one for
the instance. Measured: there is one. The supervisor and its child share a
bundle, so Launch Services registers them as a single application:

```
34678     1 …/Claude Temp.app/Contents/MacOS/DoppioShot   (supervisor)
34707 34678 …/Claude Temp.app/Contents/MacOS/Claude        (the instance)
$ lsappinfo list | grep -c '"Claude Temp"'
1
```

Quitting the instance erases the ephemeral data directory and the supervisor
exits with it.

## Consequences worth telling users about

- **Permissions are re-requested.** Each Shot is a distinct app to macOS, so
  camera, microphone, screen recording and file access are prompted per Shot.
  That is isolation working, but it reads like a bug.
- **A cloned Shot needs regenerating after the target updates.**
- **Ad-hoc signatures are local-only.** Generated bundles carry no quarantine
  flag so Gatekeeper accepts them, but a Shot copied to another Mac will not
  pass. Regenerate it there.
- **The original app is never modified.** `codesign --verify --strict` on every
  target is part of the release checklist.
