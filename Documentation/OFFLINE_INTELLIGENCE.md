# Shared offline shaping integration

Source version 1.0, build 2, October 14, 2026.

`IdeaShaper` now uses the shared `OfflineTextService` and pinned Qwen3.5 models. Settings persist the common model choice: 2B is the default, 4B is optional. Availability depends on the selected local model files, independently of Apple Intelligence settings. The parent build helper stages verified external model folders into `App/Resources/Models` and the sibling OfflineIntelligenceKit packages. No new model binaries are placed in the synced source workspace.

Generation uses deterministic sampling, a 2,048-token prompt cap, 512-token output cap, 4,096-token context cap, and cooperative 120-second deadline. The shared transaction rejects truncation, timeout, cancellation, or missing completion, and releases weights after each request. Leaving the editor cancels shaping; entering the background drains the shared service.

The complete response must decode as exactly `summary` and `phases`. Nested phases require exactly `title` and `hours`. Domain validation requires a nonempty single-line summary of at most 320 characters, 3–6 distinct phases, titles of 1–3 words and at most 28 characters, and 1–40 whole hours per phase. Invalid values are rejected rather than clamped into a schedule.

A successful response becomes a proposal. Its summary, phases, hours, total, and actual model provider remain visible until the user chooses **Use these phases** or **Discard**. Existing phases and booked blocks survive failed or discarded proposals. When logged time exists, the existing replacement confirmation preserves the actual proposal source. Size-template confirmations now preserve `.template` attribution. Historical `.appleIntelligence` metadata still decodes accurately; new plans record `.qwen2B` or `.qwen4B`.

Validation completed: XcodeGen project generation; Swift syntax checks for all changed app files; 24 new strict-schema and provider-restoration checks. The existing planner invariant harness reports 27,936/27,938 checks passing, with the same two pre-existing scheduling failures reproduced on the pre-integration domain baseline. Generic device compilation, signing, installation, and physical interaction are separate evidence owned by the parent task. Simulator activity remains on hold.

## Pre-existing planner issue

The baseline portable harness reports `fuzz217: not idempotent` and `fuzz330: not idempotent`, with 27,912/27,914 checks passing. Replanning the same input changes some block identities and, in one case, durations. The integration leaves `Planner.swift` unchanged (SHA-256 `7b0e3c0b71c8c405dd9677cd5d69022b9aeb9b471820e835f483a221391c2264`). The baseline was reconstructed in a temporary directory by omitting the new proposal-validation file and restoring the original three `ShapeSource` cases; all scheduling source stayed identical. After adding the 24 schema/provider checks, the same two scheduler failures remain and all new checks pass. They require a separate scheduler fix.
