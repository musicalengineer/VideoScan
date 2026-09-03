// GedcomFamilyGraph+PrimaryParents.swift
// The ONE place a walk reads "the mother of" / "the father of" a person
// (2026-09-02, birthplace trail). A person may carry several FAMC links
// (birth, adoptive, step, or a FamilySearch duplicate); a lineage walk
// has to follow exactly one of them, and every walk must follow the SAME
// one, or two answers about the same line would disagree.
//
// The choice is the PRIMARY parent family per person
// (GedcomFamilyGraph+ParentFamily: `primaryParentFamilyID(of:)`), which
// is exactly what `relatives(.mother/.father)` returns — so these two
// accessors, the kinship routes, siblings and `directRelation` all read
// the SAME selection. Do not re-implement FAMC selection elsewhere.

import Foundation

extension GedcomFamilyGraph {

    /// The mother a lineage walk follows for `person`, or nil when the
    /// tree records none. See the file comment for how the choice is made.
    public func primaryMother(of person: Person) -> Person? {
        relatives(.mother, of: person).first
    }

    /// The father a lineage walk follows for `person`, or nil when the
    /// tree records none. See the file comment for how the choice is made.
    public func primaryFather(of person: Person) -> Person? {
        relatives(.father, of: person).first
    }
}
