// PreviewPanePlaceholders.swift
// The catalog preview pane's placeholder family (MEDIA OFFLINE, extracting,
// NO PREVIEW, AUDIO ONLY), drawn by CatalogContent.previewCentre for the
// surface PreviewPaneSurface.decide picks. Views only — no decisions here.

import SwiftUI

/// The preview pane's placeholder box: black, rounded, at most 480×180,
/// 16:9 — one family for MEDIA OFFLINE, extracting, NO PREVIEW, AUDIO ONLY.
struct PreviewPanePlaceholder<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black)
            content
        }
        .frame(maxWidth: 480, maxHeight: 180)
        .aspectRatio(16.0/9.0, contentMode: .fit)
    }
}

/// A placeholder with a symbol over a monospaced title (NO PREVIEW, AUDIO ONLY).
struct PreviewPaneBadge: View {
    let systemImage: String
    let title: String
    let imageColor: Color
    let titleColor: Color

    var body: some View {
        PreviewPanePlaceholder {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 36))
                    .foregroundColor(imageColor)
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(titleColor)
            }
        }
    }
}
