import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

import desktop_acceptance as acceptance


def snapshot(groups=((1,), (2, 3)), minimized=()):
    columns = [{"windows": list(group), "width": 500,
                "mode": {"type": "vertical"}, "height_weights": [1 / len(group)] * len(group)}
               for group in groups]
    saved = {"columns": columns, "minimized_windows": list(minimized), "gap": 10,
             "fullscreen_window": None, "floating_windows": []}
    return {
        "mode": {"Device": "test-monitor", "Width": 1920, "Height": 1080,
                 "Hz": 60, "Bits": 32, "X": 0, "Y": 0, "Orientation": 0, "FixedOutput": 0, "Flags": 0},
        "workspace": {"active_workspace": 1, "focused_column": 0, "focused_window": 0, "scroll_offset": 0},
        "layout": {"columns": [{"window_ids": c["windows"], "width_px": c["width"],
                                "mode": c["mode"], "height_weights": c["height_weights"]} for c in columns]},
        "native": [{"Hwnd": hwnd, "Pid": hwnd + 100, "Exists": True, "Minimized": hwnd in minimized}
                   for group in groups for hwnd in group],
        "persisted": {"workspaces": [{"monitor_device_name": "test-monitor", "workspace_index": 0, "workspace": saved}]},
        "foreground": 1,
        "maximized_column": None,
    }


def executor_result():
    return {"ModeRestored": True, "ScriptFailed": False, "GuardExited": True,
            "CleanupStages": [{"Name": name, "Succeeded": True} for name in
                              ("display", "widths", "focus", "scroll", "foreground", "snapshot", "preservation", "guard")]}


class ExtentTests(unittest.TestCase):
    def test_mixed_columns(self):
        self.assertEqual(acceptance.strip_extent(snapshot(minimized=(1, 2))), 500)

    def test_all_minimized_and_empty(self):
        self.assertEqual(acceptance.strip_extent(snapshot(minimized=(1, 2, 3))), 0)
        self.assertEqual(acceptance.strip_extent(snapshot(groups=())), 0)

    def test_gap_only_between_active_columns(self):
        s = snapshot(groups=((1,), (2,), (3,)), minimized=(2,))
        acceptance.saved_workspace(s)["gap"] = 20
        self.assertEqual(acceptance.strip_extent(s), 1020)

    def test_negative_gap_and_saturated_extent_match_engine(self):
        s = snapshot()
        acceptance.saved_workspace(s)["gap"] = -5
        self.assertEqual(acceptance.strip_extent(s), 1000)
        s["layout"]["columns"][0]["width_px"] = 2**31 - 1
        self.assertEqual(acceptance.strip_extent(s), 2**31 - 1)

    def test_missing_dead_duplicate_and_unknown_native_are_incomplete(self):
        for mutation in (lambda s: s["native"].pop(),
                         lambda s: s["native"].append(s["native"][0]),
                         lambda s: s["native"][0].update(Exists=False),
                         lambda s: s["native"][0].update(Minimized=None)):
            s = snapshot()
            mutation(s)
            with self.assertRaises(acceptance.IncompleteEvidence):
                acceptance.strip_extent(s)

    def test_saved_native_disagreement_is_incomplete(self):
        s = snapshot()
        s["native"][0]["Minimized"] = True
        with self.assertRaises(acceptance.IncompleteEvidence):
            acceptance.strip_extent(s)

    def test_workspace_identity_includes_monitor(self):
        s = snapshot()
        other = copy.deepcopy(s["persisted"]["workspaces"][0])
        other["monitor_device_name"] = "other-monitor"
        other["workspace"]["gap"] = 99
        s["persisted"]["workspaces"].insert(0, other)
        self.assertEqual(acceptance.strip_extent(s), 1010)
        s["persisted"]["workspaces"].append(copy.deepcopy(other))
        with self.assertRaises(acceptance.IncompleteEvidence):
            acceptance.saved_workspace(s, ("other-monitor", 0))


