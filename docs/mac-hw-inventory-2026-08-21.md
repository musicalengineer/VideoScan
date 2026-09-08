# Mac hardware & port inventory

- **Host:** RicksM4
- **Model:** Mac16,9
- **Chip:** Apple M4 Max
- **Memory:** 64 GiB
- **macOS:** 26.6.2 (25G83)
- **Captured:** 2026-08-21 18:42:51 EDT

## Thunderbolt / USB4 bus map

One bus per physical port. macOS does not report chassis position —
identify each bus by unplugging once, then this mapping stays stable.

| Bus | Attached |
|---|---|
| Thunderbolt/USB4 Bus 3 | Port -> PRO-G40 |
| Thunderbolt/USB4 Bus 2 | Port |
| Thunderbolt/USB4 Bus 1 | Port -> TS5 Plus -> Port -> Port -> Port |
| Thunderbolt/USB4 Bus 0 | Port -> Pegasus32-R -> Port |

## Network hardware ports

```

Hardware Port: Ethernet
Device: en0
Ethernet Address: 1c:1d:d3:d9:ab:44

Hardware Port: Thunderbolt Ethernet Slot 1
Device: en10
Ethernet Address: 64:4b:f0:60:6b:96

Hardware Port: Ethernet Adapter (en6)
Device: en6
Ethernet Address: 42:2d:92:f0:e5:c6

Hardware Port: Ethernet Adapter (en7)
Device: en7
Ethernet Address: 42:2d:92:f0:e5:c7

Hardware Port: Ethernet Adapter (en8)
Device: en8
Ethernet Address: 42:2d:92:f0:e5:c8

Hardware Port: Ethernet Adapter (en9)
Device: en9
Ethernet Address: 42:2d:92:f0:e5:c9

Hardware Port: Thunderbolt Bridge
Device: bridge0
Ethernet Address: 36:d9:a8:3e:97:00

Hardware Port: Wi-Fi
Device: en1
Ethernet Address: 1c:1d:d3:d8:31:99

Hardware Port: Thunderbolt 1
Device: en2
Ethernet Address: 36:d9:a8:3e:97:00

Hardware Port: Thunderbolt 2
Device: en3
Ethernet Address: 36:d9:a8:3e:97:04

Hardware Port: Thunderbolt 3
Device: en4
Ethernet Address: 36:d9:a8:3e:97:08

Hardware Port: Thunderbolt 4
Device: en5
Ethernet Address: 36:d9:a8:3e:97:0c

VLAN Configurations
===================
```

## Displays

```
    Apple M4 Max:
      Chipset Model: Apple M4 Max
      Type: GPU
      Bus: Built-In
      Total Number of Cores: 40
      Vendor: Apple (0x106b)
      Metal Support: Metal 4
      Displays:
        BenQ MA320U:
          Resolution: 5120 x 2880 (5K/UHD+ - Ultra High Definition Plus)
          UI Looks like: 2560 x 1440 @ 60.00Hz
          Main Display: Yes
          Mirror: Off
          Online: Yes
          Rotation: Supported
        S27C450:
          Resolution: 1920 x 1080 (1080p FHD - Full High Definition)
          UI Looks like: 1920 x 1080 @ 60.00Hz
          Mirror: Off
          Online: Yes
          Rotation: Supported
```

## Thunderbolt / USB4

