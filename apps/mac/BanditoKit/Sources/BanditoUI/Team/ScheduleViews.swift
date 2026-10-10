import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// One schedule in the details tab: its name and when it runs next, the switch, run now, and edit or delete.
struct ScheduleRow: View {
    var schedule: Schedule
    var onToggle: (Bool) -> Void
    var onRunNow: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var enabled: Bool

    init(
        schedule: Schedule, onToggle: @escaping (Bool) -> Void, onRunNow: @escaping () -> Void,
        onEdit: @escaping () -> Void, onDelete: @escaping () -> Void
    ) {
        self.schedule = schedule
        self.onToggle = onToggle
        self.onRunNow = onRunNow
        self.onEdit = onEdit
        self.onDelete = onDelete
        _enabled = State(initialValue: schedule.enabled)
    }

    var body: some View {
        let words = schedule.humanText(languageCode: ModelDescription.currentLanguageCode)
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BanditoPalette.peach)
                .frame(width: 32, height: 32)
                .background(BanditoPalette.peach.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                if let title = schedule.title {
                    Text(title)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    if let words {
                        Text(words)
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                    }
                } else {
                    Text(words ?? schedule.cron)
                        .font(BanditoFont.font(size: 12.5, weight: 500, mono: words == nil))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                }
                Text(schedule.prompt)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                if let next = schedule.nextRunAt {
                    Text(Self.nextText(ms: next))
                        .font(BanditoFont.text(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRunNow) {
                Image(systemName: "play.fill")
            }
            .banditoButton(.icon(size: 26, label: L10n.Inspector.runNow))
            .help(L10n.Inspector.runNow)
            Menu {
                Button(L10n.Schedule.edit) { onEdit() }
                Button(L10n.Common.delete, role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .banditoButton(.icon(size: 26, label: L10n.Schedule.more))
            .help(L10n.Schedule.more)
            .fixedSize()
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: enabled) { _, value in
                    if value != schedule.enabled { onToggle(value) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// `Next run: today at 15:30`, or the weekday or date of a later run.
    static func nextText(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let label = TeamTime.label(ms: ms)
        return Calendar.current.isDateInToday(date)
            ? L10n.Schedule.nextToday(time: label)
            : L10n.Schedule.nextLater(when: label)
    }
}

/// The schedule sheet: how often, at what time, what the agent does, and an optional name. Saves a new schedule or
/// changes an existing one; the daemon takes the cron expression and the server's time zone is the device's.
struct ScheduleEditor: View {
    var server: ServerModel
    var agentID: String
    var existing: Schedule?

    @Environment(\.dismiss) private var dismiss
    @State private var form: ScheduleForm
    @State private var error: UserFacingMessage?
    @State private var busy = false

    init(server: ServerModel, agentID: String, existing: Schedule?) {
        self.server = server
        self.agentID = agentID
        self.existing = existing
        var start = ScheduleForm()
        if let existing {
            start = ScheduleForm.reading(cron: existing.cron)
            start.title = existing.title ?? ""
            start.prompt = existing.prompt
        }
        _form = State(initialValue: start)
    }

    /// Whether «Добавить» / «Сохранить» may run: the form is complete and not too often, and nothing is saving.
    private var canSubmit: Bool {
        !busy && form.canSave && !form.tooOften(now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? L10n.Schedule.newTitle : L10n.Schedule.editTitle)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.Bandito.text)
            field(L10n.Schedule.name, hint: L10n.Schedule.titleHint) {
                TextField(L10n.Schedule.namePlaceholder, text: $form.title)
                    .banditoField()
                    // Return in the name adds the schedule, when it can be added.
                    .onSubmit { if canSubmit { save() } }
            }
            field(L10n.Schedule.repeat) {
                // One menu for the five choices: a row of segments does not fit 432 pt.
                BanditoSelect(
                    selection: $form.rhythm,
                    sections: [
                        SelectSection(options: ScheduleForm.Rhythm.allCases.map { rhythm in
                            SelectOption(value: rhythm, title: Self.rhythmTitle(rhythm))
                        })
                    ],
                    label: L10n.Schedule.repeat, placeholder: Self.rhythmTitle(form.rhythm))
            }
            rhythmDetails
            field(L10n.Inspector.promptLabel) {
                // Vertical TextField: Return adds a line, the field grows with the text.
                TextField(L10n.Inspector.promptPlaceholder, text: $form.prompt, axis: .vertical)
                    .accessibilityLabel(L10n.Inspector.promptLabel)
                    .banditoField()
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .lineLimit(3...10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if form.cron == nil {
                Text(L10n.Schedule.incomplete)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else if form.tooOften(now: Date()) {
                Text(L10n.Schedule.tooOften)
                    .font(BanditoFont.text(size: 12, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
            }
            if let error {
                UserFacingErrorView(message: error)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                    .banditoButton(.quiet())
                    .fixedSize()
                // Enter adds it, when the form is valid (a disabled button takes no Return).
                Button(existing == nil ? L10n.Inspector.addSchedule : L10n.Common.save) { save() }
                    .banditoButton(.signal())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .fixedSize()
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.Bandito.surface2)
    }

    @ViewBuilder
    private var rhythmDetails: some View {
        switch form.rhythm {
        case .every:
            field(L10n.Schedule.intervalLabel) {
                BanditoSelect(
                    selection: $form.step,
                    sections: [SelectSection(options: ScheduleForm.Step.all.map { step in
                        SelectOption(value: step, title: Self.stepTitle(step))
                    })],
                    label: L10n.Schedule.intervalLabel, placeholder: Self.stepTitle(form.step))
                    .frame(maxWidth: 220, alignment: .leading)
            }
        case .daily, .weekdays:
            field(L10n.Schedule.atLabel) { timePicker }
        case .days:
            field(L10n.Schedule.daysLabel) {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        DayChip(title: Self.dayTitle(day), on: form.weekdays.contains(day)) {
                            if form.weekdays.contains(day) {
                                form.weekdays.remove(day)
                            } else {
                                form.weekdays.insert(day)
                            }
                        }
                    }
                }
            }
            field(L10n.Schedule.atLabel) { timePicker }
        case .custom:
            field(L10n.Inspector.cronLabel, hint: L10n.Schedule.cronHint) {
                TextField("0 9 * * 1-5", text: $form.customCron)
                    .banditoField()
                    .font(BanditoFont.mono(size: 13, weight: 400))
            }
        }
    }

    private var timePicker: some View {
        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The hour and minute of the form, as a date for the picker.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: form.hour, minute: form.minute)) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                form.hour = parts.hour ?? form.hour
                form.minute = parts.minute ?? form.minute
            })
    }

    private func field<Content: View>(
        _ label: String, hint: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            content()
            if let hint {
                Text(hint)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard let cron = form.cron else { return }
        busy = true
        error = nil
        let title = form.titleOrNil
        let prompt = form.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = TimeZone.current.identifier
        Task {
            do {
                if let existing {
                    let titleChange: FieldChange<String> = title.map { .set($0) } ?? .clear
                    _ = try await server.updateSchedule(
                        existing.id, cron: cron, tz: zone, prompt: prompt, title: titleChange)
                } else {
                    _ = try await server.createSchedule(
                        agentId: agentID, cron: cron, tz: zone, prompt: prompt, title: title)
                }
                dismiss()
            } catch {
                self.error = UserFacingError.message(for: error)
                busy = false
            }
        }
    }

    static func rhythmTitle(_ rhythm: ScheduleForm.Rhythm) -> String {
        switch rhythm {
        case .every: L10n.Schedule.Rhythm.every
        case .daily: L10n.Schedule.Rhythm.daily
        case .weekdays: L10n.Schedule.Rhythm.weekdays
        case .days: L10n.Schedule.Rhythm.days
        case .custom: L10n.Schedule.Rhythm.custom
        }
    }

    static func stepTitle(_ step: ScheduleForm.Step) -> String {
        switch step {
        case .minutes(let n): L10n.Schedule.Step.minutes(count: n)
        case .hours(let n): L10n.Schedule.Step.hours(count: n)
        }
    }

    /// The short name of a weekday, by its cron number (0 is Sunday), in the app's language.
    static func dayTitle(_ day: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols.indices.contains(day) ? symbols[day] : "\(day)"
    }
}

/// A day of the week in the days choice: a capsule that is filled when the day is picked.
private struct DayChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(on ? Color.Bandito.text : Color.Bandito.text3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(on ? Color.Bandito.text.opacity(0.08) : Color.clear, in: Capsule())
                .overlay {
                    Capsule().stroke(on ? Color.Bandito.line : Color.Bandito.text.opacity(0.22),
                                     style: StrokeStyle(lineWidth: 1, dash: on ? [] : [4, 3]))
                }
                .contentShape(Capsule())
        }
        .banditoButton(.row(cornerRadius: 14, hoverOpacity: 0.04))
    }
}