class WidthTests(unittest.TestCase):
    def test_native_minimum_is_not_requested_drift(self):
        before = snapshot()
        current = copy.deepcopy(before)
        current["layout"]["columns"][0]["width_px"] = 842
        self.assertTrue(all(a["status"] == "unchanged" for a in acceptance.width_restoration(before, current)))

    def test_resize_is_effective_relative(self):
        before = snapshot()
        current = copy.deepcopy(before)
        acceptance.saved_workspace(current)["columns"][0]["width"] = 499
        current["layout"]["columns"][0]["width_px"] = 842
        action = acceptance.width_restoration(before, current)[0]
        self.assertEqual(action["status"], "resize")
        self.assertEqual(action["delta"], -342)
        self.assertEqual(action["effective"] + action["delta"], action["target"])

    def test_selects_non_minimized_member(self):
        before = snapshot(minimized=(2,))
        current = copy.deepcopy(before)
        acceptance.saved_workspace(current)["columns"][1]["width"] = 499
        current["layout"]["columns"][1]["width_px"] = 499
        action = acceptance.width_restoration(before, current)[1]
        self.assertEqual((action["status"], action["hwnd"]), ("resize", 3))

    def test_tabbed_repair_preserves_active_tab_or_blocks(self):
        for minimized, expected in (((), "resize"), ((3,), "blocked")):
            before = snapshot(minimized=minimized)
            mode = {"type": "tabbed", "active_idx": 1}
            acceptance.saved_workspace(before)["columns"][1]["mode"] = mode
            before["layout"]["columns"][1]["mode"] = mode
            current = copy.deepcopy(before)
            acceptance.saved_workspace(current)["columns"][1]["width"] = 499
            current["layout"]["columns"][1]["width_px"] = 499
            action = acceptance.width_restoration(before, current)[1]
            self.assertEqual(action["status"], expected)
            if expected == "resize":
                self.assertEqual(action["hwnd"], 3)
            else:
                self.assertNotIn("hwnd", action)

    def test_baseline_fullscreen_or_maximize_blocks_repair(self):
        for state in ("fullscreen", "maximize"):
            before = snapshot()
            current = copy.deepcopy(before)
            acceptance.saved_workspace(current)["columns"][0]["width"] = 499
            current["layout"]["columns"][0]["width_px"] = 499
            if state == "fullscreen":
                acceptance.saved_workspace(before)["fullscreen_window"] = 1
            else:
                before["maximized_column"] = 0
            self.assertEqual(acceptance.width_restoration(before, current)[0]["status"], "blocked")

    def test_all_minimized_never_receives_action(self):
        before = snapshot(minimized=(1,))
        current = copy.deepcopy(before)
        acceptance.saved_workspace(current)["columns"][0]["width"] = 499
        action = acceptance.width_restoration(before, current)[0]
        self.assertEqual(action["status"], "blocked")
        self.assertIn("Fully minimized", action["reason"])
        self.assertNotIn("hwnd", action)

    def test_zero_delta_is_blocked(self):
        before = snapshot()
        current = copy.deepcopy(before)
        acceptance.saved_workspace(current)["columns"][0]["width"] = 499
        self.assertIn("delta zero", acceptance.width_restoration(before, current)[0]["reason"])

    def test_unsafe_repairs_are_blocked(self):
        before = snapshot()
        for mutation in (lambda s: s.pop("maximized_column"),
                         lambda s: s.update(maximized_column=0),
                         lambda s: acceptance.saved_workspace(s).update(fullscreen_window=1),
                         lambda s: s["native"][0].update(Pid=999),
                         lambda s: acceptance.saved_workspace(s)["columns"][0].update(width=490),
                         lambda s: acceptance.saved_workspace(s)["columns"][0].update(height_weights=[0.5]),
                         lambda s: acceptance.saved_workspace(s)["columns"][0].update(mode={"type": "tabbed", "active_idx": 0})):
            current = copy.deepcopy(before)
            acceptance.saved_workspace(current)["columns"][0]["width"] = 499
            current["layout"]["columns"][0]["width_px"] = 499
            mutation(current)
            self.assertEqual(acceptance.width_restoration(before, current)[0]["status"], "blocked")

    def test_membership_and_workspace_changes_are_incomplete(self):
        before = snapshot()
        for mutation in (lambda s: s["layout"]["columns"][0].update(window_ids=[99]),
                         lambda s: s["workspace"].update(active_workspace=2)):
            current = copy.deepcopy(before)
            mutation(current)
            with self.assertRaises(acceptance.IncompleteEvidence):
                acceptance.width_restoration(before, current)

    def test_missing_requested_width_is_not_inferred(self):
        before = snapshot()
        current = copy.deepcopy(before)
        del acceptance.saved_workspace(current)["columns"][0]["width"]
        with self.assertRaises(KeyError):
            acceptance.width_restoration(before, current)


