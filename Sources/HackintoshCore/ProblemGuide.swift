import Foundation

/// A searchable guide to common hackintosh problems, in everyday words.
/// Each entry links to its source, so people can read further and check it against their setup.
public struct GuideEntry: Identifiable, Sendable {
    public let id: String
    public let topic: String
    public let problem: String
    public let cause: String
    public let steps: [String]
    public let keywords: String
    public let link: String
}

public enum ProblemGuide {
    static let kernel = "https://dortania.github.io/OpenCore-Install-Guide/troubleshooting/extended/kernel-issues.html"
    static let opencore = "https://dortania.github.io/OpenCore-Install-Guide/troubleshooting/extended/opencore-issues.html"
    static let userspace = "https://dortania.github.io/OpenCore-Install-Guide/troubleshooting/extended/userspace-issues.html"
    static let post = "https://dortania.github.io/OpenCore-Post-Install/"
    static let sleep = "https://dortania.github.io/OpenCore-Post-Install/universal/sleep.html"
    static let audio = "https://dortania.github.io/OpenCore-Post-Install/universal/audio.html"
    static let iservices = "https://dortania.github.io/OpenCore-Post-Install/universal/iservices.html"
    static let drm = "https://dortania.github.io/OpenCore-Post-Install/universal/drm.html"
    static let oc2hdd = "https://dortania.github.io/OpenCore-Post-Install/universal/oc2hdd.html"
    static let usb = "https://dortania.github.io/OpenCore-Post-Install/usb/"
    static let battery = "https://dortania.github.io/OpenCore-Post-Install/laptop-specific/battery.html"
    static let nullMoth = NullMothDoctor.troubleshootingURL

    private static func entry(_ topic: String, _ problem: String, _ cause: String, _ steps: [String], _ keywords: String, _ link: String) -> GuideEntry {
        GuideEntry(id: "\(topic)-\(problem)", topic: topic, problem: problem, cause: cause, steps: steps, keywords: keywords, link: link)
    }

