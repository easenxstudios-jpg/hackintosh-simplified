# Hackintosh Simplified

A macOS app that checks a hackintosh and helps with common problems: Wi-Fi, Bluetooth, sound, USB, graphics, Ethernet, the clock, sleep and OpenCore settings.

> **Early preview. Use it at your own risk.** The scan has run on one machine only. One system setting fix (turning off hibernation) has worked through the macOS password prompt on that machine. Boot fixes have only been tested against a temporary test folder, never on a real EFI. A bad boot change can stop your Mac starting.

**Website:** https://easenxstudios-jpg.github.io/hackintosh-simplified/

## What it does

- **Scans without changing anything.** It needs no password, and it doesn't read your serial number.
- **Applies fixes it can automate.** You see the changes first. Boot changes back up your whole EFI, and macOS's own dialog asks for your password.
- **Fixes safe problems with one button.** Riskier changes stay separate, so you decide.
- **Checks OpenCore settings.** The rules were worked out from OpenCore's documentation and source, and checked against 1.0.9. Newer versions may differ. If OpenCore Vault protects your boot files, the app won't edit them.
- **Checks the NullMoth NVIDIA driver.** It reads the driver's health and sends you to its official 1401 app to install or update it. This project has no NullMoth code or files, and isn't affiliated with NullMoth.
- **Guides you through the rest.** USB maps and Wi-Fi drivers depend on your exact machine, so those are step-by-step.
- **Has a searchable Problem Guide.** It covers common problems in plain words, from startup errors to sleep, each with a link to its source. It can't cover every possible problem.
- **Says when it has no fix.** It knows of no software fix for AirDrop on Realtek and Intel cards, for example.

It never restarts your Mac, changes SIP, or generates serial numbers.

## Windows setup wizard

`HackintoshSimplifiedSetup.exe` helps you start from a Windows PC. It checks your hardware, walks you through Windows and BIOS settings, and prepares a macOS USB drive. It lists only USB drives, and you have to type ERASE before it erases one.

It puts OpenCore and drivers on the USB, checks the settings with OpenCore's validator, and checks macOS recovery against Apple's signature.

- **PCs it generates a setup for:** Intel Coffee Lake and Comet Lake desktops only. For others, it explains why and points to [OpCore Simplify](https://github.com/lzhoang2801/OpCore-Simplify).
- **First boot:** OpenCore loads the USB's drivers at startup, so the processor, Intel graphics support, audio, USB and Ethernet can work from the first boot. It can't promise speed. NVIDIA and Wi-Fi drivers have to wait until macOS is installed.
- **Not tested yet:** a real USB stick, or starting macOS on a real PC with what it builds. On a Windows test machine, the scan, validator, Apple signature check and erase code all ran on a temporary virtual disk.
- **Serial numbers:** it uses OpenCore's placeholders, so iCloud and iMessage may not work until you set up your own.
- **Windows warning:** the exe isn't code signed, so SmartScreen may warn you. Choose **More info**, then **Run anyway**, only if you trust this project.

To build it, install Go, then run `go build -o HackintoshSimplifiedSetup.exe .` in `windows/` with `GOOS=windows`.

## Before you apply a fix

Keep a bootable USB with a working OpenCore, and test that it starts. If a fix stops your Mac starting, this app can't run to undo it.

Backups are in `~/Library/Application Support/Hackintosh Simplified/Backups`. They hold your serial numbers, so don't share them.

## Known limitations

- **A "Working" result is limited.** It means macOS reports the feature, not that it works well. For example, it can't hear whether your speakers play sound.
- **Kexts aren't verified.** Kexts run inside the macOS kernel. The app downloads them from each project's newest GitHub release and shows the source and SHA-256, but it doesn't compare that hash with a known-good value or check that the kext suits your macOS version. A compromised release would get through.
- **It only supports OpenCore.** It turns boot fixes off if it can't confirm OpenCore and the partition it started from.
- **Some advice comes from one machine.** The Realtek notes come from one ASUS laptop with an RTL8852CE, so your results may differ.
- **The app isn't notarized.** macOS warns that it can't check the app for malware. See [Download](#download) for how to open it.

## Download

Get the `.dmg` from the [Releases page](https://github.com/easenxstudios-jpg/hackintosh-simplified/releases). It needs an Intel processor and macOS 13 or later.

1. Open the `.dmg` and drag the app to Applications.
2. Open the app. macOS will block it the first time.
3. On macOS 15 or later, go to **System Settings > Privacy & Security** and click **Open Anyway**. On macOS 13 or 14, right-click the app and choose **Open**.

The download doesn't include the patched Realtek Bluetooth kexts, so that one fix tells you they're missing. See [patches/README.md](patches/README.md) to build them.

## Build

You need Xcode 26 or later.

```bash
zsh build-app.sh
```

The app is in `build/`. Run the scan from Terminal with `--scan` to print a report without opening a window.

`zsh make-release.sh` builds the public `.dmg` in `dist/`.

## Test

```bash
swift test --arch x86_64
```

These settings add optional tests:

- `HS_NETWORK_TESTS=1` includes a real kext download.
- `HS_SAMPLE_CONFIG=/path/to/config.plist` checks that a real config survives being read and rewritten.

## Reporting a problem

Use **Copy Report** in the app and paste the result into an issue. It leaves out MAC addresses, your account name and your computer's name, but read it before posting. Never post your `config.plist` or a backup without removing the serial numbers.

## License

MIT, except `patches/`. See [LICENSE](LICENSE) and [patches/README.md](patches/README.md).

Installing macOS on non-Apple hardware may break Apple's software license, so check what applies to you. This project isn't affiliated with Apple, OpenCore or any driver project it links to.
