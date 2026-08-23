// FamilyTreeLayout.swift
// Pure pedigree/descendant layout over a GedcomFamilyGraph for the
// Family Tree tab (2026-08-22 overnight plan, feature/family-tree-gedcom).
//
// This is a value type with one static entry point and no SwiftUI import,
// so the unit tests can exercise it without a view hierarchy. The view
// never calls it from `body`; FamilyTreeLiveModel runs it once per
// selection change and publishes the result.
//
// Shape (generation numbers are relative to the selected root):
//
//      -3   [8 great-grandparent slots]
//      -2   [4 grandparent slots]            father left, mother right
//      -1   [2 parent slots]
//       0   [ROOT] [spouse] [spouse…]
//      +1   [children in file order, centred under the couple]
//      +2   [grandchildren under each child]
//
// Ancestor slots are a fixed binary pedigree: a person at depth d, slot s
// puts their father at (d+1, 2s) and mother at (d+1, 2s+1). Missing parents
// leave the slot empty (no re-balancing) so the father/mother sides stay
// visually stable as you walk around the tree.
//
// Cost: bounded by the generation caps, not by the size of the graph —
// at most 2^(A+1)-1 ancestor slots plus the root's spouses, children and
// grandchildren. A 5,000-person file lays out in microseconds.

import Foundation
import CoreGraphics

struct FamilyTreeLayout {

    // MARK: Geometry

    /// Card size and gaps. Defaults match the demo canvas the tab shipped
    /// with (150×194 cards) so the existing card view needs no changes.
    struct Metrics: Equatable {
        var cardSize = CGSize(width: 150, height: 194)
        var horizontalGap: CGFloat = 30
        var verticalGap: CGFloat = 60
        var margin: CGFloat = 40

        var slotWidth: CGFloat { cardSize.width + horizontalGap }
        var rowHeight: CGFloat { cardSize.height + verticalGap }
    }

    // MARK: Output

    /// One placed card. `id` is unique per *slot*, not per person: with
    /// pedigree collapse (cousin marriages) the same GEDCOM person can
    /// legitimately occupy two slots, and SwiftUI's ForEach needs distinct
    /// ids for each.
    struct Node: Identifiable, Equatable {
        let id: String
        let personID: String
        /// 0 = root, negative = ancestors, positive = descendants.
        let generation: Int
        let position: CGPoint
        let isRoot: Bool
        let isSpouseOfRoot: Bool
    }

    /// A line the canvas draws. `.spouse` is a straight horizontal segment
    /// between two card edges; `.child` is the elbow (down, across, down)
    /// from a parent or couple anchor to the top of a child card.
    struct Edge: Equatable {
        enum Kind: Equatable { case spouse, child }
        let kind: Kind
        let from: CGPoint
        let to: CGPoint
    }

    struct Result: Equatable {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var size: CGSize = .zero
        var rootID: String?

        static let empty = Result()

        func node(forPerson id: String) -> Node? {
            nodes.first { $0.personID == id }
        }
        func nodes(inGeneration generation: Int) -> [Node] {
            nodes.filter { $0.generation == generation }
        }
    }

    // MARK: Entry point

    /// Lay out `rootID` with up to `ancestorGenerations` rows above and
    /// `descendantGenerations` rows below. Returns `.empty` when the root
    /// is not in the graph.
    static func layout(graph: GedcomFamilyGraph,
                       rootID: String,
                       ancestorGenerations: Int = 3,
                       descendantGenerations: Int = 2,
                       metrics: Metrics = Metrics()) -> Result {
        guard let root = graph.people[rootID] else { return .empty }
        let ancestorGenerations = max(0, ancestorGenerations)
        let descendantGenerations = max(0, descendantGenerations)

        var builder = Builder(graph: graph, metrics: metrics,
                              ancestorGenerations: ancestorGenerations,
                              descendantGenerations: descendantGenerations)
        builder.placeRootAndAncestors(root)
        builder.placeDescendants(of: root)
        return builder.finish(rootID: rootID)
    }

    // MARK: Builder

    /// Accumulates nodes/edges in raw coordinates (root at x = pedigree
    /// centre, y by generation), then `finish` shifts everything so the
    /// top-left card sits at the margin.
    private struct Builder {
        let graph: GedcomFamilyGraph
        let metrics: Metrics
        let ancestorGenerations: Int
        let descendantGenerations: Int

