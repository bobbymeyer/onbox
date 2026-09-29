// onbox-eventkit: reads the Mac's Calendar and Reminders through EventKit and
// prints JSON, so onbox can use them without any cloud sign-in. Built on
// demand by onbox (see app/models/mac_event_kit.rb).
//
//   onbox-eventkit access                      -> {"calendar": "...", "reminders": "..."}
//   onbox-eventkit request                     -> asks macOS for access, then as access
//   onbox-eventkit events FROM TO              -> [event]   (ISO 8601 times)
//   onbox-eventkit reminders                   -> [reminder] (incomplete only)
//   onbox-eventkit complete ID                 -> {"ok": true}
//   onbox-eventkit reschedule ID WHEN          -> {"ok": true}
import EventKit
import Foundation

let store = EKEventStore()
let iso = ISO8601DateFormatter()

func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func stamp(_ date: Date?) -> Any { date.map { iso.string(from: $0) } ?? NSNull() }

func accessName(_ type: EKEntityType) -> String {
    switch EKEventStore.authorizationStatus(for: type) {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "granted"
    default:
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: type) {
            case .fullAccess: return "granted"
            case .writeOnly: return "write_only"
            default: return "unknown"
            }
        }
        return "unknown"
    }
}

func requestAccess(_ type: EKEntityType) {
    let done = DispatchSemaphore(value: 0)
    let finish: (Bool, Error?) -> Void = { _, _ in done.signal() }
    if #available(macOS 14.0, *) {
        if type == .event { store.requestFullAccessToEvents(completion: finish) }
        else { store.requestFullAccessToReminders(completion: finish) }
    } else {
        store.requestAccess(to: type, completion: finish)
    }
    _ = done.wait(timeout: .now() + 120)
}

func statusName(_ status: EKParticipantStatus) -> String {
    switch status {
    case .pending: return "pending"
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "in_process"
    default: return "unknown"
    }
}

func eventJSON(_ event: EKEvent) -> [String: Any] {
    let me = event.attendees?.first(where: { $0.isCurrentUser })
    return [
        "event_id": event.eventIdentifier ?? "",
        "series_id": event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "",
        "recurring": event.hasRecurrenceRules,
        "status": event.status == .canceled ? "cancelled" : "confirmed",
        "updated": stamp(event.lastModifiedDate),
        "summary": event.title ?? "(no title)",
        "start": stamp(event.startDate),
        "end": stamp(event.endDate),
        "all_day": event.isAllDay,
        "location": event.location ?? NSNull(),
        "description": event.notes.map { String($0.prefix(4000)) } ?? NSNull(),
        "html_link": event.url?.absoluteString ?? NSNull(),
        "calendar": event.calendar?.title ?? NSNull(),
        "organizer": event.organizer?.name ?? NSNull(),
        "organizer_self": event.organizer?.isCurrentUser ?? false,
        "attendees": (event.attendees ?? []).prefix(30).map { ["name": $0.name ?? $0.url.absoluteString, "response": statusName($0.participantStatus)] },
        "self_response": me.map { statusName($0.participantStatus) } ?? NSNull()
    ]
}

func reminderJSON(_ reminder: EKReminder) -> [String: Any] {
    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    return [
        "reminder_id": reminder.calendarItemIdentifier,
        "title": reminder.title ?? "(untitled)",
        "notes": reminder.notes.map { String($0.prefix(4000)) } ?? NSNull(),
        "list": reminder.calendar?.title ?? NSNull(),
        "due": stamp(due),
        "all_day_due": reminder.dueDateComponents.map { $0.hour == nil } ?? false,
        "priority": reminder.priority,
        "url": reminder.url?.absoluteString ?? NSNull(),
        "updated": stamp(reminder.lastModifiedDate)
    ]
}

func reminder(_ id: String) -> EKReminder {
    guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { fail("no reminder \(id)") }
    return item
}

func date(_ text: String) -> Date {
    guard let value = iso.date(from: text) else { fail("not an ISO 8601 time: \(text)") }
    return value
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "access":
    emit(["calendar": accessName(.event), "reminders": accessName(.reminder)])
case "request":
    requestAccess(.event)
    requestAccess(.reminder)
    emit(["calendar": accessName(.event), "reminders": accessName(.reminder)])
case "events":
    guard args.count == 3 else { fail("usage: events FROM TO") }
    let list = Array(args)
    let predicate = store.predicateForEvents(withStart: date(list[1]), end: date(list[2]), calendars: nil)
    emit(store.events(matching: predicate).map(eventJSON))
case "reminders":
    let done = DispatchSemaphore(value: 0)
    var found: [EKReminder] = []
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
    store.fetchReminders(matching: predicate) { items in
        found = items ?? []
        done.signal()
    }
    _ = done.wait(timeout: .now() + 60)
    emit(found.map(reminderJSON))
case "complete":
    guard args.count == 2 else { fail("usage: complete ID") }
    let item = reminder(Array(args)[1])
    item.isCompleted = true
    do { try store.save(item, commit: true) } catch { fail(error.localizedDescription) }
    emit(["ok": true])
case "reschedule":
    guard args.count == 3 else { fail("usage: reschedule ID WHEN") }
    let list = Array(args)
    let item = reminder(list[1])
    let when = date(list[2])
    item.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: when)
    item.alarms?.forEach { item.removeAlarm($0) }
    item.addAlarm(EKAlarm(absoluteDate: when))
    do { try store.save(item, commit: true) } catch { fail(error.localizedDescription) }
    emit(["ok": true])
default:
    fail("usage: onbox-eventkit access|request|events FROM TO|reminders|complete ID|reschedule ID WHEN")
}
