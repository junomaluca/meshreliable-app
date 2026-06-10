# CLAUDE.md

Agent instructions live in **`AGENTS.md`**. Read it.

## ⚠️ DO NOT REGRESS (two small, easily-reverted UI fixes)

1. **`Meshtastic/Views/Settings/UserConfig.swift`** — the Short Name `TextField` must
   NOT have `.foregroundColor(.gray)`; that made an editable field look disabled.
2. **`Meshtastic/Views/Messages/UserMessageList.swift`** — the per-user message
   `#Predicate` must keep **`&& $0.toUser != nil`**, or channel/broadcast messages leak
   into DM threads.

See `AGENTS.md` for details, and the firmware repo's `docs/RELIABILITY_INVARIANTS.md`
for the system-wide reliability invariants.
