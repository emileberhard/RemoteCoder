import SwiftUI

/// Scalar match values retain their JSON type; structured saved values remain
/// available in the complete Advanced configuration rather than becoming text.
struct AutomationTriggerMatchView: View {
    @Binding var values: [String: JSONValue]
    @State private var error: String?
    @State private var newPath = "/data/"
    var body: some View {
        DisclosureGroup("Match conditions") {
            ForEach(values.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading) {
                    Text(key).scaledFont(.subheadline).textSelection(.enabled)
                    Picker("Value type", selection: Binding(get: { type(of: values[key]) }, set: { type in
                        switch type {
                        case "string": values[key] = .string("")
                        case "number": values[key] = .number(0)
                        case "bool": values[key] = .bool(false)
                        case "null": values[key] = .null
                        default: break
                        }
                    })) {
                        Text("Text").tag("string"); Text("Number").tag("number")
                        Text("Boolean").tag("bool"); Text("Null").tag("null")
                        if type(of: values[key]) == "structured" { Text("Structured (saved)").tag("structured") }
                    }
                    switch values[key] {
                    case .string:
                        TextField("Value", text: Binding(get: { values[key]?.stringValue ?? "" }, set: { values[key] = .string($0) }))
                    case .number(let number):
                        TextField("Value", value: Binding(get: { number }, set: { values[key] = .number($0) }), format: .number)
                    case .bool(let flag):
                        Toggle("Value", isOn: Binding(get: { flag }, set: { values[key] = .bool($0) }))
                    case .object, .array:
                        Text("Edit this structured value in Advanced.").scaledFont(.footnote).foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                    Button("Remove condition", role: .destructive) { values.removeValue(forKey: key) }
                }
            }
            TextField("New JSON Pointer path", text: $newPath).autocorrectionDisabled()
            Button("Add condition") {
                guard newPath.hasPrefix("/"), newPath.count > 1, values[newPath] == nil else {
                    error = "Use a unique JSON Pointer path starting with / (for example /data/conversation_id)."; return
                }
                values[newPath] = .string(""); newPath = "/data/"; error = nil
            }.disabled(values.count >= 50)
            if let error { Text(error).scaledFont(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func type(of value: JSONValue?) -> String {
        switch value {
        case .string: "string"; case .number: "number"; case .bool: "bool"
        case .null, nil: "null"; case .array, .object: "structured"
        }
    }
}
