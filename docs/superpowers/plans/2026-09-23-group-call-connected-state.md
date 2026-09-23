# Group Call Connected-State Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make group-call duration start exactly once with the final channel identifier, refresh waiting overlays as soon as signaling is accepted, and keep active-call invitations independent from call-level connection state.

**Architecture:** Add a small pure transition policy that decides whether an accepted participant is the first connection. Keep participant UI updates in the signaling/RTC callbacks, while one existing manager helper owns the one-time `answering` transition and timer registration. Preserve the existing UIKit, singleton, and CocoaPods structure.

**Tech Stack:** Swift 5, UIKit, XCTest-free Swift executable regression test, Xcode/xcodebuild, CocoaPods.

---

## File Map

- Create `Sources/EaseCallUIKit/Classes/CoreService/Implements/CallConnectionTransitionPolicy.swift`: pure, dependency-free decision for first connection versus an accepted participant joining an already active call.
- Create `Tests/CallConnectionTransitionPolicyTests.swift`: executable regression checks for the transition policy because the repository's shared scheme references a test target that is not present in the project.
- Modify `Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+Signaling.swift`: apply accepted and terminal participant changes, perform the one-time call transition, and register the correct controller timer.
- Modify `Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+RTC.swift`: use the same call transition as an RTC fallback and fully refresh stream items when clearing `waiting`.
- Modify `Sources/EaseCallUIKit/Classes/UI/Controllers/CallMultiViewController.swift`: stop registering duration timers while still dialing or immediately on the accept tap.

### Task 1: Define and test the one-time connection policy

**Files:**
- Create: `Tests/CallConnectionTransitionPolicyTests.swift`
- Create: `Sources/EaseCallUIKit/Classes/CoreService/Implements/CallConnectionTransitionPolicy.swift`

- [ ] **Step 1: Write the failing policy test**

```swift
import Foundation

@main
enum CallConnectionTransitionPolicyTests {
    static func main() {
        precondition(CallConnectionTransitionPolicy.shouldEnterAnswering(
            isAnswering: false,
            hasAcceptedParticipant: true
        ))
        precondition(!CallConnectionTransitionPolicy.shouldEnterAnswering(
            isAnswering: true,
            hasAcceptedParticipant: true
        ))
        precondition(!CallConnectionTransitionPolicy.shouldEnterAnswering(
            isAnswering: false,
            hasAcceptedParticipant: false
        ))
        print("CallConnectionTransitionPolicyTests passed")
    }
}
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
xcrun swiftc Tests/CallConnectionTransitionPolicyTests.swift -o /tmp/call-connection-policy-tests
```

Expected: compilation fails because `CallConnectionTransitionPolicy` does not exist.

- [ ] **Step 3: Add the minimal pure policy**

```swift
import Foundation

enum CallConnectionTransitionPolicy {
    static func shouldEnterAnswering(isAnswering: Bool, hasAcceptedParticipant: Bool) -> Bool {
        !isAnswering && hasAcceptedParticipant
    }
}
```

- [ ] **Step 4: Run the test to verify GREEN**

Run:

```bash
xcrun swiftc \
  Sources/EaseCallUIKit/Classes/CoreService/Implements/CallConnectionTransitionPolicy.swift \
  Tests/CallConnectionTransitionPolicyTests.swift \
  -o /tmp/call-connection-policy-tests && \
/tmp/call-connection-policy-tests
```

Expected: `CallConnectionTransitionPolicyTests passed` and exit code 0.

- [ ] **Step 5: Commit the policy and test**

```bash
git add Tests/CallConnectionTransitionPolicyTests.swift \
  Sources/EaseCallUIKit/Classes/CoreService/Implements/CallConnectionTransitionPolicy.swift
git commit -m "test: cover one-time call connection transition"
```

### Task 2: Separate participant acceptance from the call-level transition

**Files:**
- Modify: `Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+Signaling.swift:124-200`
- Modify: `Sources/EaseCallUIKit/Classes/UI/Controllers/CallMultiViewController.swift:87-169`
- Test: `Tests/CallConnectionTransitionPolicyTests.swift`

- [ ] **Step 1: Extend the regression test for repeated accepted callbacks**

Add repeated calls that assert an already-answering call never enters again:

```swift
for _ in 0..<3 {
    precondition(!CallConnectionTransitionPolicy.shouldEnterAnswering(
        isAnswering: true,
        hasAcceptedParticipant: true
    ))
}
```

- [ ] **Step 2: Run the test and verify it passes as a characterization check**

Run the Task 1 GREEN command.

Expected: `CallConnectionTransitionPolicyTests passed`.

- [ ] **Step 3: Prevent early timer registration in the multi-call controller**

Keep timer registration in `viewDidLoad` only when the actual call state is already `answering`, remove the unconditional caller registration from `setupNavigationState`, and remove registration from the `.accept` tap:

```swift
if state {
    if CallKitManager.shared.callInfo?.state == .answering {
        self.addCallTimer()
    }
    self.bottomView.isCallConnected = true
}
```

```swift
if self.role != .callee {
    self.navigationBar.subtitle = "calling".call.localize
}
```

- [ ] **Step 4: Make `answering` a one-time transition and register every controller type**

Update `updateCallStateFromParticipants` so it uses the policy, assigns state before UI reads it, stops setup timers, and registers the duration timer on the currently displayed controller (falling back to `callVC`):

