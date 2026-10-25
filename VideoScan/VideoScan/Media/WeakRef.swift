// WeakRef.swift
// A weak reference that a `@Sendable` closure may capture.
//
// Swift 6: `[weak model]` in a capture list makes `model` a captured VAR,
// and a var reached from concurrently-executing code (a task group's
// children, a progress callback) is exactly what the checker refuses —
// even when every use is `model?.…` inside `MainActor.run`. Wrapping the
// weak reference in a LET-bound value fixes that at the type level: the
// struct is immutable, the object it points at is `Sendable` (a
// `@MainActor` class is), and reading `object` is a plain weak load.
// C++: passing a `std::weak_ptr<T>` by value into a lambda instead of
// capturing a local by reference.

/// A let-bindable weak reference to a `Sendable` object.
struct WeakRef<Object: AnyObject & Sendable>: Sendable {
    private(set) weak var object: Object?

    init(_ object: Object?) { self.object = object }
}