```
    Thunderbolt/USB4 Bus 3:
      Vendor Name: Apple Inc.
      Device Name: Mac Studio
      UID: 0x05ACCCB2D90FA5C3
      Route String: 0
      Domain UUID: EC998BD2-ED77-4448-AE1D-4FC08908E56E
      Port:
          Status: Device connected
          Link Status: 0x2
          Speed: 40 Gb/s
          Receptacle: 4
          Micro Firmware Version: 0.0.0
        PRO-G40:
          Vendor Name: SanDisk Professional
          Device Name: PRO-G40
          Mode: Thunderbolt 3
          Device ID: 0x5
          Vendor ID: 0x036A
          Device Revision: 0x1
          UID: 0x036AE0C7FC422E00
          Route String: 1
          Firmware Version: 68.3
          Port (Upstream):
              Status: Device connected
              Link Status: 0x2
              Speed: 40 Gb/s
              Link Controller Firmware Version: 1.45.0
    Thunderbolt/USB4 Bus 2:
      Vendor Name: Apple Inc.
      Device Name: Mac Studio
      UID: 0x05ACCCB2D90FA5C2
      Route String: 0
      Domain UUID: 3294CC34-FF1C-47DA-A6DD-3772D19A70E0
      Port:
          Status: No device connected
          Link Status: 0x100
          Speed: Up to 120 Gb/s
          Receptacle: 3
    Thunderbolt/USB4 Bus 1:
      Vendor Name: Apple Inc.
      Device Name: Mac Studio
      UID: 0x05ACCCB2D90FA5C1
      Route String: 0
      Domain UUID: F0E70B19-FEF6-4E80-9754-ED5FE0E04690
      Port:
          Status: Device connected
          Link Status: 0x2
          Speed: 80 Gb/s
          Receptacle: 2
          Micro Firmware Version: 0.0.0
        TS5 Plus:
          Vendor Name: CalDigit, Inc.
          Device Name: TS5 Plus
          Mode: USB4 v2
          Device ID: 0x29
          Vendor ID: 0x2188
          Device Revision: 0x2
          UID: 0x80875C4361FDE900
          Route String: 1
          Firmware Version: 64.1
          Port (Upstream):
              Status: Device connected
              Link Status: 0x2
              Speed: 80 Gb/s
              Micro Firmware Version: 1.11.0
          Port:
              Status: No device connected
              Link Status: 0x7
              Speed: Up to 120 Gb/s
              Micro Firmware Version: 1.11.0
          Port:
              Status: No device connected
              Link Status: 0x7
              Speed: Up to 120 Gb/s
              Micro Firmware Version: 1.11.0
          Port:
              Status: No device connected
              Link Status: 0x7
              Speed: Up to 120 Gb/s
              Micro Firmware Version: 1.11.0
    Thunderbolt/USB4 Bus 0:
      Vendor Name: Apple Inc.
      Device Name: Mac Studio
      UID: 0x05ACCCB2D90FA5C0
      Route String: 0
      Domain UUID: 7B9C9580-A9FA-4D31-A0DF-55755583F685
      Port:
          Status: Device connected
          Link Status: 0x2
          Speed: 40 Gb/s
          Receptacle: 1
          Micro Firmware Version: 0.0.0
        Pegasus32-R:
          Vendor Name: Promise Technology, Inc.
          Device Name: Pegasus32-R
          Mode: Thunderbolt 3
          Device ID: 0x37
          Vendor ID: 0x0002
          Device Revision: 0x1
          UID: 0x0002DF85F9383300
          Route String: 1
          Firmware Version: 50.3
          Port (Upstream):
              Status: Device connected
              Link Status: 0x2
              Speed: 40 Gb/s
              Link Controller Firmware Version: 1.37.0
          Port:
              Status: No device connected
              Link Status: 0x7
              Speed: Up to 40 Gb/s
              Link Controller Firmware Version: 1.37.0
```

## Audio

```
    Devices:
        BenQ MA320U:
          Manufacturer: BNQ
          Output Channels: 2
          Current SampleRate: 48000
          Transport: HDMI
          Output Source: Default
        Mac Studio Speakers:
          Default System Output Device: Yes
          Manufacturer: Apple Inc.
          Output Channels: 2
          Current SampleRate: 48000
          Transport: Built-in
          Output Source: Mac Studio Speakers
        Babyface Pro (73004863):
          Default Input Device: Yes
          Default Output Device: Yes
          Input Channels: 14
          Manufacturer: RME-Audio
          Output Channels: 14
          Current SampleRate: 44100
          Transport: USB
          Input Source: Default
          Output Source: Default
```

## Storage volumes

