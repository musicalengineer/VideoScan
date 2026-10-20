// CatalogTableFonts.swift
// The Catalog table's cell fonts, in ONE place (Rick 2026-10-20: "folder
// rows and file rows in the same table must look alike"). A file row's
// cell and a folder row's summary in the SAME column read the same font,
// so a folder row is never smaller than the files around it; the folder's
// name stays semibold (FootageFolderWords.folderTitleFont) as the row's
// one distinguishing mark.
//
// (For Rick: a namespace of constants — a C++ `namespace` of `const`
// values. `Font.body` is the system's 13 pt table text on macOS.)

import SwiftUI

enum CatalogTableFonts {
    /// Most columns: Duration, Resolution, Codec, Size, Stream, and a
    /// folder row's counts, running time and size.
    static let standard = Font.body
    /// The Volume column's label (monospaced so volume prefixes line up).
    static let volume = Font.system(.body, design: .monospaced)
    /// The Date, Place and Tag words — a file row's and a folder row's alike.
    static let compact = Font.system(size: 11)
}
