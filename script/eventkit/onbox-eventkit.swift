// onbox-eventkit: reads the Mac's Calendar and Reminders through EventKit, and
// Mail through its scripting interface, and prints JSON, so onbox can use them
// without any cloud sign-in. Built on demand by onbox (see
// app/models/mac_event_kit.rb). One binary, so macOS keeps one set of
// permissions for it.
//
//   onbox-eventkit access                      -> {"calendar": "...", "reminders": "..."}
//   onbox-eventkit request [calendar|reminders|mail]
//                                              -> asks macOS for access (calendar and
//                                                 reminders when none is named), then as access
//   onbox-eventkit mail-access                 -> {"mail": "..."}; launches Mail if needed
//   onbox-eventkit events FROM TO              -> [event]   (ISO 8601 times)
//   onbox-eventkit reminders                   -> [reminder] (incomplete only)
//   onbox-eventkit complete ID                 -> {"ok": true}
//   onbox-eventkit reschedule ID WHEN          -> {"ok": true}
//   onbox-eventkit mail-unread                 -> [{message_id, received, junk}] (unread, all inboxes)
//   onbox-eventkit mail-messages ID...         -> [message] (found in an inbox or archive)
//   onbox-eventkit mail-reply ID TEXT          -> {"ok": true}; sends, in the thread, and marks it read
//   onbox-eventkit mail-archive ID             -> {"ok": true}; marks it read, moves it to the account's archive
//   onbox-eventkit mail-read ID                -> {"ok": true}
import AppKit
import CoreServices
import EventKit
import Foundation
import OSAKit

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


// Mail. Its scripting interface is reached in-process through OSAKit, so
// macOS asks for (and remembers) permission for this helper, not a shell.
let mailBundle = "com.apple.mail"

func launchMail() {
    if NSRunningApplication.runningApplications(withBundleIdentifier: mailBundle).isEmpty,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundle) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 30)
    }
    for _ in 0..<40 where NSRunningApplication.runningApplications(withBundleIdentifier: mailBundle).isEmpty {
        Thread.sleep(forTimeInterval: 0.5)
    }
}

func mailAccess(ask: Bool) -> String {
    launchMail()
    let target = NSAppleEventDescriptor(bundleIdentifier: mailBundle)
    let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    switch status {
    case 0: return "granted"
    case -1743: return "denied"
    case -1744: return "not_determined"
    case -600: return "mail_not_running"
    default: return "unknown (\(status))"
    }
}

// Runs a JavaScript for Automation script against Mail. The arguments go in
// as JSON, so no value is ever spliced into code; the script returns JSON.
func mailScript(_ body: String, _ args: [Any]) -> Any {
    launchMail()
    let argsJSON = String(data: try! JSONSerialization.data(withJSONObject: args, options: []), encoding: .utf8)!
    let source = """
    const Mail = Application("com.apple.mail");
    const args = \(argsJSON);
    // The account's archive: Archive (iCloud, most IMAP), or All Mail (Gmail).
    const archiveOf = (account) => {
      const candidates = [
        () => account.mailboxes.byName("Archive"),
        () => account.mailboxes.byName("[Gmail]").mailboxes.byName("All Mail"),
        () => account.mailboxes.byName("[Google Mail]").mailboxes.byName("All Mail"),
        () => account.mailboxes.byName("All Mail"),
      ];
      for (const candidate of candidates) {
        try { const box = candidate(); box.name(); return box; } catch (e) {}
      }
      return null;
    };
    // A message by its Message-ID: the inboxes first, then each archive.
    const find = (id) => {
      const inInbox = Mail.inbox.messages.whose({messageId: id})();
      if (inInbox.length) return inInbox[0];
      for (const account of Mail.accounts()) {
        const box = archiveOf(account);
        if (!box) continue;
        const found = box.messages.whose({messageId: id})();
        if (found.length) return found[0];
      }
      throw new Error("no message " + id + " in Mail's inboxes or archives");
    };
    JSON.stringify((() => { \(body) })());
    """
    let script = OSAScript(source: source, language: OSALanguage(forName: "JavaScript"))
    var error: NSDictionary?
    guard let result = script.executeAndReturnError(&error), let text = result.stringValue else {
        let message = error?[OSAScriptErrorMessageKey] as? String ?? error?.description ?? "no result"
        fail("Mail: \(message)")
    }
    return try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!, options: [.fragmentsAllowed])
}