    public static let entries: [GuideEntry] = [
        // Before macOS starts
        entry("Starting up", "The Mac stops on a black screen with text at the very start",
              "OpenCore can't load, or it stopped because of a setting.",
              ["Turn on verbose startup and read the last line on screen.", "Check that the USB or drive has an EFI folder at its top level.", "Scan with this app to check your OpenCore settings."],
              "halted opencore black screen bootx64 oc boot", opencore),
        entry("Starting up", "“OCB: LoadImage failed - Security Violation”",
              "Apple Secure Boot rejected the startup files.",
              ["In your config, try setting SecureBootModel to Disabled.", "Turn off Secure Boot in your BIOS too."],
              "security violation loadimage ocb securebootmodel", opencore),
        entry("Starting up", "No macOS drive in the boot menu",
              "The startup disk driver or scan policy is hiding it.",
              ["Set ScanPolicy to 0.", "Press Space in the boot menu to show hidden entries.", "Check that a HFS+ driver such as OpenHfsPlus.efi is loaded for installers."],
              "picker menu missing entry scanpolicy hfs no drive not showing", opencore),
        entry("Starting up", "Stuck on “EB|#LOG:EXITBS:START”",
              "Usually a memory map or firmware setting problem, close to where macOS takes over from the firmware.",
              ["Check the Booter quirks for your platform in the Dortania guide.", "Turn on Above 4G Decoding in the BIOS.", "Turn off CSM and Secure Boot in the BIOS."],
              "exitbs eb log booter devirtualisemmio stuck", kernel),
        entry("Starting up", "“Couldn't allocate runtime area” or memory errors",
              "The firmware's memory layout blocks the area macOS needs.",
              ["Check that OpenRuntime.efi is loaded.", "Compare your Booter quirks with the Dortania page for your platform."],
              "allocate runtime area slide memory", kernel),

        // While macOS starts
        entry("Starting up", "Restarts just after the text starts scrolling",
              "A kernel panic, often from a wrong setting or a driver that doesn't suit the hardware.",
              ["Add -v, debug=0x100 and keepsyms=1 to your boot arguments, so the error stays on screen.", "Photograph the last lines, and search them in the guide.", "Turn off recently added kexts one at a time."],
              "reboot loop kernel panic restart boot loop", kernel),
        entry("Starting up", "Stuck on “Waiting for Root Device” or a prohibited sign",
              "macOS can't see the drive or USB port it started from.",
              ["Try a USB 2 port, or a different port.", "Set SATA mode to AHCI in the BIOS.", "Turn off Intel VMD if your NVMe drive is hidden.", "Check your USB map."],
              "waiting root device prohibited usb sata ahci vmd stop sign", kernel),
        entry("Starting up", "Stuck on “IOConsoleUsers: gIOScreenLockState 3”",
              "Graphics are failing just before the desktop appears.",
              ["Check your graphics settings for your platform.", "If you use an unsupported graphics card, make sure it's disabled or has a suitable driver."],
              "ioconsoleusers gioscreenlockstate black screen graphics", kernel),
        entry("Starting up", "Stuck at “PCI configuration end” for a long time",
              "On the NullMoth driver, the first start can pause here for up to a minute.",
              ["Wait a full minute on the first start.", "If it never moves on, follow the driver's troubleshooting guide."],
              "pci configuration end nullmoth nvidia hang", nullMoth),
        entry("Starting up", "“AppleUSBXHCI” errors or USB ports not working during install",
              "USB ports aren't mapped, or the 15-port limit is hit.",
              ["Use a USB 2 port for the installer.", "Build a USB map with USBToolBox.", "Don't turn on XhciPortLimit on macOS 11.3 or later, because it causes boot loops."],
              "usb xhci port limit map install", usb),
        entry("Starting up", "“This copy of the Install macOS application is damaged” or a clock error",
              "The date is wrong, or the installer failed its check.",
              ["Open Terminal in the installer, then set the date with the date command.", "Connect to the internet and try again."],
              "damaged installer date clock install failed", userspace),
        entry("Starting up", "The installer can't find any disk to install to",
              "The drive needs erasing, or macOS can't see it.",
              ["In Disk Utility, choose View > Show All Devices.", "Erase only the correct drive as APFS with GUID Partition Map.", "Set SATA to AHCI, and turn off Intel VMD."],
              "disk utility no disk install apfs nvme", userspace),

        // Graphics
        entry("Graphics", "Animations are slow or there's no transparency",
              "Graphics acceleration isn't running.",
              ["Run a scan and check Graphics.", "For Intel and AMD graphics, check WhateverGreen and your device properties.", "For NVIDIA, use the NullMoth driver's 1401 app if your card is supported."],
              "slow laggy no acceleration metal qe ci transparency sluggish", post),
        entry("Graphics", "Black screen after the Apple logo",
              "The wrong framebuffer setting, or macOS started on a card without a driver.",
              ["Try the alternative ig-platform-id for your platform.", "Try another display port or cable.", "Add -wegnoegpu during install if your NVIDIA card has no driver yet. Remove it before installing an NVIDIA driver."],
              "black screen framebuffer ig-platform-id display wegnoegpu", kernel),
        entry("Graphics", "The screen flickers when the cursor moves (NullMoth)",
              "The driver's guide lists this as a known symptom.",
              ["Try the -nvrmnoflip boot argument. This app can add it from the Graphics section."],
              "flicker tearing nvidia nullmoth cursor nvrmnoflip", nullMoth),
        entry("Graphics", "Icons are slow to appear or look wrong (NullMoth)",
              "This is an open driver issue, and the developer hasn't confirmed a fix.",
              ["Keep your driver up to date.", "Don't edit the driver's allow-list file. A mistake can crash the display."],
              "icons slow blurry artifacts nvidia nullmoth liquid glass", NullMothDoctor.iconIssueURL),
        entry("Graphics", "Netflix, Apple TV or other protected video won't play",
              "Protected video (DRM) depends on your graphics setup.",
              ["Check your graphics card against the DRM guide.", "Use the settings it lists for your exact setup."],
              "drm netflix apple tv video protected hardware decode", drm),
        entry("Graphics", "Brightness keys or the slider don't work on a laptop",
              "Laptops need ACPI patches and a keys driver.",
              ["Add BrightnessKeys.kext.", "Check your laptop's backlight patch in the guide."],
              "brightness backlight laptop keys pnlf", post),

        // Sound
        entry("Sound", "No sound at all on macOS Tahoe",
              "Tahoe removed Apple's driver for most hackintosh audio chips, so AppleALC alone no longer works.",
              ["Run a scan and use the Sound fix, which adds SimpleHDA."],
              "no sound audio tahoe simplehda applealc applehda", audio),
        entry("Sound", "Only headphones work, or speakers are missing",
              "The audio layout number doesn't match your laptop's wiring.",
              ["Use Change Audio Layout in the Sound section.", "Try the layouts listed for your codec, restarting after each one."],
              "speakers headphones layout alcid missing microphone", audio),
        entry("Sound", "Sound crackles or cuts out over HDMI",
              "HDMI audio depends on your graphics driver.",
              ["Try the built-in output to check that sound works there.", "Check your graphics driver is up to date."],
              "hdmi crackle displayport audio", audio),

        // Wi-Fi and Bluetooth
        entry("Wireless", "Wi-Fi is missing",
              "macOS has no driver for most PC Wi-Fi cards.",
              ["Run a scan and check Wi-Fi. It identifies your card.", "If the card is hidden, turn off any SSDT that disables it.", "Use Ethernet, or a USB adapter, until it's sorted."],
              "wifi wi-fi missing no card realtek intel broadcom mediatek", post),
        entry("Wireless", "Wi-Fi connects but is very slow",
              "Community drivers are often still in preview. Your router may be fine.",
              ["Compare speed with another device on the same network.", "Use Ethernet if you can.", "Report it to the driver's project with its log tool."],
              "wifi slow speed realtek rtw89", post),
        entry("Wireless", "AirPlay to this Mac is very slow",
              "With both Wi-Fi and Ethernet on, other devices can connect through the slower one.",
              ["Turn off Wi-Fi on the Mac, then start AirPlay again."],
              "airplay slow mirroring lag receiver", post),
        entry("Wireless", "Bluetooth is off or says it isn't available",
              "The chip needs a firmware driver, and USB maps can hide it.",
              ["Run a scan and check Bluetooth.", "Mark the Bluetooth USB port as internal in your USB map. Realtek chips can need it marked as external.", "Add BlueToolFixup.kext on macOS 12 or later."],
              "bluetooth off not available bluetoolfixup firmware", post),
        entry("Wireless", "AirDrop doesn't find anyone",
              "AirDrop needs a Wi-Fi link that community Intel and Realtek drivers don't provide.",
              ["There's no known software fix on those cards.", "Broadcom cards with OpenCore Legacy Patcher are the known route on recent macOS.", "LocalSend is a free alternative that works over your network."],
              "airdrop awdl continuity share", post),
        entry("Wireless", "Handoff or Universal Clipboard doesn't work",
              "They need Bluetooth LE and working Wi-Fi, and a real Apple-style card usually works best.",
              ["Sign in with the same Apple Account on both devices.", "Turn on Handoff on both devices, with Wi-Fi and Bluetooth on.", "Check your SMBIOS is set up so Apple services work."],
              "handoff universal clipboard continuity copy paste iphone", iservices),

        // Apple services
        entry("Apple services", "iMessage, FaceTime or the App Store won't sign in",
              "These services need unique, valid system identifiers.",
              ["Follow the guide to set up your SMBIOS correctly.", "Check that your network shows as en0 and built in.", "Don't use numbers belonging to a real Mac. This app doesn't generate them."],
              "imessage facetime app store icloud sign in serial smbios en0 mlb rom", iservices),

        // Sleep and power
        entry("Sleep and power", "The Mac won't wake from sleep",
              "Sleep is one of the hardest parts of a hackintosh.",
              ["Turn off hibernation. This app has a fix for it.", "Check that your graphics card and USB map support sleep.", "Follow the sleep guide step by step."],
              "sleep wake hibernate crash restart", sleep),
        entry("Sleep and power", "The Mac wakes by itself every minute",
              "USB or firmware wake signals are the usual cause.",
              ["Check the wake reason with: pmset -g log | grep -i wake", "Follow the sleep guide's fix for USB wake."],
              "wakes up instantly wake every minute xhci gprw darkwake", sleep),
        entry("Sleep and power", "Graphics don't come back after sleep (NullMoth)",
              "Sleep support depends on your card, and -nvrmnopm turns it off.",
              ["Remove -nvrmnopm if it's set. This app can do it.", "Send logs from the 1401 app if it keeps happening."],
              "nvidia sleep wake black nvrmnopm nullmoth", nullMoth),
        entry("Sleep and power", "Battery percentage is missing",
              "Laptops need SMCBatteryManager and battery patches.",
              ["Use Install Battery Driver in this app.", "Add your laptop's battery patches from the guide."],
              "battery percentage laptop smcbatterymanager", battery),
        entry("Sleep and power", "The fans run loud or the Mac runs hot",
              "Processor power management may not be working.",
              ["Check SSDT-PLUG is loaded.", "Use an SMBIOS that matches your processor."],
              "fans hot temperature power management plug cpu", post),

        // USB and storage
        entry("USB and storage", "USB 3 ports only run at USB 2 speed",
              "Ports aren't mapped, or the path has a USB 2 cable or adapter.",
              ["Run a scan and check USB.", "Try a direct cable and another port.", "Build a USB map with USBToolBox."],
              "usb 3 slow 480 speed map port", usb),
        entry("USB and storage", "macOS is slow when it runs from an external drive",
              "A USB 2 link limits your whole system.",
              ["Check link speed in System Information > USB.", "Use USB 3 with a good cable, or install to an internal SSD."],
              "external ssd slow usb boot sluggish", usb),
        entry("USB and storage", "An NVMe drive doesn't appear",
              "Intel VMD can hide NVMe drives, and some drives don't work well with macOS.",
              ["Turn off VMD in the BIOS.", "Add NVMeFix.kext.", "Check your drive isn't a model known to have problems."],
              "nvme missing vmd rst drive", userspace),
        entry("USB and storage", "The Mac only starts from the USB, not its own drive",
              "OpenCore is only on the USB so far.",
              ["Copy your working EFI folder to the macOS drive's EFI partition.", "Set it as first in your BIOS boot order."],
              "efi copy usb drive boot oc2hdd move opencore", oc2hdd),

        // Input and display
        entry("Input and display", "Trackpad or keyboard doesn't work on a laptop",
              "Laptops need input drivers.",
              ["For PS/2 devices, use Install VoodooPS2 in this app.", "I2C trackpads need VoodooI2C and may need ACPI patches."],
              "trackpad keyboard laptop voodoops2 voodooi2c input", post),
        entry("Input and display", "The clock is wrong after using Windows",
              "Windows and macOS read the hardware clock differently.",
              ["Turn on automatic time. This app has a fix for it.", "In Windows, you can set the clock to use UTC."],
              "clock time wrong dual boot windows timezone", post),
        entry("Input and display", "Your time zone isn't listed",
              "Some names, such as Asia/Kolkata, are rejected by macOS's setup tool.",
              ["Use Change Time Zone in this app. It handles those names."],
              "timezone time zone india kolkata calcutta", post),

        // Updates
        entry("Updates", "Something stopped working after a macOS update",
              "Updates can break patches and drivers, especially ones made for an exact build.",
              ["Check that your kexts are the newest versions before updating.", "Restore a backup from this app if a boot change caused it.", "Patched Bluetooth kexts have to be rebuilt for each build."],
              "update broke stopped working after update kext ota", post),
        entry("Updates", "The Mac won't start after a change",
              "A setting or driver is stopping startup.",
              ["Start from your bootable USB with a working OpenCore.", "Put back your backup config.plist.", "Reset NVRAM from the boot menu if your setup includes that option."],
              "won't boot broken restore backup recovery nvram", opencore),
    ]

    /// Finds entries matching every word typed. An empty search returns everything.
    public static func search(_ text: String) -> [GuideEntry] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = "\(entry.topic) \(entry.problem) \(entry.cause) \(entry.keywords)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    public static var topics: [String] {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.topic) { seen.append(entry.topic) }
        return seen
    }
}
