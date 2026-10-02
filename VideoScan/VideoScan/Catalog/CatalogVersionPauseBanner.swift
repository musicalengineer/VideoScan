// CatalogVersionPauseBanner.swift
// GH #167 (Rick 2026-10-02): when catalog.json was last saved by a NEWER
// VideoScan, this build opens it read-only and says so in plain words —
// it never refuses to launch, never writes, never downgrades. The words
// live in `CatalogStore.newerCatalogNotice` so the banner, the console
// line and the tests agree; this view only draws them.
//
// Same visual language as CatalogSyncBanner's can't-miss amber state.

import SwiftUI

struct CatalogVersionPauseBanner: View {
    let notice: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(notice)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.85, green: 0.45, blue: 0.10))   // amber — can't-miss
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("catalog.versionPauseBanner")
    }
}