func mailUnread() -> Any {
    mailScript("""
    const unread = Mail.inbox.messages.whose({readStatus: false});
    const ids = unread.messageId(), received = unread.dateReceived(), junk = unread.junkMailStatus();
    return ids.map((id, i) => ({message_id: id, received: received[i].toISOString(), junk: junk[i]}));
    """, [])
}

func mailMessages(_ ids: [String]) -> Any {
    mailScript("""
    const out = [];
    for (const id of args) {
      let m;
      try { m = find(id); } catch (e) { continue; }
      const box = m.mailbox();
      out.push({
        message_id: m.messageId(),
        subject: m.subject(),
        from: m.sender(),
        reply_to: m.replyTo(),
        to: m.toRecipients().map(r => r.address()).join(", "),
        cc: m.ccRecipients().map(r => r.address()).join(", "),
        received: m.dateReceived().toISOString(),
        account: box.account().name(),
        mailbox: box.name(),
        read: m.readStatus(),
        headers: (m.allHeaders() || "").slice(0, 20000),
        body: (m.content() || "").slice(0, 50000),
      });
    }
    return out;
    """, ids)
}

func mailAct(_ action: String, _ id: String, _ text: String = "") -> Any {
    mailScript("""
    const [action, id, text] = args;
    let m;
    try { m = find(id); } catch (e) {
      if (action === "read") return {ok: true, missing: true}; // gone from Mail: nothing left to mark
      throw e;
    }
    if (action === "reply") {
      const reply = Mail.reply(m, {openingWindow: false, replyToAll: false});
      reply.content = text;
      delay(1);
      reply.send();
      m.readStatus = true;
    } else if (action === "archive") {
      const box = archiveOf(m.mailbox().account());
      if (!box) throw new Error("no Archive or All Mail mailbox in " + m.mailbox().account().name());
      m.readStatus = true;
      Mail.move(m, {to: box});
    } else {
      m.readStatus = true;
    }
    return {ok: true};
    """, [action, id, text])
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "access":
    emit(["calendar": accessName(.event), "reminders": accessName(.reminder)])
case "request":
    switch args.dropFirst().first {
    case "mail": emit(["mail": mailAccess(ask: true)])
    case "calendar": requestAccess(.event)
    case "reminders": requestAccess(.reminder)
    default:
        requestAccess(.event)
        requestAccess(.reminder)
    }
    if args.dropFirst().first != "mail" { emit(["calendar": accessName(.event), "reminders": accessName(.reminder)]) }
case "mail-access":
    emit(["mail": mailAccess(ask: false)])
case "mail-unread":
    emit(mailUnread())
case "mail-messages":
    emit(mailMessages(Array(args.dropFirst())))
case "mail-reply":
    guard args.count == 3 else { fail("usage: mail-reply ID TEXT") }
    let list = Array(args)
    emit(mailAct("reply", list[1], list[2]))
case "mail-archive", "mail-read":
    guard args.count == 2 else { fail("usage: \(args.first!) ID") }
    let list = Array(args)
    emit(mailAct(list[0] == "mail-archive" ? "archive" : "read", list[1]))
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
    fail("usage: onbox-eventkit access|request [KIND]|events FROM TO|reminders|complete ID|reschedule ID WHEN|mail-access|mail-unread|mail-messages ID...|mail-reply ID TEXT|mail-archive ID|mail-read ID")
}