class VerdictTests(unittest.TestCase):
    def test_exact_restoration_passes(self):
        before = snapshot()
        self.assertEqual(acceptance.restoration(before, copy.deepcopy(before), executor_result())["state"], "passed")

    def test_maximize_loss_fails_and_missing_state_is_incomplete(self):
        before = snapshot()
        before["maximized_column"] = 0
        final = copy.deepcopy(before)
        final["maximized_column"] = None
        self.assertEqual(acceptance.restoration(before, final, executor_result())["state"], "failed")
        del final["maximized_column"]
        self.assertEqual(acceptance.restoration(before, final, executor_result())["state"], "incomplete")

    def test_one_pixel_drift_fails_restoration(self):
        before = snapshot()
        final = copy.deepcopy(before)
        acceptance.saved_workspace(final)["columns"][0]["width"] -= 1
        self.assertEqual(acceptance.restoration(before, final, executor_result())["state"], "failed")

    def test_missing_final_evidence_is_incomplete(self):
        restored = acceptance.restoration(snapshot(), None, None)
        self.assertEqual(restored["state"], "incomplete")
        self.assertIn("Final snapshot absent", restored["missing"])
        self.assertIn("Executor result absent", restored["missing"])

    def test_cleanup_failure_cannot_be_hidden_by_restored_snapshot(self):
        before = snapshot()
        result = executor_result()
        result["CleanupStages"][1]["Succeeded"] = False
        self.assertEqual(acceptance.restoration(before, before, result)["state"], "failed")

    def test_missing_cleanup_stage_is_incomplete(self):
        before = snapshot()
        result = executor_result()
        result["CleanupStages"].pop()
        self.assertEqual(acceptance.restoration(before, before, result)["state"], "incomplete")

    def test_independent_product_and_restoration_verdicts(self):
        passed = acceptance.verdict([("geometry", True)])
        failed = acceptance.verdict([("geometry", False)])
        incomplete = acceptance.verdict([])
        for product, restored in ((passed, failed), (failed, passed), (passed, incomplete)):
            report = acceptance.acceptance(product, restored)
            self.assertFalse(report["passed"])
            self.assertEqual(report["product"], product)
            self.assertEqual(report["restoration"], restored)
        self.assertTrue(acceptance.acceptance(passed, passed)["passed"])

    def test_other_workspace_and_native_identity_are_checked(self):
        before = snapshot()
        other = copy.deepcopy(before["persisted"]["workspaces"][0])
        other["workspace_index"] = 1
        before["persisted"]["workspaces"].append(other)
        for mutation in (lambda s: s["persisted"]["workspaces"][1]["workspace"]["columns"][0].update(width=501),
                         lambda s: s["native"][0].update(Pid=999),
                         lambda s: s["workspace"].update(focused_window=1)):
            final = copy.deepcopy(before)
            mutation(final)
            self.assertEqual(acceptance.restoration(before, final, executor_result())["state"], "failed")

    def test_json_cli_reports_missing_input_without_traceback(self):
        script = Path(__file__).with_name("desktop_acceptance.py")
        result = subprocess.run([sys.executable, str(script)], input=json.dumps({"operation": "extent", "snapshot": {}}),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["state"], "incomplete")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
