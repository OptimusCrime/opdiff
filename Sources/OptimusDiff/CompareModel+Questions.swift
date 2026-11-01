import AppKit
import DiffCore
import SwiftUI

/// Lines the user is about to ask Claude about.
struct QuestionDraft: Identifiable {
    let id = UUID()
    let fileID: String
    let range: ClosedRange<Int>
    let split: Bool
    /// e.g. "src/app.swift:12-20"
    let reference: String
    /// The lines as a diff, shown in the sheet.
    let preview: String
}

extension CompareModel {
    // MARK: Questions about lines

    /// Opens the question sheet for the selected lines (or the right-clicked row).
    func beginQuestion(fallback: (fileID: String, index: Int, split: Bool)? = nil) {
        guard let (file, rows) = rowsToCopy(fallback: fallback), !rows.isEmpty else {
            NSSound.beep()
            return
        }
        questionDraft = QuestionDraft(
            fileID: file.id, range: rows.startIndex...(rows.endIndex - 1), split: splitView,
            reference: DiffCopy.reference(rows, in: file),
            preview: DiffCopy.text(rows, asDiff: true))
    }

    func askQuestion(_ draft: QuestionDraft, question rawQuestion: String, command rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo, !command.isEmpty, !question.isEmpty, let file = file(id: draft.fileID) else { return }
        let rows = rows(of: file, split: draft.split)
        guard draft.range.upperBound < rows.count else { return }

        var lines: [DiffLine] = []
        for row in rows[draft.range] {
            switch row {
            case .hunk: break
            case .line(let line): lines.append(line)
            case .pair(let old, let new):
                if let old, let new, old == new { lines.append(old) } else { lines += [old, new].compactMap { $0 } }
            }
        }
        let newNumbers = lines.filter { $0.kind != .deletion }.compactMap(\.newNumber)
        let oldNumbers = lines.compactMap(\.oldNumber)
        let (side, numbers): (AnnotationSide, [Int]) = newNumbers.isEmpty ? (.old, oldNumbers) : (.new, newNumbers)
        guard let low = numbers.min(), let high = numbers.max() else { return }

        rememberClaudeCommand(command)
        let uid = UUID().uuidString
        let key = reviewKey
        questions.append(
            Annotation(
                file: file.path, side: side, startLine: low, endLine: high, kind: .question,
                comment: "", question: question, uid: uid))
        pendingQuestionIDs.insert(uid)
        ReviewStore.saveQuestions(questions, key: key)
        rebuildAnnotationLayouts()

        let context = ReviewContext(
            base: base, head: head, mergeBase: mergeBase,
            includesWorkingTree: effectiveUncommitted, commitCount: commits.count, focus: "")
        let prompt = QuestionPrompt.build(file: file, selected: lines, question: question, context: context)
        let run = ClaudeReviewRun(command: command, directory: repo, prompt: prompt, schema: AnswerSchema.json)
        questionRuns[uid] = run
        Task {
            var answer: String?
            do {
                answer = try await Task.detached(priority: .userInitiated) { try run.runAnswer() }.value.answer
            } catch is CancellationError {
                answer = nil
            } catch {
                answer = "⚠️ Couldn't get an answer: \(error.localizedDescription)"
            }
            finishQuestion(uid: uid, key: key, answer: answer)
        }
    }

    /// Store the answer (nil: cancelled, so drop the question).
    private func finishQuestion(uid: String, key: String, answer: String?) {
        questionRuns[uid] = nil
        pendingQuestionIDs.remove(uid)
        let isCurrent = key == reviewKey
        var list = isCurrent ? questions : ReviewStore.loadQuestions(key: key)
        if let answer, let i = list.firstIndex(where: { $0.uid == uid }) {
            list[i].comment = answer
        } else {
            list.removeAll { $0.uid == uid }
        }
        ReviewStore.saveQuestions(list, key: key)
        if isCurrent {
            questions = list
            rebuildAnnotationLayouts()
        }
    }

    func isPending(_ annotation: Annotation) -> Bool {
        annotation.uid.map(pendingQuestionIDs.contains) ?? false
    }

    func cancelQuestion(_ annotation: Annotation) {
        guard let uid = annotation.uid else { return }
        questionRuns[uid]?.cancel()
    }

    func removeQuestion(_ annotation: Annotation) {
        guard let uid = annotation.uid else { return }
        questionRuns[uid]?.cancel()
        questions.removeAll { $0.uid == uid }
        ReviewStore.saveQuestions(questions, key: reviewKey)
        rebuildAnnotationLayouts()
    }
}
