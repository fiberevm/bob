# Agent questions

Bob exposes `request_user_input` to all connected model providers, including Claude Code through Bob's MCP registry. The tool pauses execution until the user submits answers or dismisses the form. It uses the existing tool review boundary; answers never bypass Clef or high-risk confirmations.

## Interaction

- A Liquid Glass card appears immediately above the message composer (native glass on macOS 26, material fallback on older systems, opaque fallback with Reduce Transparency).
- Requests contain 1–3 questions, each with 2–3 labeled options and descriptions. The recommended option goes first with `(Recommended)` in its label.
- The client supplies **Other** with free-form input; no answer is preselected.
- Back/Next navigation retains answers. Submission requires a non-empty answer for every question.
- Pending requests and their in-progress form state belong to each chat, including when switching chats.
- Dismiss returns an explicit unanswered result, not consent. Stop cancels the request; sending a steering message dismisses it and lets the existing steering flow take over.
- Submitted answers appear in the transcript and are retained as trusted user input for subsequent safety review. Completed question/answer tool pairs can reconstruct those transcript entries during journal recovery. Unanswered interrupted forms are not automatically replayed on restart.

## Codex reference

The implementation follows the open-source Codex tool contract and response mapping:

- [Tool schema and normalization](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/request_user_input_spec.rs)
- [Request handler](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/request_user_input.rs)
- [Protocol types](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/request_user_input.rs)

Input has `questions: [{id, header, question, options: [{label, description}]}]`. Output has `answers: {question_id: {answers: [selected_label_or_custom_text]}}`.

Bob deliberately uses a blocking request in normal chats because it has no Codex collaboration-mode switch. It validates the documented question/choice limits, does not implement secret fields or automatic answer selection, and renders the interaction in SwiftUI rather than Codex's terminal UI.

## Validation

`swift test --filter UserInputTests` covers serialization, malformed requests, required answers, cancellation, stale/double callbacks, harness pause/resume, per-chat isolation, steering, composer preservation, and journal reconstruction.
