# Codex risk guidance provenance

Source: https://github.com/openai/codex
Revision: e7de1f444089c29ac002e3df08d940f6de8a2613
Retrieved: October 16, 2026
License: Apache-2.0 (included as Codex-LICENSE, with upstream Codex-NOTICE)

CodexGuardianPolicy.md, CodexGuardianTemplate.md, and CodexGuardianClassifier.md
are unmodified copies of codex-rs/prompts/templates/guardian/policy.md,
policy_template.md, and classifier_instructions.md at that revision.

CodexGuardianCompact.md is Bob's risk-only adaptation of the intrinsic-risk
taxonomy and browser/computer guidance for the local 9B decision model. The
unmodified originals remain bundled for comparison and attribution. Bob uses
one typed Clef risk question instead of generated JSON and describes its own execution
boundaries. The nonblocking/predictive classifier instructions are not executed.
Bob scores every agent tool call. Clef returns only low, medium, high or critical
risk; it does not score authorization, classify concerns or choose allow/deny.
Bob automatically executes low- and medium-risk calls and asks for human
confirmation for high and critical scores, regardless of confidence. The resulting execution route is
recorded with the risk probabilities and input digest. Historical review records
remain readable. Bob does not claim Codex reviewer model quality or behavioral
parity. Unavailable, malformed, oversized or timed-out scoring blocks execution.
Scoring has an 8192-token input limit and a 30-second deadline. Clef's allocator cache is capped at 256 MiB to avoid retaining large
prefill temporaries between tool calls.