```swift
func updateCallStateFromParticipants(call: CallInfo, state: CallState) {
    let shouldEnterAnswering = CallConnectionTransitionPolicy.shouldEnterAnswering(
        isAnswering: call.state == .answering,
        hasAcceptedParticipant: state == .answering
    )
    guard call.state != .answering || state == .answering else { return }
    guard shouldEnterAnswering || state != .answering else { return }

    call.state = state
    guard shouldEnterAnswering else { return }

    self.stopInvitationSignalTimer(callId: call.callId)
    self.stopConfirmBuildConnectionTimer(callId: call.callId)
    self.callStartTimerStop(callId: call.callId)

    let currentController = UIViewController.currentController
    (currentController as? Call1v1AudioViewController)?.addCallTimer()
    (currentController as? Call1v1VideoViewController)?.addCallTimer()
    (currentController as? CallMultiViewController)?.addCallTimer()
    if currentController !== self.callVC {
        (self.callVC as? Call1v1AudioViewController)?.addCallTimer()
        (self.callVC as? Call1v1VideoViewController)?.addCallTimer()
        (self.callVC as? CallMultiViewController)?.addCallTimer()
    }
}
```

For group calls, do not regress an already-answering call to `dialing` or `ringing` when a later participant snapshot contains no accepted remote participant.

- [ ] **Step 5: Refresh accepted participants immediately**

For each `.accepted` participant, obtain or create the item, set `waiting = false`, and refresh an existing canvas directly:

```swift
let item: CallStreamItem
if let existing = self.itemsCache[participant.userId] {
    item = existing
} else {
    item = CallStreamItem(
        userId: participant.userId,
        index: self.itemsCache.count + 1,
        isExpanded: false
    )
    self.itemsCache[participant.userId] = item
}
item.waiting = false
self.canvasCache[participant.userId]?.updateItem(item)
```

Retain `updateWithItems()` for genuinely new or removed tiles. Terminal states remove only their matching participant; they do not change an already-answering call.

- [ ] **Step 6: Use the common transition after local accept succeeds**

Replace the direct `self.callInfo?.state = .answering` in the new signaling accept completion with:

```swift
self.updateCallStateFromParticipants(call: call, state: .answering)
```

- [ ] **Step 7: Run policy tests and Swift syntax/build checks**

Run the Task 1 GREEN command, then:

```bash
xcodebuild \
  -workspace Example/EaseCallUIKit.xcworkspace \
  -scheme EaseCallUIKit-Example \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: policy test exits 0 and the example build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit signaling and controller changes**

```bash
git add Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+Signaling.swift \
  Sources/EaseCallUIKit/Classes/UI/Controllers/CallMultiViewController.swift
git commit -m "fix: start group call duration on first acceptance"
```

### Task 3: Make RTC join an idempotent UI fallback

**Files:**
- Modify: `Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+RTC.swift:303-390`
- Test: `Tests/CallConnectionTransitionPolicyTests.swift`

- [ ] **Step 1: Route the caller's first RTC join through the common transition**

Replace the direct caller assignment with a main-thread call to the same transition helper:

```swift
if call.callerId == ChatClient.shared().currentUsername ?? "" {
    self.performRTCUIUpdate {
        self.updateCallStateFromParticipants(call: call, state: .answering)
    }
}
```

Change the helper access from `private` to file-module internal so the RTC extension can call it.

- [ ] **Step 2: Fully refresh waiting UI on RTC join**

Replace both `updateUserInfo(newItem:)` calls after `item.waiting = false` with `updateItem(_:)`:

```swift
streamView.updateItem(item)
```

```swift
self.canvasCache[first.userId]?.updateItem(first)
```

- [ ] **Step 3: Run all available verification**

Run the policy test executable and full example workspace build from Task 2.

Expected: policy test exits 0 and build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Inspect the focused diff**

```bash
git diff --check
git diff -- Sources/EaseCallUIKit/Classes/CoreService/Implements/CallConnectionTransitionPolicy.swift \
  Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+Signaling.swift \
  Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+RTC.swift \
  Sources/EaseCallUIKit/Classes/UI/Controllers/CallMultiViewController.swift \
  Tests/CallConnectionTransitionPolicyTests.swift
```

Expected: no whitespace errors; no generated CocoaPods, workspace, storyboard, or unrelated user files appear in the diff.

- [ ] **Step 5: Commit the RTC fallback**

```bash
git add Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+RTC.swift
git commit -m "fix: refresh group participant after RTC join"
```

### Task 4: Manual two-client acceptance checks

**Files:**
- No file changes.

- [ ] **Step 1: Verify initial group-call acceptance**

Start a group call from account A to account B. Confirm B's signaling acceptance removes B's waiting overlay on A and the duration starts at `00:00:00` without including ringing time.

- [ ] **Step 2: Verify an in-call invitation acceptance**

While A and B remain connected, invite account C. Confirm C's tile begins waiting, acceptance removes only C's overlay, and the existing duration continues without resetting.

- [ ] **Step 3: Verify an in-call invitation timeout**

Invite account D and let the invitation time out. Confirm D's waiting tile is removed and the A/B/C call and duration continue.

- [ ] **Step 4: Verify RTC fallback**

Delay or reorder signaling/RTC delivery if the test environment permits. Confirm an RTC join clears the waiting overlay even if the accepted UI refresh was missed.
