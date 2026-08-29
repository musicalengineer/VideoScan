import Foundation

extension VideoScanModel {
    /// Publish one coherent, read-only value snapshot for Hallie's detached
    /// workers and the Family Tree tab.  A designated archive is usable only
    /// when its root is online and its recorded volume identity still matches.
    ///
    /// Remote viewer (docs/remote_use_design.md Phase 1): the synced
    /// catalog carries the MASTER's archive designation, and that RAID is
    /// not mounted on the porch Mac. Publishing it would make the tree
    /// `.unavailable` ("designated but offline") and hide everything. A
    /// viewer therefore publishes NO archive root: its assets root falls
    /// back to Application Support/family-tree/assets, which is exactly
    /// where the sync stages the master's People/ enrichments, and its
    /// GEDCOM directory to family-tree/originals, also synced. Read-only
    /// either way.
    func publishFamilyAssetConfiguration() {
        let isViewer = ViewerModeCenter.shared.isViewer
        let root = isViewer ? nil : masterArchiveRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let safelyAvailable = root == nil
            || (isMasterArchiveOnline && masterArchiveIdentityRefusal() == nil)
        FamilyAssetConfigurationCenter.shared.publish(
            masterArchiveRoot: root,
            masterIsSafelyAvailable: safelyAvailable,
            readOnly: isReadOnly || isViewer)
    }
}
