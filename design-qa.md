# Design QA

- Source visual truth: `/var/folders/9x/lvy5jhds1yj717dcc2zcq0p00000gn/T/TemporaryItems/NSIRD_screencaptureui_Lq6yU2/스크린샷 2026-09-12 오후 12.24.21.png`
- Implementation evidence: Codex Computer Use inline capture of `ListenUpRerecordQA2` in the completed-recording state
- Viewport: macOS desktop app window, approximately 900 × 700 CSS points
- Source pixels: 1808 × 1356 (@2x, approximately 904 × 678 points)
- Implementation pixels: 900 × 700 capture at the automation surface's normalized density
- State: completed microphone recording, waiting to start transcription

## Full-view comparison

The existing sidebar, title hierarchy, metadata, completion card, status message, OpenAI state, primary transcription CTA, typography, colors, spacing, radii, and system icons remain unchanged. The new neutral `녹음 다시하기` control appears in the existing secondary-action row between playback and folder access, so it does not compete with the blue primary CTA.

The source uses an informational audio-status banner while the implementation capture uses the existing low-input warning for the selected session. This is expected data-dependent state, not design drift. The QA build name in the title bar is also expected test-only chrome.

## Focused-region comparison

The secondary-action row is legible in the full-view captures, so an additional crop was not required. Button height, spacing, icon weight, label size, and neutral treatment match the adjacent controls.

## Findings

- No actionable P0, P1, or P2 visual differences.
- Typography: existing SwiftUI system typography and hierarchy are preserved.
- Spacing and layout rhythm: the third secondary button fits without wrapping or crowding at the reference window size.
- Colors and tokens: the new action uses the same neutral button treatment as playback and folder access.
- Image and icon fidelity: the existing SF Symbols style is preserved with `arrow.counterclockwise.circle`.
- Copy and content: `녹음 다시하기` is distinct from `새 녹음`, and its help/accessibility text explains that the prior recording is retained.

## Interaction verification

- Selecting `녹음 다시하기` started a new microphone recording immediately.
- The title `녹음 테스트`, purpose `강의`, and microphone input were retained.
- The previous session remained on disk; the retry created a separate session.
- Reopened sessions recover their parent save directory before retrying.
- System-audio sessions without a currently selected app return to setup with a clear instruction.
- Imported-file sessions do not show the retry-recording action.

## Comparison history

1. Initial implementation exposed the button correctly, but a reopened session with no restored root directory could not start a retry.
2. The retry flow was updated to recover the previous session's parent directory and input source, and to route missing system-audio app selection back to setup.
3. Post-fix interaction verification reached the active recording screen with the same recording configuration.

## Implementation checklist

- [x] Add retry action to the completed-recording screen.
- [x] Preserve the prior recording.
- [x] Reuse title, purpose, input source, and save location.
- [x] Handle reopened and system-audio sessions.
- [x] Verify layout and primary interaction.

final result: passed
