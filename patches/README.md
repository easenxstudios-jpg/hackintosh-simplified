# Realtek Bluetooth patches

These are for an RTL8852C (USB 13d3:3612) on macOS 26.7.2 (25G332). They got Classic Bluetooth audio working on one machine. LE scanning still fails, and a macOS update will stop the patches matching.

## BlueToolFixup

`bluetoolfixup-25G332.diff` applies to [acidanthera/BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM). It's a change to that GPL-2.0 project, so it's under GPL-2.0 rather than this repo's MIT license.

## RealtekBluetoothFirmware

Build [thegwchr/RealtekBluetoothFirmware](https://github.com/thegwchr/RealtekBluetoothFirmware) 1.0.2 with one change: remove the `setName("Bluetooth USB Host Controller")` call and its `version_major >= 21` check from `publishReg`.

## Using them in the app

Put both built kexts in `../hackintosh-fixes/6-bluetooth-kext/` and `../hackintosh-fixes/9-bluetoolfixup/` next to this repo before running `build-app.sh`. It copies them into the app.

Kext binaries aren't committed here, and they shouldn't be added without checking each project's license.

## Other settings they need

- The boot argument `-btlfxboardid`
- NVRAM `bluetoothHostControllerSwitchBehavior=always`
- A USB map with the Bluetooth port set to type 3 (external)