        var nodes: [Node] = []
        var edges: [Edge] = []

        /// Width of the widest ancestor row; the root is centred on it.
        var pedigreeWidth: CGFloat {
            CGFloat(1 << ancestorGenerations) * metrics.slotWidth
        }
        var rootX: CGFloat { pedigreeWidth / 2 }

        func y(forGeneration generation: Int) -> CGFloat {
            CGFloat(generation) * metrics.rowHeight
        }

        /// Centre x of ancestor slot `slot` at `depth` rows above the root.
        func ancestorX(depth: Int, slot: Int) -> CGFloat {
            let slotsInRow = 1 << depth
            let slotWidth = pedigreeWidth / CGFloat(slotsInRow)
            return (CGFloat(slot) + 0.5) * slotWidth
        }

        mutating func add(_ person: GedcomFamilyGraph.Person,
                          generation: Int, x: CGFloat,
                          slotKey: String,
                          isRoot: Bool = false,
                          isSpouseOfRoot: Bool = false) -> Node {
            let node = Node(id: "\(generation)/\(slotKey)/\(person.id)",
                            personID: person.id,
                            generation: generation,
                            position: CGPoint(x: x, y: y(forGeneration: generation)),
                            isRoot: isRoot,
                            isSpouseOfRoot: isSpouseOfRoot)
            nodes.append(node)
            return node
        }

        func top(of node: Node) -> CGPoint {
            CGPoint(x: node.position.x,
                    y: node.position.y - metrics.cardSize.height / 2)
        }
        func bottom(of node: Node) -> CGPoint {
            CGPoint(x: node.position.x,
                    y: node.position.y + metrics.cardSize.height / 2)
        }

        mutating func spouseEdge(_ left: Node, _ right: Node) {
            let half = metrics.cardSize.width / 2
            edges.append(Edge(kind: .spouse,
                              from: CGPoint(x: left.position.x + half, y: left.position.y),
                              to: CGPoint(x: right.position.x - half, y: right.position.y)))
        }

        // MARK: Ancestors

        mutating func placeRootAndAncestors(_ root: GedcomFamilyGraph.Person) {
            let rootNode = add(root, generation: 0, x: rootX, slotKey: "root", isRoot: true)
            placeParents(of: root, childNode: rootNode, depth: 1, slot: 0)
        }

        /// Recursive pedigree walk. `depth` is rows above the root (1 = the
        /// person's own parents); `slot` is the binary slot index in that
        /// row. The generation cap is the only thing stopping the
        /// recursion, which also makes a malformed cyclic GEDCOM harmless.
        mutating func placeParents(of person: GedcomFamilyGraph.Person,
                                   childNode: Node, depth: Int, slot: Int) {
            guard depth <= ancestorGenerations else { return }
            let father = graph.relatives(.father, of: person).first
            let mother = graph.relatives(.mother, of: person).first
            guard father != nil || mother != nil else { return }

            let generation = -depth
            var fatherNode: Node?
            var motherNode: Node?
            if let father {
                fatherNode = add(father, generation: generation,
                                 x: ancestorX(depth: depth, slot: slot * 2),
                                 slotKey: "a\(slot * 2)")
            }
            if let mother {
                motherNode = add(mother, generation: generation,
                                 x: ancestorX(depth: depth, slot: slot * 2 + 1),
                                 slotKey: "a\(slot * 2 + 1)")
            }

            // Couple line + elbow down to the child; a lone parent gets the
            // elbow straight from their card.
            let anchor: CGPoint
            switch (fatherNode, motherNode) {
            case let (f?, m?):
                spouseEdge(f, m)
                anchor = CGPoint(x: (f.position.x + m.position.x) / 2,
                                 y: bottom(of: f).y)
            case let (f?, nil):
                anchor = bottom(of: f)
            case let (nil, m?):
                anchor = bottom(of: m)
            case (nil, nil):
                return
            }
            edges.append(Edge(kind: .child, from: anchor, to: top(of: childNode)))

            if let father, let fatherNode {
                placeParents(of: father, childNode: fatherNode,
                             depth: depth + 1, slot: slot * 2)
            }
            if let mother, let motherNode {
                placeParents(of: mother, childNode: motherNode,
                             depth: depth + 1, slot: slot * 2 + 1)
            }
        }

