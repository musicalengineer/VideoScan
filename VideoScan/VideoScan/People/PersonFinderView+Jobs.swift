// PersonFinderView+Jobs.swift
// The Searches section — the search-header buttons, the active/terminal
// job partition, the per-job row, the history toggle/footer, and the
// jobs list itself — extracted verbatim from PersonFinderView's body in
// PersonFinderView.swift (refactor 2026-06-24). Members shared with the
// main file are internal there; `private` here is file-private to THIS
// file.

import SwiftUI
import AppKit

extension PersonFinderView {

    @ViewBuilder
    var searchHeaderButtons: some View {
        Menu {
            ForEach(model.savedProfiles) { profile in
                Button {
                    addJobForPerson(profile)
                } label: {
                    Label(profile.name, systemImage: "person.circle")
                }
            }
            if model.savedProfiles.isEmpty {
                Text("Add people in the gallery above first")
            }
        } label: {
            Label("New Search\u{2026}", systemImage: "plus.circle.fill")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.savedProfiles.isEmpty)

        Button {
            PreviewWindowController.shared.show(model: model)
        } label: {
            Label("Face Detection", systemImage: "eye.fill")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.jobs.isEmpty)

        Button {
            JobConsoleWindowController.shared.show(model: model, focusJobID: selectedJobID)
        } label: {
            Label("Console", systemImage: "terminal")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.jobs.isEmpty)
        // Gauntlet flow 1 opens the job console here to assert the
        // refused-below-floor line. Test-only.
        .accessibilityIdentifier("pf.console.open")

        let anyIdle   = model.jobs.contains { $0.status.isIdle }
        let anyActive = model.jobs.contains { $0.status.isActive }
        if model.jobs.count > 1 && anyIdle {
            Button { model.startAll(); if selectedJobID == nil { selectedJobID = model.jobs.first?.id } } label: {
                Label("Start All", systemImage: "play.fill").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        if model.jobs.count > 1 && anyActive {
            Button { model.stopAll() } label: {
                Label("Stop All", systemImage: "stop.fill").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Partition jobs into "active" (idle/loading/scanning/paused — though
    /// paused is technically terminal in our isTerminal sense, the user
    /// still treats it as work-in-flight so we keep it in the active list)
    /// and "terminal" (done/cancelled/failed). Terminal jobs sort newest
    /// first by completedAt so the most recent search appears at the top
    /// of history. Pure function — testable in isolation.
    static func splitJobs(_ jobs: [ScanJob]) -> (active: [ScanJob], terminal: [ScanJob]) {
        var active: [ScanJob] = []
        var terminal: [ScanJob] = []
        for job in jobs {
            // .paused is technically not isTerminal in the model sense, but
            // for the UI we want paused jobs to stay with active ones so the
            // user sees them at the top when they relaunch and want to resume.
            if job.status.isTerminal && job.status != .paused {
                terminal.append(job)
            } else {
                active.append(job)
            }
        }
        terminal.sort { (lhs, rhs) in
            (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
        return (active, terminal)
    }

    @ViewBuilder
    private func jobRow(_ job: ScanJob) -> some View {
        ScanJobRow(
            job: job,
            model: model,
            isSelected: selectedJobID == job.id,
            isExpanded: expandedJobIDs.contains(job.id),
            // Engine-effective threshold, not the global Vision slider: an
            // AdaFace/ArcFace row must show its own cosine threshold (0.30 /
            // 0.40), not a stale "thresh 0.52". A restored row carries its
            // real engine via assignedEngine (makeJob), so effectiveEngine is
            // correct here without a global default.
            threshold: model.settings.thresholdForEngine(job.effectiveEngine),
            savedProfiles: model.savedProfiles,
            onToggleExpand: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedJobIDs.contains(job.id) {
                        expandedJobIDs.remove(job.id)
                    } else {
                        expandedJobIDs.insert(job.id)
                    }
                }
            },
            onStart: { selectedJobID = job.id; expandedJobIDs.insert(job.id); model.startJob(job) },
            onStop: { model.stopJob(job) },
            onPause: { model.togglePauseJob(job) },
            onReset: { job.reset() },
            onRemove: { expandedJobIDs.remove(job.id); model.removeJob(job) },
            onPreview: { PreviewWindowController.shared.show(model: model, focusJobID: job.id) }
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { selectedJobID = job.id }
        )
    }

    @ViewBuilder
    private func historyToggle(totalHistory: Int) -> some View {
        let hidden = totalHistory - Self.visibleHistoryDefault
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showAllSearchHistory.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAllSearchHistory ? "chevron.up" : "chevron.down")
                Text(showAllSearchHistory
                     ? "Show fewer"
                     : "Show \(hidden) more older search\(hidden == 1 ? "" : "es")")
            }
            .font(.system(size: 12))
            .foregroundColor(.accentColor)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func historyFooter(retention: Int) -> some View {
        Text("Older searches auto-removed after \(retention) — your most recent ones are kept.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }

    var jobsSection: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.body).foregroundColor(.secondary)
                    Text("Use \"New Search\" to start finding people in your videos")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        // Active jobs always visible (the user wants to watch
                        // live work). Terminal jobs sort newest-first and
                        // collapse to 5 by default so the list doesn't grow
                        // unbounded — "Show more" reveals the rest, up to
                        // the ScanJobsStorage retention cap (10).
                        let split = Self.splitJobs(model.jobs)
                        ForEach(split.active) { job in
                            jobRow(job)
                        }
                        let visibleHistory = showAllSearchHistory
                            ? split.terminal
                            : Array(split.terminal.prefix(Self.visibleHistoryDefault))
                        ForEach(visibleHistory) { job in
                            jobRow(job)
                        }
                        if split.terminal.count > Self.visibleHistoryDefault {
                            historyToggle(totalHistory: split.terminal.count)
                        }
                        if !split.terminal.isEmpty {
                            historyFooter(retention: ScanJobsStorage.defaultLimit)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}
