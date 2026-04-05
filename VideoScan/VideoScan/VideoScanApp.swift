//
//  VideoScanApp.swift
//  VideoScan
//
//  Created by rickb on 3/15/26.
//

import SwiftUI

@main
struct VideoScanApp: App {
    @StateObject private var catalogModel = VideoScanModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
            CommandGroup(after: .windowArrangement) {
                WindowMenuItems()
            }
        }

        Window("About VideoScan", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("VideoScan Dashboard", id: "dashboard") {
            DashboardWindow()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("VideoScan Console", id: "console") {
            ConsoleWindow()
                .environmentObject(catalogModel.dashboard)
        }
        .defaultPosition(.bottomTrailing)
    }
}

struct AboutMenuItem: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("About VideoScan") {
            openWindow(id: "about")
        }
    }
}

struct WindowMenuItems: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Dashboard") {
            openWindow(id: "dashboard")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Button("Console") {
            openWindow(id: "console")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Header
            ZStack(alignment: .bottom) {
                Image("AboutCollage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)

                // Title overlay
                VStack(spacing: 4) {
                    Text("VideoScan")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Text("Find the people you love in your home videos")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .clipped()

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AboutSection(icon: "heart.fill", color: .pink, title: "What it does") {
                        Text("VideoScan finds the people you're looking for by scanning folders or your whole computer. You can organize your memories by person or create a catalog for reference.")
                    }

                    AboutSection(icon: "person.crop.rectangle.stack", color: .blue, title: "How it works") {
                        Text("You provide a folder of reference photos (or pick from Apple Photos) and the app detects faces in videos and can generate new videos of that person, optionally creating videos by decade, such as Donna_1990, Donna_2000s.")
                    }

                    AboutSection(icon: "externaldrive.connected.to.line.below", color: .green, title: "Multi-volume, parallel scanning") {
                        Text("Add as many volumes or folders as you like. Each runs in parallel with its own progress bar.")
                    }

                    AboutSection(icon: "waveform.and.magnifyingglass", color: .purple, title: "Handles Any Video Format") {
                        Text("Supports 40+ video formats including MXF, DV, VHS captures, MOV, MP4, MTS, and more.")
                    }

                    Divider()

                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("Developed By Rick Breen.   Inspired by Donna.")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 620)
    }
}

struct AboutSection<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    @ViewBuilder let content: () -> Content

    init(icon: String, color: Color, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon; self.color = color; self.title = title; self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                content()
                    .font(.body)
                    .foregroundColor(.primary.opacity(0.85))
            }
        }
    }
}

struct BulletPoint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(.secondary)
            Text(text)
        }
    }
}

