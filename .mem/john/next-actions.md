# Next Actions

## Immediate: M5 — Snapshots
### M5.1 — Create snapshot
- POST .../snapshots -> vm.pause(), saveMachineStateTo(url), vm.resume()
- Save to machines/{id}/snapshots/{snapId}/state.vzsave
- Return BentosSnapshot JSON with size from file

### M5.2 — Restore snapshot
- POST .../snapshots/{sid}/restore -> machine must be stopped
- Rebuild VZ config, restoreMachineStateFrom(url)

### M5.3 — List snapshots
- GET .../snapshots -> enumerate snapshot directories

### M5.4 — Delete snapshot
- DELETE .../snapshots/{sid} -> remove snapshot directory

## After M5
- All milestones complete. Head A's plan is done.
- End-to-end validation needs M2 artifacts (kernel + rootfs).
- Contract source of truth: lib/bentos_vmm/lib/src/
