# Scripts

## INSTALL_APP.sh

```
./INSTALL_APP.sh [options…]

  (no options)    Check the tools, run the tests, build "Data Syncer.app" (BUILD_APP.sh) and
                  copy it to /Applications (asking first).
  -t, --to DIR    Put the finished app in DIR instead of /Applications — for example
                  ./INSTALL_APP.sh --to ~/Desktop   (DIR must already exist).
  -n, --no-copy   Build only; leave the app in build/ and don't touch /Applications.
  -y, --yes       Don't ask before installing tools or replacing an app that is already there.
  -c, --check     Only report what is installed or missing; change nothing.
  -h, --help      This help.
```

Needs macOS 14 or newer and Xcode's command-line tools; when they are missing it offers to start
Apple's installer (`xcode-select --install`), then asks you to run it again. Test output goes to
`build/test.log`. Safe to run again at any time: it rebuilds and replaces the app.

**Using the app on another Mac:** the finished `Data Syncer.app` is self-contained — copy the whole
app to the other Mac (AirDrop, a USB drive, a share) and open it; it needs macOS 14 or newer and
nothing else installed. The signature is ad hoc, so the first time macOS may say the app is from an
unidentified developer: right-click it, choose *Open*, and confirm once (or allow it in
System Settings → Privacy & Security). Build on an Apple-silicon Mac for Apple-silicon Macs and on an
Intel Mac for Intel Macs; the build is for the kind of Mac that made it.

## BUILD_APP.sh

```
./BUILD_APP.sh [options…]

  (no options)    Release build → build/Data Syncer.app
  -d, --debug     Debug build (faster to compile, slower to run)
  -o, --out DIR   Put the app somewhere else (default: build/)
  -h, --help      This help.
```

Compiles with `swift build`, then assembles the `.app`: the program as `Contents/MacOS/Data Syncer`,
`icon/DataSyncer.icns`, an `Info.plist` (bundle id `com.mattwalker.datasyncer`, version from
`Sources/DataSyncerCore/Version.swift`, macOS 14 minimum) and an ad-hoc signature, which is enough
for an app you build and use on your own Macs.

## icon/make_icns.sh

Draws `icon/icon.svg` at 1024 px with Chrome, Edge, Brave or Arc (headless), scales it with `sips`
to every size macOS wants and makes `icon/DataSyncer.icns` with `iconutil`. The result is
committed; run it only after changing the SVG.
