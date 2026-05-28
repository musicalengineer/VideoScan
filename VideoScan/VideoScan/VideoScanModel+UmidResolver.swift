import Foundation

extension VideoScanModel {

    // MARK: - MXF UMID Substitute Resolver
    //
    // Avid MXF files embed a SMPTE MaterialPackage UMID in their header —
    // a 32-byte identifier that's the same across byte-for-byte copies of
    // the media, regardless of filename, parent directory, or volume.
    // ffprobe surfaces it as `format_tags["material_package_umid"]`, which
    // ScanEngine.extractMetadata captures into `VideoRecord.materialPackageUMID`.
    //
    // This lets us answer: "the file at /Volumes/MacPro/X.mxf is needed
    // but MacPro is offline — is there a copy of the same media on a
    // currently-reachable volume?" Without this, Combine and similar
    // workflows are blocked any time a source volume is unavailable.

    /// Catalog records that share `record`'s MaterialPackage UMID but live
    /// at a different fullPath. Pure lookup — caller is responsible for
    /// filtering by reachability, so a UI picker can include offline
    /// candidates ("found 3 copies: 2 reachable, 1 on MacPro [offline]").
    ///
    /// Returns empty when:
    ///   - the source has no UMID (non-MXF, or scanned before the field
    ///     was added — re-scan picks it up);
    ///   - no other catalog records share the UMID;
    ///   - the only matches are at the same fullPath (self).
    func findSubstitutes(for record: VideoRecord) -> [VideoRecord] {
        let umid = record.materialPackageUMID
        guard !umid.isEmpty else { return [] }
        return records.filter {
            $0.materialPackageUMID == umid && $0.fullPath != record.fullPath
        }
    }
}
