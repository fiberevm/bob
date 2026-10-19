# Goal

Build a Mac-native version of Codex that becomes the best developer harness for Mac users.

The app will bring together:

- Built-in code review.
- Computer use.
- An integrated browser the agent can navigate, inspect, and interact with while the user follows along.
- An integrated editor view.
- An integrated terminal for interactive commands, running servers, and agent output.
- Git and worktrees for isolated tasks, staging, commits, branches, and pull request workflows.
- Agent controls to inspect tool calls, interrupt, steer, and resume work.
- Concurrent chats within a project, with independent streaming, approvals, and cancellation. Clef scores only intrinsic risk: low and medium run automatically; high and critical ask for human confirmation.
- Agent runs continue until completion, user cancellation, or an execution error, with no fixed step, turn, or tool-call cap.
- Checkpoints and undo to review and roll back agent edits.
- Persistent sessions that restore projects and conversations after quitting or crashing.
- Mac ergonomics, including keyboard navigation, a command palette, multiple windows, and accessibility.

Deliver a cohesive, native Mac experience that makes these capabilities feel like one developer workspace.

Each project gets its own native Mac window, with independent sessions, editor state, Git context, terminal, and agent activity. Opening another project opens or focuses that project's window; projects are not grouped as folders in a shared session sidebar.

## Implementation constraints

- Build the application entirely in Swift using native macOS frameworks, including SwiftUI and AppKit.
- Build and own the agent harness in Swift for direct API providers. Claude subscription chats use the official, unmodified Claude Code binary as their model and agent backend, with Bob exposing its reviewed Swift tools through MCP. Keep the interface, tool execution, permissions, journaling, and cancellation native. Do not wrap Codex CLI, Pi, or other agent runtimes for chat inference or tools. The Usage panel may query the installed Codex client's read-only account-status RPCs after verifying the selected account matches; it must not create threads, run tools, change sign-ins, or export credentials.
- Connect models through their supported APIs and authentication flows, using Claude Code for Claude subscriptions, with an OpenAI-compatible interface for additional providers and local model servers.
- Score every agent tool call with local Clef before execution, using an attributed, pinned adaptation of Codex's intrinsic-risk taxonomy. Ask only for risk, with no authorization, concern or allow/deny classification. Derive automatic execution for low and medium risk and human confirmation for high and critical risk. Keep original user requests separate from untrusted evidence, record scores durably, block unavailable or failed scoring, and retain current-target checks. Run agent shell commands directly on the user's Mac with normal user file permissions, network access, home directory and tool path; do not wrap them in a workspace sandbox.
- Use native views throughout the application; do not use Electron, an embedded web frontend, or a JavaScript application runtime.
- Use native WebKit for the Browser panel's web content. Keep the browser controls and agent orchestration in Swift, with a separate browser session per project.
- Delegate bounded browser navigation goals from the main model to local Clef. Select concrete actions from fresh observed page controls, use only supplied form text, retain every action's review and approvals, and return control on uncertainty or a step limit. Record delegated steps durably and preserve cancellation and recovery without replay.
- Build desktop computer use in Swift with ScreenCaptureKit, Accessibility, and Core Graphics. Scope capture and control to approved apps and windows, return screenshots to the model, and support immediate cancellation and user takeover. Keep app access revocable and separate from macOS system permissions.
- Keep the interface limited to task content, essential controls, and actionable status. Omit marketing copy, decorative onboarding, repeated labels, and empty sections.
- Fade scrolling lists into their top and bottom edges only while content extends beyond the viewport. Keep end items fully readable and respect Reduce Transparency.
- Keep the single-line composer floating above the bottom of every chat, including an empty chat, as a native Liquid Glass capsule with 16-point outer spacing. Let the conversation scroll beneath it while reserving enough space to keep the latest content and approvals accessible. Use a material fallback on older macOS and an opaque surface for Reduce Transparency. Put a circular Send control on the right and preserve the send animation and keyboard shortcuts. Reuse the selected empty session when starting a new chat. Put Open Project in the File menu and Settings in the Bob menu.
- Put the provider-grouped model dropdown and effort selector in a compact colored status bar across the bottom of the window, alongside project, branch, selected chat, active work, and Usage with real account quota percentages, reset times, and selected-chat details. Scope activity and metrics to the selected chat. Show context fill as an unlabeled progress bar with a detailed popover, distinguishing Bob's local context budget from provider-reported windows. Show cumulative input ↑ and output ↓ tokens for the chat, preserving totals through compaction and restarts. Omit idle “Ready” status. Keep catalogs shared and persistent, save effort per chat, and send only supported effort values to the provider. Keep the resizable workspace sidebar always open and omit unused space above the chat and editor.
- Use consistent 16-point chat padding. Align user messages to the right in bubbles that animate from the composer, respecting Reduce Motion. Omit speaker labels. Combine consecutive tool calls into compact, expandable activity groups with stable ordering, live summaries, visible failures, and access to every call's input and output. Visible conversation messages separate groups.
- Keep the agent chat visible while a separate, resizable right panel hosts tabs opened on demand by the user or agent. Support file tabs plus Plan, Changes, Terminal, Browser, Computer, and an interactive iOS Simulator; provide add and close controls instead of a fixed set of tabs. Plan renders detailed Markdown written and updated by the AI, persists per chat, and preserves each chat's plan during concurrent work. Selecting another file replaces the current editor tab when it has no unsaved edits; otherwise preserve its buffer in a separate tab. Keep file browsing inside editor tabs, and preserve separate editor buffers and browser pages when switching chats or tabs. Protect unsaved edits when closing tabs.
- Give the native editor syntax highlighting, line numbers, a total line count, and horizontal scrolling without wrapping source lines.
- Never display worktrees or worktree management controls in the editor.
- Browse project files in an indented, expandable tree. Reveal folder contents inline, load them on demand, and preserve expansion state without navigating away from the tree.
- Follow the macOS system appearance with fully supported light and dark themes. Combine Notion's calm, document-like surfaces with Linear's compact controls, precise spacing, and restrained color.
- Prioritize fast startup, responsive interactions, a low memory footprint, and low idle CPU and energy use.
- Measure performance throughout development, including memory growth during long agent sessions and when working with large repositories.
