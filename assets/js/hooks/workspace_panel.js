/**
 * WorkspacePanel hook — persist right panel collapsed state in localStorage.
 *
 * - mounted(): restores collapsed preference from localStorage
 * - handleEvent("persist_collapsed"): writes current state to localStorage
 */

const STORAGE_KEY = "handbeam:right_panel_collapsed";

export const WorkspacePanel = {
  mounted() {
    // Restore collapsed preference on mount
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "true") {
      this.pushEvent("set_right_panel_collapsed", { collapsed: true });
    }

    // Listen for persist requests from server
    this.handleEvent("persist_collapsed", ({ collapsed }) => {
      localStorage.setItem(STORAGE_KEY, collapsed ? "true" : "false");
    });
  },
};

export default WorkspacePanel;