import Foundation

public enum FixCatalog {
    /// The one macOS build the bundled Bluetooth patches match.
    public static let realtekPatchedBuild = "25G332"

    private static let lilu = KextSpec("Lilu.kext")
    private static let liluOrigin = KextOrigin.github(repo: "acidanthera/Lilu", kexts: [lilu])

    private static func auto(_ plan: FixPlan) -> FixKind {
        .automatic { _ in plan }
    }

    /// Fixes that depend on this machine's state. Unknown IDs return nil.
    public static func fix(id: String, facts: SystemFacts) -> Fix? {
        all(facts: facts).first { $0.id == id }
    }

    public static func all(facts: SystemFacts) -> [Fix] {
        let connectScript = Bundle.main.resourceURL?.appendingPathComponent("connect-bluetooth.js").path ?? "connect-bluetooth.js"
        var fixes: [Fix] = [
            Fix(id: "sound-simplehda", title: "Install SimpleHDA",
                summary: "Restores the audio driver Tahoe removed. It needs AppleALC too.",
                kind: auto(FixPlan(kexts: [
                    liluOrigin,
                    .github(repo: "acidanthera/AppleALC", kexts: [KextSpec("AppleALC.kext", after: ["Lilu.kext"])]),
                    .github(repo: "laobamac/SimpleHDA", kexts: [KextSpec("SimpleHDA.kext", after: ["Lilu.kext", "AppleALC.kext"])]),
                ]))),
            Fix(id: "sound-applealc", title: "Install AppleALC",
                summary: "The standard driver add-on for hackintosh sound.",
                kind: auto(FixPlan(kexts: [
                    liluOrigin,
                    .github(repo: "acidanthera/AppleALC", kexts: [KextSpec("AppleALC.kext", after: ["Lilu.kext"])]),
                ]))),
            Fix(id: "sound-layout", title: "Change audio layout",
                summary: "Each number is a different wiring map for your audio chip. Try another if speakers, headphones or the microphone don't work. AppleALC's Supported Codecs list shows the numbers for your chip.",
                parameter: FixParameter(label: "Layout number", defaultValue: facts.config?.layoutID.map(String.init) ?? "1", help: "A number from 1 to 255"),
                kind: .automatic { value in
                    guard let value, let layout = Int(value.trimmingCharacters(in: .whitespaces)) else {
                        throw FixError("Enter a layout number.")
                    }
                    return FixPlan(edits: [.setLayoutID(layout)])
                }),

            Fix(id: "bt-realtek-patched", title: "Install patched Realtek Bluetooth",
                summary: "Installs the kexts that got an RTL8852C (13d3:3612) working on macOS \(realtekPatchedBuild), and sets the boot argument and NVRAM value they need. Your USB map must mark the Bluetooth port as external (type 3). A macOS update will stop these patches matching.",
                risk: .medium,
                kind: auto(FixPlan(
                    edits: [.addBootArg("-btlfxboardid")],
                    kexts: [
                        liluOrigin,
                        .bundled(folder: "BundledKexts", kexts: [
                            KextSpec("BlueToolFixup.kext", after: ["Lilu.kext"]),
                            KextSpec("RealtekBluetoothFirmware.kext", after: ["Lilu.kext"]),
                        ]),
                    ],
                    commands: ["/usr/sbin/nvram bluetoothHostControllerSwitchBehavior=always"]))),
            Fix(id: "bt-realtek", title: "Install Realtek Bluetooth driver",
                summary: "Installs RealtekBluetoothFirmware and BlueToolFixup. On recent macOS it may also need patches for your exact build, so it might not be enough alone.",
                risk: .medium,
                kind: auto(FixPlan(
                    kexts: [
                        liluOrigin,
                        .github(repo: "acidanthera/BrcmPatchRAM", kexts: [KextSpec("BlueToolFixup.kext", after: ["Lilu.kext"])]),
                        .github(repo: "thegwchr/RealtekBluetoothFirmware", kexts: [KextSpec("RealtekBluetoothFirmware.kext", after: ["Lilu.kext"])]),
                    ],
                    commands: ["/usr/sbin/nvram bluetoothHostControllerSwitchBehavior=always"]))),
            Fix(id: "bt-intel", title: "Install Intel Bluetooth driver",
                summary: "Installs IntelBluetoothFirmware, IntelBTPatcher and BlueToolFixup.",
                kind: auto(FixPlan(kexts: [
                    liluOrigin,
                    .github(repo: "acidanthera/BrcmPatchRAM", kexts: [KextSpec("BlueToolFixup.kext", after: ["Lilu.kext"])]),
                    .github(repo: "OpenIntelWireless/IntelBluetoothFirmware", kexts: [
                        KextSpec("IntelBluetoothFirmware.kext", after: ["BlueToolFixup.kext"]),
                        KextSpec("IntelBTPatcher.kext", after: ["Lilu.kext"]),
                    ]),
                ]))),
            Fix(id: "bt-broadcom", title: "Install Broadcom Bluetooth driver",
                summary: "Installs BrcmPatchRAM3, BrcmFirmwareData and BlueToolFixup. These are for Broadcom chips, so check your chip's maker first.",
                kind: auto(FixPlan(kexts: [
                    liluOrigin,
                    .github(repo: "acidanthera/BrcmPatchRAM", kexts: [
                        KextSpec("BlueToolFixup.kext", after: ["Lilu.kext"]),
                        KextSpec("BrcmFirmwareData.kext"),
                        KextSpec("BrcmPatchRAM3.kext", after: ["BrcmFirmwareData.kext"]),
                    ]),
                ]))),
            Fix(id: "bt-unsupported", title: "No driver known for this Bluetooth chip", summary: "", needsRestart: false,
                kind: .unavailable(reason: "This app can't tell who made this chip, or doesn't have a driver for it, so it won't guess. A wrong driver wouldn't help and could cause problems. A supported USB Bluetooth adapter is the simplest way around it.")),
            Fix(id: "bt-connect-help", title: "Connect a device that won't pair", summary: "A workaround for Realtek chips where Settings fails to connect.", needsRestart: false,
                kind: .guided(steps: [
                    "Put the device in pairing mode.",
                    "Find its address under System Settings > Bluetooth, or by holding Option while opening the Bluetooth menu.",
                    "In Terminal, run: osascript -l JavaScript \"\(connectScript)\" AA-BB-CC-DD-EE-FF, using your device's address with dashes. On the tested Mac this paired headphones where Settings' Connect button failed.",
                ], link: nil)),

            Fix(id: "wifi-intel", title: "Install Intel Wi-Fi driver", summary: "Intel cards use the OpenIntelWireless driver. The right file depends on your macOS version, so this is a manual install.", needsRestart: true,
                kind: .guided(steps: [
                    "Open the project's releases and download the file for your macOS version. If there isn't one for yours yet, your version isn't supported.",
                    "Copy the kext to EFI/OC/Kexts and add it to Kernel > Add.",
                    "Restart, then scan again.",
                ], link: "https://github.com/OpenIntelWireless/itlwm/releases")),
            Fix(id: "wifi-broadcom", title: "Set up Broadcom Wi-Fi", summary: "On macOS Sonoma and later, Broadcom cards need root patches from OpenCore Legacy Patcher. This is the route with the most AirDrop and Continuity support, but it changes system files and lowers security.", risk: .high,
                kind: .guided(steps: [
                    "Read the project's instructions for your macOS version and card.",
                    "Back up your Mac first, and keep a bootable USB ready.",
                    "Follow its steps. They can break after macOS updates.",
                ], link: "https://github.com/dortania/OpenCore-Legacy-Patcher")),
            Fix(id: "wifi-realtek", title: "Realtek Wi-Fi driver (experimental)", summary: "AirPort_RTW89 is a preview driver that needs extra system components. It has no AirDrop support, and speeds can be very low. Check that your card is on its supported list.", risk: .high,
                kind: .guided(steps: [
                    "Copy your working EFI to a USB stick, and test that it boots.",
                    "Download the driver and tools from the project's releases, and read TESTING.md.",
                    "Install using its instructions, then restart.",
                    "If it's slow or fails, report it using the project's collect_logs tool.",
                ], link: "https://github.com/FranciumOS-org/Airport_RTW89/releases")),
            Fix(id: "wifi-realtek-slow", title: "If Wi-Fi is slow", summary: "This driver is still a preview, so low speed is usually a driver limit that settings can't fix.", needsRestart: false,
                kind: .guided(steps: [
                    "If you have Ethernet, turn Wi-Fi off and use that.",
                    "Download the driver's tools, then report your result using its collect_logs tool, so the developer can fix your card.",
                ], link: "https://github.com/FranciumOS-org/Airport_RTW89/issues")),
            Fix(id: "wifi-unsupported", title: "No driver known for this card", summary: "", needsRestart: false,
                kind: .unavailable(reason: "This app doesn't know a working macOS driver for this Wi-Fi card. The usual fixes are a USB Wi-Fi adapter or replacing the card, if yours is removable.")),
            Fix(id: "continuity-unavailable", title: "No software fix available", summary: "", needsRestart: false,
                kind: .unavailable(reason: "No fix found for this Wi-Fi card. The only reliable route for AirDrop is a Broadcom card with macOS-compatible firmware, and on recent macOS that also needs OpenCore Legacy Patcher.")),
            Fix(id: "show-network-card", title: "Stop hiding the network card",
                summary: "Turns off the ACPI table that hides the card from macOS. A driver is still needed afterward.",
                kind: auto(FixPlan(edits: [.setACPIEnabled(pathContains: "Disable_Network", enabled: false)]))),
            Fix(id: "single-network", title: "Use one network connection", summary: "Keep only your faster connection on while using AirPlay.", needsRestart: false,
                kind: .guided(steps: [
                    "If Ethernet is faster, click the Wi-Fi icon in the menu bar and turn Wi-Fi off.",
                    "Start AirPlay again from your other device.",
                ], link: nil)),

            Fix(id: "usb-map", title: "Build a USB map", summary: "macOS allows 15 ports per controller, so a map has to choose which ports to use. It depends on your machine's physical ports, so it can't be built automatically.", risk: .medium,
                kind: .guided(steps: [
                    "Start Windows or Windows PE on this machine, and run USBToolBox.",
                    "Use Discover Ports, and plug a USB 2 and a USB 3 device into each port.",
                    "Select at most 15 ports. Keep the ports for your boot drive, keyboard, webcam and Bluetooth.",
                    "Build the map, copy it to EFI/OC/Kexts, and add it with USBToolBox.kext to Kernel > Add.",
                ], link: "https://github.com/USBToolBox/tool")),
            Fix(id: "xhci-off", title: "Turn off XhciPortLimit", summary: "Turns off this quirk. Build a USB map as well if you depended on it, or some ports may stop working.", risk: .medium,
                kind: auto(FixPlan(edits: [.setKernelQuirk("XhciPortLimit", false)]))),

            Fix(id: "gpu-whatevergreen", title: "Install WhateverGreen", summary: "Fixes the most common Intel and AMD graphics problems. Some setups also need device properties for their exact graphics chip.",
                kind: auto(FixPlan(kexts: [liluOrigin, .github(repo: "acidanthera/WhateverGreen", kexts: [KextSpec("WhateverGreen.kext", after: ["Lilu.kext"])])]))),

            Fix(id: "eth-intelmausi", title: "Install IntelMausi", summary: "Driver for most Intel Ethernet chips.",
                kind: auto(FixPlan(kexts: [liluOrigin, .github(repo: "acidanthera/IntelMausi", kexts: [KextSpec("IntelMausi.kext", after: ["Lilu.kext"])])]))),
            Fix(id: "eth-rtl8111", title: "Install RealtekRTL8111", summary: "Driver for Realtek RTL8111-family Ethernet.",
                kind: auto(FixPlan(kexts: [.github(repo: "Mieze/RTL8111_driver_for_OS_X", kexts: [KextSpec("RealtekRTL8111.kext")])]))),
            Fix(id: "eth-lucy", title: "Install LucyRTL8125Ethernet", summary: "Driver for Realtek 2.5 Gb Ethernet.",
                kind: auto(FixPlan(kexts: [.github(repo: "Mieze/LucyRTL8125Ethernet", kexts: [KextSpec("LucyRTL8125Ethernet.kext")])]))),
            Fix(id: "eth-i225", title: "Intel 2.5 Gb Ethernet", summary: "These chips usually need boot arguments or a separate driver, depending on your macOS version.", needsRestart: true,
                kind: .guided(steps: [
                    "Check the Dortania guide's Ethernet section for your exact chip and macOS version.",
                    "Apply what it lists for your chip, and restart.",
                ], link: "https://dortania.github.io/OpenCore-Install-Guide/ktext.html")),
            Fix(id: "eth-unknown", title: "No driver known for this Ethernet chip", summary: "", needsRestart: false,
                kind: .unavailable(reason: "This app doesn't have a driver for this Ethernet chip. A USB Ethernet adapter is the simplest way around it.")),

            Fix(id: "time-network", title: "Set the time automatically", summary: "Turns on network time, so macOS corrects its clock.", needsRestart: false,
                kind: auto(FixPlan(commands: ["/usr/sbin/systemsetup -setusingnetworktime on"]))),
            Fix(id: "time-zone", title: "Change time zone", summary: "Sets the time zone directly. It's useful when Settings doesn't offer yours.", needsRestart: false,
                parameter: FixParameter(label: "Time zone", defaultValue: facts.timeZone, help: "For example Europe/London or Asia/Calcutta"),
                kind: .automatic { value in
                    let zone = normalizedTimeZone(value ?? "")
                    guard TimeZone(identifier: zone) != nil, zone.range(of: "^[A-Za-z_/+-]+$", options: .regularExpression) != nil else {
                        throw FixError("That isn't a known time zone.")
                    }
                    return FixPlan(commands: ["/usr/sbin/systemsetup -settimezone \(Shell.quote(zone))"])
                }),

            Fix(id: "hibernate-off", title: "Turn off hibernation", summary: "Uses plain sleep instead of hibernation. If the battery runs out during sleep, unsaved work is lost.", needsRestart: false,
                kind: auto(FixPlan(commands: ["/usr/bin/pmset -a hibernatemode 0"]))),
            Fix(id: "input-voodoops2", title: "Install VoodooPS2", summary: "Driver for PS/2 keyboards and trackpads. I2C trackpads need VoodooI2C and may need extra ACPI setup.",
                kind: auto(FixPlan(kexts: [liluOrigin, .github(repo: "acidanthera/VoodooPS2", kexts: [KextSpec("VoodooPS2Controller.kext", after: ["Lilu.kext"])])]))),
            Fix(id: "battery-driver", title: "Install battery driver", summary: "Installs VirtualSMC and SMCBatteryManager. Laptops also usually need battery ACPI patches.",
                kind: auto(FixPlan(kexts: [
                    liluOrigin,
                    .github(repo: "acidanthera/VirtualSMC", kexts: [
                        KextSpec("VirtualSMC.kext", after: ["Lilu.kext"]),
                        KextSpec("SMCBatteryManager.kext", after: ["VirtualSMC.kext"]),
                    ]),
                ]))),

            Fix(id: "verbose-off", title: "Turn off verbose startup", summary: "Shows the Apple logo at startup again.",
                kind: auto(FixPlan(edits: [.removeBootArg("-v")]))),
        ]
        fixes += ConfigDoctor.fixes(facts: facts)
        fixes += NullMothDoctor.fixes(facts: facts)
        if let device = facts.efiDevice {
            fixes.append(Fix(id: "mount-efi", title: "Open boot partition", summary: "Mounts \(device), the partition OpenCore started from. This only opens it and changes nothing.", needsRestart: false,
                             kind: auto(FixPlan(commands: ["/usr/sbin/diskutil mount \(Shell.quote(device))"]))))
        }
        return fixes
    }

    /// systemsetup rejects some current names, such as Asia/Kolkata, and only accepts the older ones.
    public static func normalizedTimeZone(_ value: String) -> String {
        let zone = value.trimmingCharacters(in: .whitespaces)
        let aliases = ["Asia/Kolkata": "Asia/Calcutta", "Asia/Ho_Chi_Minh": "Asia/Saigon", "Asia/Kathmandu": "Asia/Katmandu", "Europe/Kyiv": "Europe/Kiev"]
        return aliases[zone] ?? zone
    }
}
