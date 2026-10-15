import AppKit
import SwiftUI

struct SetupView: View {
    @ObservedObject var setup: SetupCoordinator
    let readyActionTitle: String
    let isHelpSessionActive: Bool
    let onReady: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(setup.readiness.isReady ? "You’re all set." : "Let’s get you ready.")
                    .font(.system(size: 25, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 13, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close setup")
                    .disabled(setup.isRestarting)
            }
            Text("Three simple steps. We’ll take them one at a time.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(SetupStep.allCases.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, number: index + 1)
                    if index < 2 { Divider().padding(.leading, 54) }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text(setup.readiness.nextStep?.title ?? "Ready to help")
                    .font(.system(size: 19, weight: .semibold))
                Text(setup.explanation).font(.system(size: 16))
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = setup.notice {
                    Text(notice).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if setup.readiness.isReady {
                    setup.refresh()
                    if setup.readiness.isReady { onReady() }
                } else { setup.performPrimaryAction() }
            } label: {
                HStack(spacing: 10) {
                    if setup.isRequesting { ProgressView().controlSize(.small) }
                    Text(setup.isRequesting ? setup.activityLabel :
                         (setup.readiness.isReady ? readyActionTitle : setup.actionTitle))
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
            .disabled(setup.isRequesting)

            if setup.canOpenScreenSettings {
                Button("Open Screen Recording instead") { setup.openScreenSettings() }
                    .buttonStyle(.link).font(.system(size: 14))
                    .disabled(setup.isRequesting)
            }

            Text(isHelpSessionActive ? "Your help session is still active. We’ll check setup as you make changes." :
                 "We’re only checking setup. Your microphone and screen are not being recorded.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).frame(width: 440)
        .task {
            while !Task.isCancelled {
                setup.refresh()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refresh() }
        .onDisappear { setup.cancelPendingAction() }
    }

    private func stepRow(_ step: SetupStep, number: Int) -> some View {
        let complete = setup.readiness.isComplete(step)
        let current = setup.readiness.nextStep == step
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(complete || current ? Color.teal.opacity(0.12) : Color.primary.opacity(0.05))
                if complete {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.teal)
                } else {
                    Text("\(number)").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(current ? Color.teal : Color.secondary)
                }
            }.frame(width: 36, height: 36)
            Text(step.title).font(.system(size: 16, weight: current ? .semibold : .regular))
            Spacer()
            if complete { Text("Ready").font(.system(size: 13)).foregroundStyle(.teal) }
        }
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(complete ? "ready" : current ? "current step" : "next")")
    }
}