```
    Data:
      Free: 150 GB (149,997,334,528 bytes)
      Capacity: 994.66 GB (994,662,584,320 bytes)
      Mount Point: /System/Volumes/Data
      File System: APFS
      Writable: Yes
      Ignore Ownership: No
      BSD Name: disk3s5
      Volume UUID: A7A2B888-442A-42FC-B548-4FE8FE93F6C8
      Physical Drive:
          Device Name: APPLE SSD AP1024Z
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: Apple Fabric
          Internal: Yes
          Partition Map Type: Unknown
          S.M.A.R.T. Status: Verified
    CrucialX10:
      Free: 1.75 TB (1,754,308,177,920 bytes)
      Capacity: 2 TB (2,000,189,177,856 bytes)
      Mount Point: /Volumes/CrucialX10
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk8s1
      Volume UUID: 2E5BD3AE-B85A-47B4-BC1B-A0E1D32A57BB
      Physical Drive:
          Device Name: CT2000X10SSD9
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: USB
          Internal: No
          Partition Map Type: Unknown
    CrucialX9:
      Free: 1.67 TB (1,670,280,548,352 bytes)
      Capacity: 2 TB (2,000,189,177,856 bytes)
      Mount Point: /Volumes/CrucialX9
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk9s1
      Volume UUID: 194A9792-3CE5-43FF-B5FB-B7102637E4A9
      Physical Drive:
          Device Name: CT2000X9SSD9
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: USB
          Internal: No
          Partition Map Type: Unknown
    LaCieWorkspace:
      Free: 3.18 TB (3,181,383,958,528 bytes)
      Capacity: 8 TB (8,001,353,465,856 bytes)
      Mount Point: /Volumes/LaCieWorkspace
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk5s1
      Volume UUID: 84661FE3-C826-4B3B-A550-59BF9FEE77BD
      Physical Drive:
          Device Name: d2 Professional
          Media Name: AppleAPFSMedia
          Medium Type: Rotational
          Protocol: USB
          Internal: No
          Partition Map Type: Unknown
          S.M.A.R.T. Status: Verified
    MediaExpansion:
      Free: 554 GB (554,001,805,312 bytes)
      Capacity: 2 TB (2,000,000,000,000 bytes)
      Mount Point: /Volumes/MediaExpansion
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk5s2
      Volume UUID: 45AC3C84-BEAF-413F-9BDA-B767B979489F
      Physical Drive:
          Device Name: d2 Professional
          Media Name: AppleAPFSMedia
          Medium Type: Rotational
          Protocol: USB
          Internal: No
          Partition Map Type: Unknown
          S.M.A.R.T. Status: Verified
    FamilyArchive:
      Free: 8.75 TB (8,750,339,518,464 bytes)
      Capacity: 9 TB (8,999,779,971,072 bytes)
      Mount Point: /Volumes/FamilyArchive
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk11s1
      Volume UUID: 91D10242-E43B-4A49-988E-637A3D83BFF2
      Physical Drive:
          Device Name: Pegasus32 R4
          Media Name: AppleAPFSMedia
          Protocol: SAS
          Internal: No
          Partition Map Type: Unknown
    Projects:
      Free: 3.92 TB (3,917,907,144,704 bytes)
      Capacity: 6 TB (5,999,779,971,072 bytes)
      Mount Point: /Volumes/Projects
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk11s2
      Volume UUID: 0978904A-3D3C-4546-BC51-5A53F32BCB23
      Physical Drive:
          Device Name: Pegasus32 R4
          Media Name: AppleAPFSMedia
          Protocol: SAS
          Internal: No
          Partition Map Type: Unknown
    SanDiskWorkspace:
      Free: 2.02 TB (2,017,354,235,904 bytes)
      Capacity: 4 TB (4,000,577,273,856 bytes)
      Mount Point: /Volumes/SanDiskWorkspace
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk13s1
      Volume UUID: 8BA3554E-C57E-4392-B46F-12B07BD65A5D
      Physical Drive:
          Device Name: WD_BLACK SN850XE 4000GB
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: PCI-Express
          Internal: No
          Partition Map Type: Unknown
          S.M.A.R.T. Status: Verified
    XcodeRAM:
      Free: 13.48 GB (13,482,496,000 bytes)
      Capacity: 17.18 GB (17,179,869,184 bytes)
      Mount Point: /Volumes/XcodeRAM
      File System: APFS
      Writable: Yes
      Ignore Ownership: Yes
      BSD Name: disk15s1
      Volume UUID: C6F9B9A6-1287-4342-A0B4-9103043904F7
      Physical Drive:
          Device Name: Disk Image
          Media Name: AppleAPFSMedia
          Protocol: Disk Image
          Internal: No
          Partition Map Type: Unknown
    iOS 18.4 Simulator Bundle:
      Free: 263.2 MB (263,184,384 bytes)
      Capacity: 9.12 GB (9,116,319,744 bytes)
      Mount Point: /Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-B9E0CBB6-DD2A-4A06-AE0C-3F2614719BBB
      File System: APFS
      Writable: No
      Ignore Ownership: No
      BSD Name: disk17s1
      Volume UUID: 1E636626-73D7-484B-835A-A24FBF7D2C5C
      Physical Drive:
          Device Name: Disk Image
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: Disk Image
          Internal: No
          Partition Map Type: Unknown
    iOS 18.4 Simulator:
      Free: 518.6 MB (518,606,848 bytes)
      Capacity: 20.7 GB (20,698,890,240 bytes)
      Mount Point: /Library/Developer/CoreSimulator/Volumes/iOS_22E238
      File System: APFS
      Writable: No
      Ignore Ownership: No
      BSD Name: disk19s1
      Volume UUID: DD50EC5C-3A04-49B5-88ED-F50BB6C03943
      Physical Drive:
          Device Name: Disk Image
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: Disk Image
          Internal: No
          Partition Map Type: Unknown
    iOS 18.5 Simulator Bundle:
      Free: 262.9 MB (262,914,048 bytes)
      Capacity: 9.13 GB (9,128,902,656 bytes)
      Mount Point: /Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-A2395257-6FD1-4BCB-9003-C2C0744249E9
      File System: APFS
      Writable: No
      Ignore Ownership: No
      BSD Name: disk21s1
      Volume UUID: 37AF619B-BB0F-4D5E-AD7C-29E34BAB7389
      Physical Drive:
          Device Name: Disk Image
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: Disk Image
          Internal: No
          Partition Map Type: Unknown
    MetalToolchainCryptex:
      Free: 75.8 MB (75,771,904 bytes)
      Capacity: 2.31 GB (2,306,867,200 bytes)
      Mount Point: /private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.6.109.0.qZZSBh
      File System: APFS
      Writable: No
      Ignore Ownership: No
      BSD Name: disk23s1
      Volume UUID: 8FBF648C-5893-4C7A-B2D0-56DD267979E8
      Physical Drive:
          Device Name: Disk Image
          Media Name: AppleAPFSMedia
          Protocol: Disk Image
          Internal: No
          Partition Map Type: Unknown
    iOS 18.5 Simulator:
      Free: 518.8 MB (518,807,552 bytes)
      Capacity: 20.75 GB (20,747,124,736 bytes)
      Mount Point: /Library/Developer/CoreSimulator/Volumes/iOS_22F77
      File System: APFS
      Writable: No
      Ignore Ownership: No
      BSD Name: disk25s1
      Volume UUID: 70AF9BCF-D1A8-49E0-AE3F-BCF95EC96DA0
      Physical Drive:
          Device Name: Disk Image
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: Disk Image
          Internal: No
          Partition Map Type: Unknown
    M4drive:
      Free: 150 GB (149,997,797,376 bytes)
      Capacity: 994.66 GB (994,662,584,320 bytes)
      Mount Point: /
      File System: APFS
      Writable: No
      Ignore Ownership: No
      BSD Name: disk3s1s1
      Volume UUID: BAC62FCD-581B-4C81-8354-6A4A57AD315B
      Physical Drive:
          Device Name: APPLE SSD AP1024Z
          Media Name: AppleAPFSMedia
          Medium Type: SSD
          Protocol: Apple Fabric
          Internal: Yes
          Partition Map Type: Unknown
          S.M.A.R.T. Status: Verified
```

