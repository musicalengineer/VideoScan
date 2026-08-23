import Foundation

extension VideoScanModel {
    /// Publish one coherent, read-only value snapshot for Hallie's detached
    /// workers and the Family Tree tab.  A designated archive is usable only
    /// when its root is online and its recorded volume identity still matches.
    func publishFamilyAssetConfiguration() {
        let root = masterArchiveRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let safelyAvailable = root == nil
            || (isMasterArchiveOnline && masterArchiveIdentityRefusal() == nil)
        FamilyAssetConfigurationCenter.shared.publish(
            masterArchiveRoot: root,
            masterIsSafelyAvailable: safelyAvailable,
            readOnly: isReadOnly)
    }
}
