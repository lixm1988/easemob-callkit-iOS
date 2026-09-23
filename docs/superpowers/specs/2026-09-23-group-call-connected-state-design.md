# Group Call Connected-State Fix Design

## Goal

Restore group-call duration updates and invited-member waiting UI after migrating to `CallSignalingManager`, while preserving the behavior of inviting additional members during an active call.

## Confirmed Behavior

- When the first remote participant accepts the call, transition the call to `answering` and start the duration timer once.
- When a participant accepts through signaling, immediately set that participant's `waiting` state to `false` and refresh the existing stream view so its waiting overlay disappears.
- An RTC join also clears `waiting` as an idempotent fallback and binds the participant's RTC UID and canvas.
- When an invitation is rejected, canceled, or times out, remove that participant's waiting tile.
- Accepting, rejecting, or timing out an invitation sent during an active call must not restart, replace, or stop the call-duration timer.

## Selected Approach

Keep call-level and participant-level transitions separate within the existing manager extensions.

1. Participant callbacks update only the affected participant UI.
2. The call-level transition checks the previous call state and starts the duration timer only when entering `answering` for the first time.
3. Duration timer registration uses the server-assigned final `channelName`. If a provisional key was registered before call creation completed, replace it with the final key without retaining the provisional elapsed time.
4. RTC callbacks refresh the full `CallStreamView` state when clearing `waiting`; updating profile data alone is insufficient because it does not update the overlay visibility.

## Alternatives Considered

- Remove the waiting overlay only after RTC join: rejected because signaling acceptance is required to remove it immediately.
- Introduce a new group-call state machine: rejected for this fix because it expands compatibility risk and is unnecessary for the two regressions.

## Error and Race Handling

- Repeated accepted/RTC-joined callbacks are idempotent.
- A participant acceptance received after the call is already `answering` updates only that participant.
- Terminal participant states remove only the matching remote participant and leave the active call unchanged.
- UI refresh resolves both the currently presented multi-call controller and the manager-held controller where applicable.

## Verification

- Regression coverage must demonstrate that the provisional timer key no longer prevents duration updates after the server changes `callId/channelName`.
- Regression coverage must demonstrate that signaling acceptance refreshes an existing waiting stream view.
- Regression coverage must demonstrate that accepting an additional participant while already `answering` does not reset the duration timer.
- Regression coverage must demonstrate that a terminal participant state removes its waiting tile without ending the active call.
- Build the example workspace after tests.