## NVMe / internal

```
    Apple SSD Controller:
        APPLE SSD AP1024Z:
          Capacity: 1 TB (1,000,555,581,440 bytes)
          TRIM Support: Yes
          Model: APPLE SSD AP1024Z
          Revision: 2,973.120
          Detachable Drive: No
          BSD Name: disk0
          Partition Map Type: GPT (GUID Partition Table)
          Removable Media: No
          S.M.A.R.T. status: Verified
    Generic SSD Controller:
        WD_BLACK SN850XE 4000GB:
          Capacity: 4 TB (4,000,787,030,016 bytes)
          TRIM Support: Yes
          Model: WD_BLACK SN850XE 4000GB
          Revision: 624131EX
          Link Width: x4
          Link Speed: 8.0 GT/s
          Detachable Drive: No
          BSD Name: disk12
          Partition Map Type: GPT (GUID Partition Table)
          Removable Media: No
          S.M.A.R.T. status: Verified
```

## Bluetooth

```
      Bluetooth Controller:
          State: On
          Chipset: BCM_4388C2
          Discoverable: Off
          Firmware Version: 23.5.224.1462
          Product ID: 0x4A36
          Supported services: 0x392039 < HFP AVRCP A2DP HID Braille LEA AACP GATT SerialPort >
          Transport: PCIe
          Vendor ID: 0x004C (Apple)
      Not Connected:
          Breen Living Room:
              RSSI: -64
          Ricks Airpods:
              Case Battery Level: 47%
              Left Battery Level: 100%
              Right Battery Level: 100%
              Case Version: 8B41
              Firmware Version: 8B41
              Minor Type: Headphones
              Serial Number: HHG6773M7Q
              Serial Number (Left): GX4KK8N418JQ
              Serial Number (Right): GN1KJ71U18JP
          RicksIntel:
          RicksM1:
          RicksM1:
          RicksM5:
          RickyPad:
              RSSI: -67
          Rick’s iPhone:
              RSSI: -45
```

## Power

```
    System Power Settings:
      AC Power:
          System Sleep Timer (Minutes): 0
          Disk Sleep Timer (Minutes): 0
          Display Sleep Timer (Minutes): 60
          Sleep on Power Button: Yes
          Automatic Restart on Power Loss: No
          Wake on LAN: Yes
          Automatic Restart On Power Connect: 0
          Current Power Source: Yes
          Low Power Mode: No
          Prioritize Network Reachability Over Sleep: No
      UPS Power:
          System Sleep Timer (Minutes): 1
          Disk Sleep Timer (Minutes): 10
          Display Sleep Timer (Minutes): 2
          Sleep on Power Button: Yes
          Automatic Restart on Power Loss: No
          Wake on LAN: No
          Automatic Restart On Power Connect: 0
          Low Power Mode: No
          Prioritize Network Reachability Over Sleep: No
    Hardware Configuration:
      UPS Installed: Yes
    AC Charger Information:
      Family: 0x0000
```

---

Generated by `mac-hw-inventory.sh`
