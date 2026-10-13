# Scripts

## INSTALL_APP.sh

```
./INSTALL_APP.sh [options…]

  (no options)    Check the tools, run the tests, build "Data Syncer.app" (BUILD_APP.sh) and
                  copy it to /Applications (asking first).
  -t, --to DIR    Put the finished app in DIR instead of /Applications — for example
                  ./INSTALL_APP.sh --to ~/Desktop   (DIR must already exist).
  -u, --universal Build one app that runs on Apple-silicon and Intel Macs (for copying to another Mac).
  -s, --sign ID   Sign with a certificate from your Keychain, so Full Disk Access and Keychain
                  permissions survive rebuilds (below). Or set DATASYNCER_SIGN_IDENTITY.
  -k, --skip-tests  Don't run the tests first (quicker when you just pulled new code).
  -n, --no-copy   Build only; leave the app in build/ and don't touch /Applications.
  -y, --yes       Don't ask before installing tools, installing on a failed test run, or replacing
                  an app that is already there.
  -c, --check     Only report what is installed or missing (and what the installed app was built
                  for and signed with); change nothing.
  -h, --help      This help.
```

Needs macOS 14 or newer and Xcode's command-line tools; when they are missing it offers to start
Apple's installer (`xcode-select --install`), then asks you to run it again. Test output goes to
`build/test.log`; a red suite asks before installing (or stops, without `--yes`). A failed build or
copy stops with the reason — the old app is never replaced by a broken one. Safe to run again at
any time: it rebuilds and replaces the app.

**Run it again after pulling new code.** (`BUILD_APP.sh` on its own only writes `build/`; the copy
in /Applications would stay old.)

## Full Disk Access, the Keychain, and the signature

macOS remembers a permission (Full Disk Access, a Keychain item's "always allow") by the app's
*code signature identity*. The default signature is **ad hoc**: its identity is a hash of the exact
build, so **every rebuild looks like a different app** — the Full Disk Access switch has to be
turned off and on again for the new build, and the Keychain asks once per saved sign-in. Annoying,
but harmless.

To make permissions stick across rebuilds, sign with a certificate of your own (free, five minutes):

1. Keychain Access → menu Keychain Access → Certificate Assistant → **Create a Certificate…**
2. Name: `Data Syncer Local` (any name) · Identity Type: Self Signed Root · Certificate Type:
   **Code Signing** → Create.
3. Build with it: `./INSTALL_APP.sh --sign "Data Syncer Local"` (or `export
   DATASYNCER_SIGN_IDENTITY="Data Syncer Local"` in your shell profile and forget about it).

An Apple Development certificate works the same way. `./INSTALL_APP.sh --check` shows what the
installed app is signed with.

## Using the app on another Mac

The finished `Data Syncer.app` is self-contained: copy the whole app to the other Mac (AirDrop, a
USB drive, a share) and open it. It needs macOS 14 or newer and nothing else installed.

- **Chips:** a normal build is for the kind of Mac that made it (Apple silicon or Intel). For a
  Mac with the other kind, build with `--universal`; that app runs on both.
- **"Apple could not verify…":** the app isn't from the App Store or notarized, so the first time
  macOS blocks it. On **macOS 15 or newer**: open it once, click *Done*, then System Settings →
  Privacy & Security → scroll down → **Open Anyway**, and confirm. On **macOS 14**: right-click the
  app → *Open* → *Open*. Once is enough. (A copy made in Finder from a USB drive or share usually
  isn't flagged at all; AirDrop and downloads are.)
- Full Disk Access and sign-ins are per Mac: grant and enter them again there.

## BUILD_APP.sh

Not meant to be run by a general user — `INSTALL_APP.sh` calls it for you. It is here for
development (a quick rebuild without the tests or the install step).

```
./BUILD_APP.sh [options…]

  (no options)        Release build for this Mac's kind of chip → build/Data Syncer.app
  -u, --universal     Build for Apple-silicon AND Intel Macs in one app
  -d, --debug         Debug build (faster to compile, slower to run)
  -o, --out DIR       Put the app somewhere else (default: build/; relative to where you run it)
  -s, --sign IDENTITY Sign with a Keychain certificate (see above); default: ad hoc
  -h, --help          This help.
```

Compiles with `swift build` (output in `build/build.log`; the last 40 lines are shown when it
fails, and nothing is packaged), then assembles the `.app`: the program as `Contents/MacOS/Data
Syncer`, `icon/DataSyncer.icns`, an `Info.plist` (bundle id `com.mattwalker.datasyncer`, version
from `Sources/DataSyncerCore/Version.swift`, macOS 14 minimum, the usage descriptions macOS shows
when it asks about Desktop/Documents/Downloads, removable drives and network shares, and local
networking allowed for `http://` S3-compatible services on the LAN) and the signature.

## icon/make_icns.sh

Draws `icon/icon.svg` at 1024 px with Chrome, Edge, Brave or Arc (headless), scales it with `sips`
to every size macOS wants and makes `icon/DataSyncer.icns` with `iconutil`. The result is
committed; run it only after changing the SVG.
