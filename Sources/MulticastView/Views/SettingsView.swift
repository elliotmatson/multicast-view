import SwiftUI
import MulticastCore
import MulticastSystem

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            SwitchSettings(model: model)
                .tabItem { Label("Switches", systemImage: "network") }
            CaptureSettings(model: model)
                .tabItem { Label("Capture", systemImage: "waveform") }
            RuleSettings(model: model)
                .tabItem { Label("Protocols", systemImage: "tag") }
        }
        .frame(width: 660, height: 460)
    }
}

// MARK: - Switches

private struct SwitchSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SNMP read access lets MulticastView ask each switch which ports it is forwarding "
               + "each group out of. Without it the app still works; you just lose the comparison "
               + "between what is flowing and what the switches think they are forwarding.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Not every switch exposes this. Some expose very little of the Q-BRIDGE MIB and "
                + "some expose none of it, in which case the switch-port column stays empty however "
                + "this is configured \u{2014} a limit of the switch, not a failed poll. The capture "
                + "and the local-membership columns still work normally.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(settings.switches) {
                TableColumn("Name") { device in
                    TextField("core-sw", text: binding(for: device, keyPath: \.name))
                        .textFieldStyle(.roundedBorder)
                }
                TableColumn("Host") { device in
                    TextField("10.10.1.1", text: binding(for: device, keyPath: \.host))
                        .textFieldStyle(.roundedBorder)
                }
                TableColumn("Community") { device in
                    TextField("public", text: binding(for: device, keyPath: \.community))
                        .textFieldStyle(.roundedBorder)
                }
                TableColumn("On") { device in
                    Toggle("", isOn: binding(for: device, keyPath: \.isEnabled))
                        .labelsHidden()
                }
                .width(30)
            }
            .frame(minHeight: 150, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button {
                    settings.switches.append(SNMPSwitch())
                } label: { Label("Add switch", systemImage: "plus") }

                Button(role: .destructive) {
                    if !settings.switches.isEmpty { settings.switches.removeLast() }
                } label: { Label("Remove last", systemImage: "minus") }
                .disabled(settings.switches.isEmpty)

                Spacer()

                Button("Poll now") { model.pollSwitches() }
            }

            Divider()

            HStack {
                Text("Poll every")
                Slider(value: $settings.pollInterval, in: 10...300, step: 5)
                    .frame(minWidth: 140, idealWidth: 180)
                Text("\(Int(settings.pollInterval))s")
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .onChange(of: settings.pollInterval) { _ in model.pollIntervalChanged() }

            if let status = model.snmpStatus {
                Text(status)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.snmpFailures, id: \.self) { failure in
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Token.statusWarning)
                    Text(failure).foregroundColor(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(16)
    }

    private func binding<Value>(for device: SNMPSwitch,
                                keyPath: WritableKeyPath<SNMPSwitch, Value>) -> Binding<Value> {
        Binding(
            get: {
                settings.switches.first { $0.id == device.id }?[keyPath: keyPath]
                    ?? device[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = settings.switches.firstIndex(where: { $0.id == device.id }) else { return }
                settings.switches[index][keyPath: keyPath] = newValue
            })
    }
}

// MARK: - Capture

private struct CaptureSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Capture buffer")
                    Slider(value: Binding(get: { Double(settings.bufferMegabytes) },
                                          set: { settings.bufferMegabytes = Int($0) }),
                           in: 1...32, step: 1)
                    Text("\(settings.bufferMegabytes) MB")
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("The kernel's buffer. A bigger buffer absorbs bursts on a busy mirror port. "
                   + "Takes effect when the capture is next started.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("Sampling")
                    Slider(value: Binding(get: { Double(settings.sampleRate) },
                                          set: { settings.sampleRate = Int($0) }),
                           in: 1...64, step: 1)
                    Text(settings.sampleRate == 1 ? "every packet" : "1 in \(settings.sampleRate)")
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("Parse one packet in N and scale the counts back up. Use this when the capture "
                   + "is dropping: it cuts the per-packet cost so the reader keeps up, at the price "
                   + "of coarser figures. Rates stay roughly right; small streams may be missed.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("Forget silent streams after")
                    Slider(value: $settings.streamTimeout, in: 5...300, step: 5)
                    Text("\(Int(settings.streamTimeout))s")
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("Keeps the table showing what is happening now rather than everything ever seen.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            if let statistics = model.captureStatistics {
                Section("Kernel counters") {
                    Text("\(statistics.received) accepted by the filter, \(statistics.dropped) dropped")
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Site-specific protocol rules

private struct RuleSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The built-in catalogue covers the protocols with registered ports or published "
               + "addresses. For gear that uses neither \u{2014} or for a group range your site has "
               + "allocated to something specific \u{2014} add a rule here. Your rules are checked "
               + "before the catalogue.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(settings.customRules) {
                TableColumn("Label") { rule in
                    TextField("SDVoE wall", text: binding(for: rule, keyPath: \.name))
                        .textFieldStyle(.roundedBorder)
                }
                TableColumn("Family") { rule in
                    Picker("", selection: binding(for: rule, keyPath: \.family)) {
                        ForEach(ProtocolFamily.filterable, id: \.self) { family in
                            Text(family.displayName).tag(family)
                        }
                    }
                    .labelsHidden()
                }
                .width(110)
                TableColumn("Port") { rule in
                    TextField("", text: portBinding(for: rule, keyPath: \.portLow))
                        .textFieldStyle(.roundedBorder)
                }
                .width(60)
                TableColumn("to") { rule in
                    TextField("", text: portBinding(for: rule, keyPath: \.portHigh))
                        .textFieldStyle(.roundedBorder)
                }
                .width(60)
                TableColumn("Group") { rule in
                    TextField("239.100.0.0", text: optionalText(for: rule, keyPath: \.groupPrefix))
                        .textFieldStyle(.roundedBorder)
                }
                TableColumn("/") { rule in
                    TextField("16", text: prefixBinding(for: rule))
                        .textFieldStyle(.roundedBorder)
                }
                .width(40)
                TableColumn("On") { rule in
                    Toggle("", isOn: binding(for: rule, keyPath: \.isEnabled)).labelsHidden()
                }
                .width(30)
            }
            .frame(minHeight: 170, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button {
                    settings.customRules.append(CustomClassificationRule(name: "New rule"))
                } label: { Label("Add rule", systemImage: "plus") }
                Button(role: .destructive) {
                    if !settings.customRules.isEmpty { settings.customRules.removeLast() }
                } label: { Label("Remove last", systemImage: "minus") }
                .disabled(settings.customRules.isEmpty)
                Spacer()
            }
        }
        .padding(16)
    }

    private func binding<Value>(for rule: CustomClassificationRule,
                                keyPath: WritableKeyPath<CustomClassificationRule, Value>) -> Binding<Value> {
        Binding(
            get: {
                settings.customRules.first { $0.id == rule.id }?[keyPath: keyPath] ?? rule[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = settings.customRules.firstIndex(where: { $0.id == rule.id }) else { return }
                settings.customRules[index][keyPath: keyPath] = newValue
            })
    }

    private func optionalText(for rule: CustomClassificationRule,
                              keyPath: WritableKeyPath<CustomClassificationRule, String?>) -> Binding<String> {
        Binding(
            get: { settings.customRules.first { $0.id == rule.id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = settings.customRules.firstIndex(where: { $0.id == rule.id }) else { return }
                settings.customRules[index][keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            })
    }

    private func portBinding(for rule: CustomClassificationRule,
                             keyPath: WritableKeyPath<CustomClassificationRule, UInt16?>) -> Binding<String> {
        Binding(
            get: {
                guard let value = settings.customRules.first(where: { $0.id == rule.id })?[keyPath: keyPath]
                else { return "" }
                return String(value)
            },
            set: { newValue in
                guard let index = settings.customRules.firstIndex(where: { $0.id == rule.id }) else { return }
                settings.customRules[index][keyPath: keyPath] = UInt16(newValue)
            })
    }

    private func prefixBinding(for rule: CustomClassificationRule) -> Binding<String> {
        Binding(
            get: {
                guard let value = settings.customRules.first(where: { $0.id == rule.id })?.prefixLength
                else { return "" }
                return String(value)
            },
            set: { newValue in
                guard let index = settings.customRules.firstIndex(where: { $0.id == rule.id }) else { return }
                settings.customRules[index].prefixLength = Int(newValue)
            })
    }
}
