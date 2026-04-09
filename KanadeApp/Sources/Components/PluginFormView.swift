import SwiftUI
import KanadeKit

struct PluginFormView: View {
    let definition: PluginFormDefinition
    @Binding var values: [String: String]
    let onSubmit: (() -> Void)?

    init(
        definition: PluginFormDefinition,
        values: Binding<[String: String]>,
        onSubmit: (() -> Void)? = nil
    ) {
        self.definition = definition
        self._values = values
        self.onSubmit = onSubmit
    }

    var body: some View {
        Form {
            ForEach(definition.sections) { section in
                Section(section.title ?? "") {
                    ForEach(section.fields) { field in
                        fieldView(for: field)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    @ViewBuilder
    private func fieldView(for field: PluginFormField) -> some View {
        switch field.type {
        case .text:
            textFieldView(for: field)
        case .toggle:
            toggleView(for: field)
        case .select:
            selectView(for: field)
        case .number:
            numberFieldView(for: field)
        }
    }

    @ViewBuilder
    private func textFieldView(for field: PluginFormField) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] ?? field.value ?? "" },
            set: { values[field.id] = $0 }
        )

        #if os(iOS)
        LabeledContent(field.label) {
            if field.secure == true {
                SecureField(field.placeholder ?? "", text: binding)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(field.placeholder ?? "", text: binding)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        #else
        if field.secure == true {
            SecureField(field.label, text: binding, prompt: Text(field.placeholder ?? ""))
                .multilineTextAlignment(.trailing)
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder ?? ""))
                .multilineTextAlignment(.trailing)
        }
        #endif
    }

    @ViewBuilder
    private func toggleView(for field: PluginFormField) -> some View {
        let binding = Binding<Bool>(
            get: { values[field.id] == "true" || (values[field.id] == nil && field.value == "true") },
            set: { values[field.id] = $0 ? "true" : "false" }
        )

        Toggle(field.label, isOn: binding)
    }

    @ViewBuilder
    private func selectView(for field: PluginFormField) -> some View {
        let options = field.options ?? []
        let binding = Binding<String>(
            get: { values[field.id] ?? field.value ?? (options.first ?? "") },
            set: { values[field.id] = $0 }
        )

        #if os(iOS)
        Picker(field.label, selection: binding) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        #else
        Picker(field.label, selection: binding) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.menu)
        #endif
    }

    @ViewBuilder
    private func numberFieldView(for field: PluginFormField) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] ?? field.value ?? "" },
            set: { newValue in
                if let number = Double(newValue) {
                    let clamped = clamp(number, min: field.min, max: field.max)
                    values[field.id] = String(clamped)
                } else {
                    values[field.id] = newValue
                }
            }
        )

        #if os(iOS)
        LabeledContent(field.label) {
            TextField(field.placeholder ?? "", text: binding)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
        #else
        TextField(field.label, text: binding, prompt: Text(field.placeholder ?? ""))
            .multilineTextAlignment(.trailing)
        #endif
    }

    private func clamp(_ value: Double, min: Double?, max: Double?) -> Double {
        var result = value
        if let min = min {
            result = Swift.max(result, min)
        }
        if let max = max {
            result = Swift.min(result, max)
        }
        return result
    }
}

#if DEBUG
struct PluginFormPreview: View {
    @State private var values: [String: String] = [:]

    var body: some View {
        PluginFormView(
            definition: PluginFormDefinition(
                sections: [
                    PluginFormSection(
                        id: "credentials",
                        title: "Last.fm",
                        fields: [
                            PluginFormField(
                                id: "api_key",
                                type: .text,
                                label: "API Key",
                                placeholder: "Enter API key",
                                secure: true,
                                value: ""
                            ),
                            PluginFormField(
                                id: "enabled",
                                type: .toggle,
                                label: "Enable Scrobbling",
                                value: "true"
                            ),
                            PluginFormField(
                                id: "priority",
                                type: .select,
                                label: "Priority",
                                options: ["Low", "Normal", "High"],
                                value: "Normal"
                            ),
                            PluginFormField(
                                id: "timeout",
                                type: .number,
                                label: "Timeout (seconds)",
                                placeholder: "30",
                                min: 1,
                                max: 300,
                                value: "30"
                            )
                        ]
                    )
                ]
            ),
            values: $values
        )
    }
}
#endif
