"""Offline helpers for private desktop probes; never accesses the live desktop.

JSON CLI (stdin -> stdout):
  {"operation": "extent", "snapshot": ...}
  {"operation": "widths", "baseline": ..., "current": ...}
  {"operation": "restoration", "baseline": ..., "final": ..., "result": ...}

Snapshots use the native probe's layout/workspace/native/persisted/mode fields.
Width actions are proposals, not authorization: executors must revalidate HWND/PID,
workspace, membership, requested/effective width and transient maximize state after
focus and immediately before resize. Missing transient state blocks resize.
"""

import json
import sys


class IncompleteEvidence(ValueError):
    pass


def unique(items, description):
    matches = list(items)
    if len(matches) != 1:
        raise IncompleteEvidence(f"Expected one {description}; found {len(matches)}")
    return matches[0]


def workspace_key(snapshot):
    return snapshot["mode"]["Device"], snapshot["workspace"]["active_workspace"] - 1


def saved_workspace(snapshot, key=None):
    device, index = workspace_key(snapshot) if key is None else key
    return unique(
        (w["workspace"] for w in snapshot["persisted"]["workspaces"]
         if (w["monitor_device_name"], w["workspace_index"]) == (device, index)),
        "saved monitor/workspace",
    )


def native_window(snapshot, hwnd):
    native = unique((n for n in snapshot["native"] if n["Hwnd"] == hwnd), "native window")
    if native["Exists"] is not True or not native["Pid"]:
        raise IncompleteEvidence("Native window is absent or has no PID")
    if type(native["Minimized"]) is not bool:
        raise IncompleteEvidence("Missing native minimized state")
    return native


def active_members(snapshot, column):
    minimized = saved_workspace(snapshot)["minimized_windows"]
    members = []
    for hwnd in column["window_ids"]:
        native = native_window(snapshot, hwnd)
        if native["Minimized"] != (hwnd in minimized):
            raise IncompleteEvidence("Saved/native minimized states disagree")
        if not native["Minimized"]:
            members.append(hwnd)
    return members


def strip_extent(snapshot):
    saved = saved_workspace(snapshot)
    columns = snapshot["layout"]["columns"]
    if [c["window_ids"] for c in columns] != [c["windows"] for c in saved["columns"]]:
        raise IncompleteEvidence("Saved/layout membership disagrees")
    widths = [c["width_px"] for c in columns if active_members(snapshot, c)]
    return min(2**31 - 1, sum(widths) + max(0, saved["gap"]) * max(0, len(widths) - 1))


def width_restoration(baseline, current):
    if workspace_key(baseline) != workspace_key(current):
        raise IncompleteEvidence("Active monitor/workspace changed")
    before = saved_workspace(baseline)
    now = saved_workspace(current)
    layout = current["layout"]["columns"]
    groups = [c["windows"] for c in before["columns"]]
    if groups != [c["windows"] for c in now["columns"]] or groups != [c["window_ids"] for c in layout]:
        raise IncompleteEvidence("Column membership/order changed")
    actions = []
    for index, (saved, observed, effective) in enumerate(zip(before["columns"], now["columns"], layout)):
        target, requested = saved["width"], observed["width"]
        action = {"column": index, "members": saved["windows"], "target": target,
                  "requested": requested, "effective": effective["width_px"], "status": "unchanged"}
        if target != requested:
            action["status"] = "blocked"
            reason = None
            try:
                active = active_members(current, effective)
                for hwnd in saved["windows"]:
                    initial = native_window(baseline, hwnd)
                    final = native_window(current, hwnd)
                    if (initial["Pid"], initial["Minimized"]) != (final["Pid"], final["Minimized"]):
                        raise IncompleteEvidence("Window identity/minimized state changed")
                delta = target - effective["width_px"]
                if abs(target - requested) > 4:
                    reason = "Requested drift exceeds bounded rounding repair"
                elif not active:
                    reason = "Fully minimized column cannot be directionally focused"
                elif any(saved[k] != observed[k] or observed[k] != effective[k] for k in ("mode", "height_weights")):
                    reason = "Column mode/height weights changed"
                elif any(s.get("maximized_column", "unknown") is not None for s in (baseline, current)):
                    reason = "Transient maximized-column state is active or unknown"
                elif before["fullscreen_window"] is not None or now["fullscreen_window"] is not None:
                    reason = "Fullscreen state prevents safe resize"
                elif delta == 0:
                    reason = "Resize delta zero cannot restore requested intent"
                elif target < 100 or not -(2**31) <= delta < 2**31:
                    reason = "Requested target is outside the resize contract"
                else:
                    hwnd = active[0]
                    if effective["mode"]["type"] == "tabbed":
                        tab = effective["mode"]["active_idx"]
                        if type(tab) is not int or not 0 <= tab < len(effective["window_ids"]):
                            raise IncompleteEvidence("Invalid active tab index")
                        hwnd = effective["window_ids"][tab]
                        if hwnd not in active:
                            raise IncompleteEvidence("Active tab is minimized; refusing to change selection")
                    action.update(status="resize", hwnd=hwnd,
                                  pid=native_window(current, hwnd)["Pid"], delta=delta)
            except (KeyError, IncompleteEvidence) as error:
                reason = f"Incomplete evidence: {error}"
            if reason:
                action["reason"] = reason
        actions.append(action)
    return actions


