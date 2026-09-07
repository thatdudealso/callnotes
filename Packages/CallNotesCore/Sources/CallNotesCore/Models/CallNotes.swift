import Foundation

/// Structured notes for one call, stored as JSONB in the `notes` table.
public struct CallNotes: Codable, Sendable, Equatable {
    public struct ActionItem: Codable, Sendable, Equatable {
        public var owner: String?
        public var text: String
        public var due: String?

        public init(owner: String? = nil, text: String, due: String? = nil) {
            self.owner = owner
            self.text = text
            self.due = due
        }
    }

    public struct Entities: Codable, Sendable, Equatable {
        public var people: [String]
        public var companies: [String]
        public var amounts: [String]
        public var dates: [String]

        public init(
            people: [String] = [],
            companies: [String] = [],
            amounts: [String] = [],
            dates: [String] = []
        ) {
            self.people = people
            self.companies = companies
            self.amounts = amounts
            self.dates = dates
        }
    }

    public var title: String
    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var followUps: [String]
    public var openQuestions: [String]
    public var entities: Entities

    public init(
        title: String,
        summary: String,
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        followUps: [String] = [],
        openQuestions: [String] = [],
        entities: Entities = Entities()
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.followUps = followUps
        self.openQuestions = openQuestions
        self.entities = entities
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case followUps = "follow_ups"
        case openQuestions = "open_questions"
        case entities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        followUps = try container.decodeIfPresent([String].self, forKey: .followUps) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        entities = try container.decodeIfPresent(Entities.self, forKey: .entities) ?? Entities()
    }
}
