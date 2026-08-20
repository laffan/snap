//
//  LaunchWidget.swift
//  SnapWidgets
//
//  A circular lock-screen widget that does nothing but open the app.
//

import SwiftUI
import WidgetKit

struct LaunchEntry: TimelineEntry {
    let date: Date
}

/// Nothing about this widget changes over time, so the timeline is a single
/// entry that never asks to be refreshed.
struct LaunchProvider: TimelineProvider {

    func placeholder(in context: Context) -> LaunchEntry {
        LaunchEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LaunchEntry) -> Void) {
        completion(LaunchEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LaunchEntry>) -> Void) {
        completion(Timeline(entries: [LaunchEntry(date: .now)], policy: .never))
    }
}

struct LaunchWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SnapLaunchWidget", provider: LaunchProvider()) { _ in
            LaunchWidgetView()
        }
        .configurationDisplayName("Snap")
        .description("Opens the camera.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LaunchWidgetView: View {

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            Image(systemName: "camera.aperture")
                .font(.system(size: 22, weight: .light))
        }
        // Required from iOS 17: a widget has to declare its own background
        // rather than painting one into its content.
        .containerBackground(.clear, for: .widget)
    }
}
