// PersonOfTheDayCard.swift
// The Person of the Day card in the Family Tree sidebar (Rick 2026-10-01):
// portrait (or the birth-country flag, or the plain placeholder), name,
// years, relation, birthplace and ONE "why today" line ("Born 212 years ago
// today in Cork, Ireland"). Click → the tree focuses that person.
//
// THE BODY COMPUTES NOTHING: the pick arrives from PersonOfTheDayCenter (a
// value), the flag is one dictionary lookup on the tree model, and the
// photo is decoded off-main by `.task` (the same resolver and thumbnail
// path as the tree's own cards — FamilyAssetPortrait). The `.task(id:)` on
// the card asks the center to refresh whenever an input's KEY changes —
// a few short strings, never an O(people) value.
//
// PRIVACY: a living inner-circle person is shown only on their birthday,
// and Core has already removed their years and birthplace; the card simply
// draws what it is handed.
//
// (For Rick: `.task(id:)` ≈ "run this async job when the view appears and
// again whenever `id` changes, cancelling the previous run" — like
// restarting a worker when a parameter changes.)

import AppKit
import SwiftUI
import VideoScanCore

struct PersonOfTheDayCard: View {
    @ObservedObject var model: FamilyTreeLiveModel
    @ObservedObject var center: PersonOfTheDayCenter = .shared
    @ObservedObject var walkCenter: FamilyTreeWalkCenter = .shared

    /// The refresh trigger: a cheap string of the inputs (see
    /// PersonOfTheDayCenter.inputsKey).
    private var inputsKey: String {
        PersonOfTheDayCenter.inputsKey(graph: model.walkGraph, decorationsKey: walkCenter.stored?.sourceKey,
                                       hasNotes: model.walkFamilyKnowledge != nil,
                                       day: center.dayKey)   // moves at midnight (QA P3-4)
    }

    var body: some View {
        Group {
            if let pick = center.pick, model.isLive {
                card(pick)
            }
        }
        .task(id: inputsKey) {
            center.refresh(graph: model.walkGraph, decorations: walkCenter.stored,
                           knowledge: model.walkFamilyKnowledge, displayNames: walkCenter.displayNames,
                           ownerFamilySearchID: HallieTurnExecutor.Speakers.fromDefaults().ownerFamilySearchID)
        }
    }

    private func card(_ pick: PersonOfTheDay.Pick) -> some View {
        let accent = TreeWalkPalette.color(pick.line)
        return Button {
            _ = model.focus(onID: pick.personID)
            appLog.write("Person of the Day: card clicked — focusing \(pick.personID)")
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    Text("Person of the Day").font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    if pick.reason.isOnThisDay {
                        Text("On this day")
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(accent.opacity(0.22)))
                    }
                }
                .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    PersonOfTheDayPortrait(personID: pick.personID, sex: pick.sex,
                                           assetPerson: model.assetPerson(for: pick.personID),
                                           // No flag for a living person — where
                                           // they were born is private (QA P3-1).
                                           flag: pick.isLiving ? nil : model.birthFlag(for: pick.personID),
                                           revision: model.photoRevision, accent: accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let years = pick.years {
                            Text(years).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let relation = pick.relation {
                            Text(relation).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        if let place = pick.birthPlace {
                            Text(place).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(place)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(pick.whyToday)
                    .font(.system(size: 11.5).italic())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.08)))
            .overlay(alignment: .leading) {
                // A thin bar in the line's colour (Rick blue, Donna rose).
                UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9)
                    .fill(accent.opacity(0.75))
                    .frame(width: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Show \(pick.name) in the tree")
        .accessibilityLabel("Person of the Day: \(pick.name). \(pick.whyToday)")
        .accessibilityIdentifier("ft.personOfTheDay")
    }
}

/// The card's picture: the person's photo (the tree card's resolver, off
/// the main actor), else the birth-country flag, else the plain sex
/// placeholder. 52 pt circle.
struct PersonOfTheDayPortrait: View {
    let personID: String
    let sex: String
    let assetPerson: FamilyAssetPerson?
    let flag: FamilyTreeBirthFlag?
    let revision: Int
    let accent: Color
    var side: CGFloat = 52

    @State private var image: NSImage?

    private struct Key: Equatable {
        let personID: String
        let revision: Int
    }

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.18))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let flag {
                Text(flag.emoji)
                    .font(.system(size: side * 0.5))
                    .help(flag.tooltip)
                    .accessibilityLabel(flag.accessibilityLabel)
            } else {
                Image(systemName: sex.isEmpty ? "person.crop.circle.dashed" : "person.fill")
                    .font(.system(size: side * 0.45, weight: .medium))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().stroke(accent.opacity(0.6), lineWidth: 1.2))
        .task(id: Key(personID: personID, revision: revision)) {
            image = nil
            guard let person = assetPerson else { return }
            let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
            let pixels = Int(side * 3)
            let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
                let store = configuration.makeStore()
                guard let url = PersonPhotoResolver(store: store).treePhoto(for: person, bridgedProfile: nil)?.url,
                      let cg = store.makeThumbnail(for: url, maxPixelSize: pixels) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}
