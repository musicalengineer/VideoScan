# Issue #5: Auto-Wake Offline Network Volumes

## Problem

When a scan target shows as offline (yellow indicator), the host machine may just be asleep. Currently the user must manually wake the host or mount the share. The app should try to wake/mount automatically with visual feedback.

## Current Architecture

- `VolumeReachability.isReachable(path:)` does a synchronous `FileManager.fileExists` + `checkResourceIsReachable` check
- `VideoScanModel.installVolumeMountObservers()` listens for `NSWorkspace.didMountNotification` / `didUnmountNotification`
- `refreshTargetReachability()` re-checks all targets on mount/unmount events
- `CatalogScanTarget.isReachable` is the published bool that drives the yellow indicator

## Proposed Solution

### 1. Wake-on-LAN (WOL) for sleeping hosts

If the volume host is a Mac on the local network that went to sleep, send a WOL magic packet to wake it.

**Implementation:**
- Store the MAC address for each network volume host (auto-discover via `arp -a` when the volume is first seen online, persist in UserDefaults)
- When user clicks a "wake" button on an offline volume, send a UDP magic packet (6x `0xFF` + 16x MAC) to port 9 on the broadcast address
- Use `Network.framework` (`NWConnection` with UDP) — no external dependencies

```swift
import Network

func sendWOL(macAddress: [UInt8]) {
    let magic = [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in macAddress }
    let connection = NWConnection(
        host: .ipv4(.broadcast), port: 9, using: .udp
    )
    connection.start(queue: .global())
    connection.send(content: Data(magic), completion: .contentProcessed { _ in
        connection.cancel()
    })
}
```

### 2. SMB auto-mount for unmounted shares

If the host is awake but the share isn't mounted, attempt to mount it.

**Implementation:**
- Parse the volume path to extract the SMB share info (e.g., `/Volumes/MediaArchive` → `smb://hostname/MediaArchive`)
- Store the mapping: volume mount point → SMB URL (discover from `mount` command output when online)
- Use `NetFS.framework` / `NetFSMountURLSync` or shell out to `mount_smbfs` to re-mount
- Alternative: `open "smb://host/share"` via NSWorkspace (simpler but shows Finder dialog)

```swift
// Preferred: NetFS (no Finder UI)
import NetFS

func mountSMBShare(url: URL, mountPoint: String) {
    var mountPoints: Unmanaged<CFArray>?
    let status = NetFSMountURLSync(
        url as CFURL, nil, nil, nil, nil, nil, &mountPoints
    )
    // status == 0 on success
}
```

### 3. Visual feedback flow

```
[Offline - Yellow] → user clicks "Wake" or auto-retry
    → [Waking... - Animated spinner, pulsing orange]
    → send WOL packet, wait 15-30 seconds
    → attempt SMB mount
    → [Online - Green] or [Still Offline - Yellow, "Host unreachable"]
```

**UI changes in ContentView (scan targets pane):**
- Add a "wake" button (moon.zzz icon) next to offline targets
- Replace yellow circle with pulsing orange ProgressView during wake attempt
- Show tooltip with status: "Sending wake packet...", "Waiting for host...", "Attempting mount..."
- Auto-timeout after 45 seconds, revert to yellow

### 4. Auto-retry on launch

On app launch, if any targets are offline, automatically attempt wake/mount in the background (no UI blocking). This handles the common case where the user opens VideoScan and their NAS hasn't been accessed recently.

### 5. Data to persist

- `volumeHosts: [String: (hostname: String, macAddress: [UInt8], smbURL: URL)]` — keyed by mount point path
- Auto-populated when a volume is first seen online (parse `mount` output + `arp` table)
- Stored in UserDefaults alongside scan target paths

## Complexity Assessment

**Medium.** The core WOL packet is trivial. SMB mounting via NetFS is straightforward. The main work is:
- Reliable MAC address discovery
- Handling various network configurations (VPN, multiple interfaces)
- Graceful timeout and retry logic
- Persisting host info across launches

## Dependencies

- `Network.framework` (built-in, macOS 10.14+)
- `NetFS.framework` (built-in, macOS 10.6+) — for programmatic SMB mount
- No external dependencies
