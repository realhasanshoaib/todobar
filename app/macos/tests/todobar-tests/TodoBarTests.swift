import XCTest
@testable import TodoBar

final class TodoBarTests: XCTestCase {
    func testLegacyDueTextMigratesToATag() throws {
        let data = Data(
            """
            {
              "id": "legacy",
              "title": "Old task",
              "completed": false,
              "dueDate": "Client",
              "createdAt": "2026-07-17T12:00:00Z",
              "updatedAt": "2026-07-17T12:00:00Z",
              "sortOrder": 1
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let task = try decoder.decode(TodoTask.self, from: data)

        XCTAssertEqual(task.tags, ["Client"])
    }

    func testReminderIsDueOnlyForActiveUnfiredTasks() {
        XCTAssertTrue(TodoTask(title: "A", reminderAt: Date().addingTimeInterval(-1)).reminderIsDue)
        XCTAssertFalse(TodoTask(title: "B", completed: true, reminderAt: Date().addingTimeInterval(-1)).reminderIsDue)
        XCTAssertFalse(TodoTask(title: "C", reminderAt: Date().addingTimeInterval(60)).reminderIsDue)
        XCTAssertFalse(TodoTask(title: "D", reminderAt: Date().addingTimeInterval(-1), reminderFiredAt: Date()).reminderIsDue)
    }

    @MainActor
    func testDraggingTaskChangesPriorityOrderAndPersistsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["TODOBAR_DATA_DIRECTORY"]
        setenv("TODOBAR_DATA_DIRECTORY", directory.path, 1)
        defer {
            if let previousDirectory {
                setenv("TODOBAR_DATA_DIRECTORY", previousDirectory, 1)
            } else {
                unsetenv("TODOBAR_DATA_DIRECTORY")
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let completed = TodoTask(id: UUID().uuidString, title: "Done", completed: true, sortOrder: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([completed]).write(to: directory.appendingPathComponent("tasks.json"))
        let repository = LocalTaskRepository()
        let initialTasks = try await repository.loadTasks()
        XCTAssertEqual(initialTasks.map(\.id), [completed.id])
        guard initialTasks.map(\.id) == [completed.id] else { return }
        for (id, order) in [("first", 10.0), ("second", 20.0), ("third", 30.0)] {
            _ = try await repository.createTask(TodoTask(id: id, title: id, sortOrder: order))
        }
        let effects = EffectsController()
        let reminders = ReminderController(effects: effects, requestNotificationAuthorization: false)
        let appState = AppState(repository: repository, effects: effects, reminders: reminders, isCloudConfigured: false)
        appState.load()
        let loadDeadline = Date().addingTimeInterval(2)
        while appState.tasks.count != 4 && Date() < loadDeadline {
            await Task.yield()
        }
        XCTAssertEqual(appState.tasks.count, 4)
        XCTAssertEqual(appState.activeTasks.map(\.id), ["first", "second", "third"])
        XCTAssertNil(appState.priorityRank(for: "done"))

        appState.moveActiveTask("first", to: "second")
        let middleDeadline = Date().addingTimeInterval(2)
        var middleDrop = try await LocalTaskRepository().loadTasks()
        while middleDrop.filter({ !$0.completed }).sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id) != ["second", "first", "third"] && Date() < middleDeadline {
            await Task.yield()
            middleDrop = try await LocalTaskRepository().loadTasks()
        }
        XCTAssertEqual(appState.activeTasks.map(\.id), ["second", "first", "third"])
        XCTAssertEqual(middleDrop.filter { !$0.completed }.sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id), ["second", "first", "third"])

        appState.moveActiveTask("third", to: "second")
        let frontDeadline = Date().addingTimeInterval(2)
        var restored = try await LocalTaskRepository().loadTasks()
        while restored.filter({ !$0.completed }).sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id) != ["third", "second", "first"] && Date() < frontDeadline {
            await Task.yield()
            restored = try await LocalTaskRepository().loadTasks()
        }
        XCTAssertEqual(restored.filter { !$0.completed }.sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id), ["third", "second", "first"])
        XCTAssertEqual(appState.priorityRank(for: "third"), 1)

        appState.toggle(completed)
        let completionDeadline = Date().addingTimeInterval(2)
        var reopened = try await LocalTaskRepository().loadTasks()
        while reopened.first(where: { $0.id == "done" })?.completed != false && Date() < completionDeadline {
            await Task.yield()
            reopened = try await LocalTaskRepository().loadTasks()
        }
        XCTAssertEqual(reopened.first(where: { $0.id == "done" })?.completed, false)
        XCTAssertEqual(appState.activeTasks.map(\.id), ["done", "third", "second", "first"])
        XCTAssertTrue(appState.completedTasks.isEmpty)
    }
}