        // MARK: Descendants

        mutating func placeDescendants(of root: GedcomFamilyGraph.Person) {
            guard let rootNode = nodes.first(where: \.isRoot) else { return }

            // Spouses sit to the right of the root on the same row, chained
            // by spouse lines (root–s1, s1–s2 …).
            let spouses = uniqued(graph.relatives(.spouse, of: root))
            var previous = rootNode
            var firstSpouseNode: Node?
            for (index, spouse) in spouses.enumerated() {
                let node = add(spouse, generation: 0,
                               x: rootX + metrics.slotWidth * CGFloat(index + 1),
                               slotKey: "s\(index)", isSpouseOfRoot: true)
                spouseEdge(previous, node)
                if firstSpouseNode == nil { firstSpouseNode = node }
                previous = node
            }

            guard descendantGenerations >= 1 else { return }
            let children = uniqued(graph.relatives(.children, of: root))
            guard !children.isEmpty else { return }

            // Children are centred under the couple (root + first spouse)
            // when there is one, else under the root — same as the demo.
            let anchorX = firstSpouseNode.map { ($0.position.x + rootX) / 2 } ?? rootX
            let anchor = CGPoint(x: anchorX, y: bottom(of: rootNode).y)

            // Tidy-tree widths: a child's block is as wide as its own
            // children need, never narrower than one slot.
            let grandchildren: [[GedcomFamilyGraph.Person]] = children.map { child in
                descendantGenerations >= 2
                    ? uniqued(graph.relatives(.children, of: child))
                    : []
            }
            let widths: [CGFloat] = grandchildren.map {
                max(1, CGFloat($0.count)) * metrics.slotWidth
            }
            let total = widths.reduce(0, +)
            var cursor = anchorX - total / 2

            for (index, child) in children.enumerated() {
                let width = widths[index]
                let childX = cursor + width / 2
                let childNode = add(child, generation: 1, x: childX, slotKey: "c\(index)")
                edges.append(Edge(kind: .child, from: anchor, to: top(of: childNode)))

                let kids = grandchildren[index]
                let kidsLeft = childX - CGFloat(kids.count) * metrics.slotWidth / 2
                for (kidIndex, kid) in kids.enumerated() {
                    let kidX = kidsLeft + (CGFloat(kidIndex) + 0.5) * metrics.slotWidth
                    let kidNode = add(kid, generation: 2, x: kidX,
                                      slotKey: "c\(index).\(kidIndex)")
                    edges.append(Edge(kind: .child,
                                      from: bottom(of: childNode),
                                      to: top(of: kidNode)))
                }
                cursor += width
            }
        }

        /// File order preserved, duplicates dropped (a child recorded in
        /// two FAM records, or a spouse listed twice).
        func uniqued(_ people: [GedcomFamilyGraph.Person]) -> [GedcomFamilyGraph.Person] {
            var seen = Set<String>()
            return people.filter { seen.insert($0.id).inserted }
        }

        // MARK: Finish

        /// Shift so the left-most/top-most card edge sits at the margin and
        /// report the canvas size.
        func finish(rootID: String) -> Result {
            guard !nodes.isEmpty else { return .empty }
            let halfW = metrics.cardSize.width / 2
            let halfH = metrics.cardSize.height / 2
            let minX = nodes.map { $0.position.x - halfW }.min() ?? 0
            let minY = nodes.map { $0.position.y - halfH }.min() ?? 0
            let dx = metrics.margin - minX
            let dy = metrics.margin - minY

            func shifted(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x + dx, y: point.y + dy)
            }
            let movedNodes = nodes.map {
                Node(id: $0.id, personID: $0.personID, generation: $0.generation,
                     position: shifted($0.position),
                     isRoot: $0.isRoot, isSpouseOfRoot: $0.isSpouseOfRoot)
            }
            let movedEdges = edges.map {
                Edge(kind: $0.kind, from: shifted($0.from), to: shifted($0.to))
            }
            let maxX = movedNodes.map { $0.position.x + halfW }.max() ?? 0
            let maxY = movedNodes.map { $0.position.y + halfH }.max() ?? 0
            return Result(nodes: movedNodes, edges: movedEdges,
                          size: CGSize(width: maxX + metrics.margin,
                                       height: maxY + metrics.margin),
                          rootID: rootID)
        }
    }
}
