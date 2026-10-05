# Step: xcode — Xcode components and Swift packages the build needs.
# Resolves packages only; never builds the app (Rick does his own builds).

section "Xcode components and Swift packages"

PROJECT="$REPO_ROOT/VideoScan/VideoScan.xcodeproj"

if ! xcodebuild -version >/dev/null 2>&1; then
    failed "Xcode components" "Xcode is not installed (see preflight)"
else
    # mlx-swift compiles Metal kernels; without this component the first build
    # stops to download ~700 MB.
    # (xcodebuild has no -showComponents; xcrun finds `metal` only when the
    # toolchain component is mounted.)
    if xcrun -f metal >/dev/null 2>&1; then
        ok "Metal Toolchain"
    elif checking; then
        failed "Metal Toolchain" "missing: xcodebuild -downloadComponent MetalToolchain"
    else
        note "downloading the Metal Toolchain (~700 MB, one time)…"
        if xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1; then
            installed "Metal Toolchain"
        else
            failed "Metal Toolchain" "run: xcodebuild -downloadComponent MetalToolchain"
        fi
    fi

    # Fetch mlx-swift-examples, swift-algorithms and their transitive packages
    # now, so the first ⌘R does not stall on the network. Pinned by the
    # committed Package.resolved.
    if checking; then
        if [[ -d "$HOME/Library/Caches/org.swift.swiftpm/repositories" ]]; then
            ok "SwiftPM cache present (packages resolve on first build)"
        else
            manual "Swift packages" "not resolved yet; the first build (or a run without --check) fetches them"
        fi
    else
        note "resolving Swift packages from Package.resolved…"
        if xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme VideoScan \
                -onlyUsePackageVersionsFromResolvedFile >/dev/null 2>&1; then
            ok "Swift packages resolved (mlx-swift-examples, swift-algorithms, …)"
        else
            failed "Swift packages" "run: xcodebuild -resolvePackageDependencies -project $PROJECT -scheme VideoScan"
        fi
    fi
fi
