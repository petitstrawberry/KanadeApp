import Foundation

struct PluginFormDefinition: Identifiable {
    let id: String
    let sections: [PluginFormSection]

    init(id: String = UUID().uuidString, sections: [PluginFormSection]) {
        self.id = id
        self.sections = sections
    }
}

struct PluginFormSection: Identifiable {
    let id: String
    let title: String?
    let fields: [PluginFormField]

    init(id: String = UUID().uuidString, title: String? = nil, fields: [PluginFormField]) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

struct PluginFormField: Identifiable {
    enum FieldType: String, Codable {
        case text
        case toggle
        case select
        case number
    }

    let id: String
    let type: FieldType
    let label: String
    var value: String?
    var placeholder: String?
    var secure: Bool?
    var options: [String]?
    var min: Double?
    var max: Double?

    init(
        id: String,
        type: FieldType,
        label: String,
        value: String? = nil,
        placeholder: String? = nil,
        secure: Bool? = nil,
        options: [String]? = nil,
        min: Double? = nil,
        max: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.secure = secure
        self.options = options
        self.min = min
        self.max = max
    }
}