def verdict(checks, missing=()):
    failed = [name for name, passed in checks if passed is not True]
    missing = list(missing)
    if not checks and not missing:
        missing.append("No checks supplied")
    state = "failed" if failed else "incomplete" if missing else "passed"
    return {"state": state, "failures": failed, "missing": missing}


def restoration(baseline, final, result):
    checks, missing = [], []

    def compare(name, observation):
        try:
            checks.append((name, observation()))
        except (KeyError, TypeError, IndexError, IncompleteEvidence) as error:
            missing.append(f"{name}: {error}")

    if final is None:
        missing.append("Final snapshot absent")
    else:
        compare("Active monitor/workspace restored", lambda: workspace_key(baseline) == workspace_key(final))
        for field in ("Device", "Width", "Height", "Hz", "Bits", "X", "Y", "Orientation", "FixedOutput", "Flags"):
            compare(f"Display {field} restored", lambda f=field: baseline["mode"][f] == final["mode"][f])
        for field in ("focused_column", "focused_window", "scroll_offset"):
            compare(f"Workspace {field} restored", lambda f=field: baseline["workspace"][f] == final["workspace"][f])
        compare("Foreground restored", lambda: baseline["foreground"] == final["foreground"])
        compare("Maximized column restored", lambda: baseline["maximized_column"] == final["maximized_column"])
        compare("Saved workspace set restored", lambda:
                sorted((w["monitor_device_name"], w["workspace_index"]) for w in baseline["persisted"]["workspaces"]) ==
                sorted((w["monitor_device_name"], w["workspace_index"]) for w in final["persisted"]["workspaces"]))
        try:
            workspaces = baseline["persisted"]["workspaces"]
        except KeyError:
            missing.append("Baseline saved workspaces absent")
            workspaces = []
        for entry in workspaces:
            key = entry["monitor_device_name"], entry["workspace_index"]
            for field in ("columns", "minimized_windows", "floating_windows", "fullscreen_window"):
                compare(f"Saved {key} {field} restored", lambda k=key, f=field:
                        saved_workspace(baseline, k)[f] == saved_workspace(final, k)[f])
        try:
            windows = baseline["native"]
        except KeyError:
            missing.append("Baseline native identities absent")
            windows = []
        if not windows:
            missing.append("No baseline native identities")
        for window in windows:
            hwnd = window["Hwnd"]
            compare(f"HWND {hwnd} identity/minimized state preserved", lambda h=hwnd:
                    (native_window(baseline, h)["Pid"], native_window(baseline, h)["Minimized"]) ==
                    (native_window(final, h)["Pid"], native_window(final, h)["Minimized"]))
    if result is None:
        missing.append("Executor result absent")
    else:
        for field, expected in (("ModeRestored", True), ("ScriptFailed", False), ("GuardExited", True)):
            compare(f"Executor {field}", lambda f=field, e=expected: result[f] is e)
        for stage in ("display", "widths", "focus", "scroll", "foreground", "snapshot", "preservation", "guard"):
            compare(f"Cleanup {stage} succeeded", lambda name=stage:
                    unique((s for s in result["CleanupStages"] if s["Name"] == name),
                           f"cleanup {name} result")["Succeeded"] is True)
    return verdict(checks, missing)


def acceptance(product, restored):
    return {"product": product, "restoration": restored,
            "passed": product["state"] == restored["state"] == "passed"}


def dispatch(request):
    operation = request["operation"]
    if operation == "extent":
        return {"total_width": strip_extent(request["snapshot"])}
    if operation == "widths":
        return {"actions": width_restoration(request["baseline"], request["current"])}
    if operation == "restoration":
        return restoration(request["baseline"], request.get("final"), request.get("result"))
    raise ValueError("Unknown operation")


if __name__ == "__main__":
    try:
        response = dispatch(json.load(sys.stdin))
    except (KeyError, TypeError, ValueError, IndexError) as error:
        print(json.dumps({"state": "incomplete", "error": str(error)}))
        raise SystemExit(2)
    print(json.dumps(response))
