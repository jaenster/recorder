import Foundation
import FoundationModels

@available(macOS 26.0, *)
enum Summarizer {
    /// Run Apple Intelligence's on-device LanguageModel over a transcript and
    /// return a markdown-formatted meeting summary with action items.
    /// Returns nil if the model isn't available on this machine.
    static func summarize(transcript: String) async throws -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let instructions = """
        You are summarizing a recorded conversation. The transcript is speaker-labeled:
        lines starting with 'ME:' are the user; lines starting with 'THEM:' are the other party.

        Produce a tight markdown summary in this exact shape:

        ## Summary
        2–4 sentences. Plain English. No fluff.

        ## Decisions
        - …
        - …
        (Omit this section entirely if no clear decisions were made.)

        ## Action items
        - **ME**: …
        - **THEM**: …
        (Only items the speaker explicitly committed to. Skip if none.)

        ## Open questions
        - …
        (Skip if none.)

        Do not invent items that weren't in the transcript. If the transcript is too short
        or contains only filler, say "Nothing substantive in this recording." and stop.
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: transcript)
        return response.content
    }
}
