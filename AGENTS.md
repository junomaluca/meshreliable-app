# Agent instructions — MeshReliable iOS app

This is the MeshReliable fork of the Meshtastic Apple (iOS) app.

## ⚠️ CRITICAL INVARIANTS — DO NOT REGRESS

These are small, easy-to-silently-revert UI fixes. Before "cleaning up" these views,
read this first — each prevents a real, observed bug.

1. **Short Name field must look editable** — `Meshtastic/Views/Settings/UserConfig.swift`
   The Short Name `TextField` must **not** carry `.foregroundColor(.gray)`. That gray
   styling (it was applied twice) makes a fully-editable field render as if it were
   disabled/locked — users reported they "couldn't change the 4-digit name." Keep it
   styled like the Long Name field (no gray).

2. **Channel messages must not leak into DM threads** —
   `Meshtastic/Views/Messages/UserMessageList.swift`
   The per-user (DM) conversation `#Predicate` must keep **`&& $0.toUser != nil`**:
   ```swift
   ($0.fromUser?.num == userNum || $0.toUser?.num == userNum)
   && $0.toUser != nil   // <-- exclude channel/broadcast msgs (toUser == nil)
   && $0.isEmoji == false && $0.admin == false && $0.portNum != detectionSensorPortNum
   ```
   Without `toUser != nil`, a maluca/channel broadcast from a node (which has
   `toUser == nil`) matches `fromUser == userNum` and **leaks into that node's DM
   thread**. Group/channel messages belong in the channel view, not DMs.

3. **Auto-provisioning must stay once-per-node** —
   `Meshtastic/Services/MeshReliableDefaults.swift` + `AccessoryManager+Connect.swift`
   `applyAll` overwrites a node's whole config with defaults; it must run only on a node's
   **first** connect (guarded by `hasBeenProvisioned`/`markProvisioned`). Do NOT call
   `applyAll` on every connect — `needsProvisioning` returns true for any node still on the
   default MQTT broker, so re-running it silently clobbers the user's own config edits.
   (Known still-open issue: `applyLoRaConfig` hardcodes `region = .us`, wrong for 144 MHz
   VHF nodes — don't let provisioning force-set region on an already-configured node.)

## Build / deploy

- Workspace: `Meshtastic.xcworkspace`, scheme `Meshtastic`.
- Device build can hit `clang-stat-cache ... Resource temporarily unavailable` — that's
  the launchd `maxfiles` soft limit (256). Build from a shell with `ulimit -n 65536`.
- Install to a connected iPhone: build for `generic/platform=iOS` then
  `xcrun devicectl device install app --device <id> <Meshtastic.app>`.
- The app runs a **DebugHTTPServer** (used by `tests/full_7device_test.py` for delivery
  tracking) — only reachable while the app is **foregrounded** on the device.

See the firmware repo `docs/RELIABILITY_INVARIANTS.md` for the system-wide reliability
invariants (DM/group/media retry policies) this app pairs with.
