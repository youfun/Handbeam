/**
 * WorkspacePanel hook — persist right panel collapsed state in localStorage and
 * keep wheel scrolling useful when a non-scrollable file preview opens under
 * the pointer.
 */

const STORAGE_KEY = "handbeam:right_panel_collapsed";
const SCROLL_TOLERANCE = 1;
const LINE_SCROLL_PIXELS = 16;
const FALLBACK_PAGE_HEIGHT = 400;

function hasVerticalOverflow(element) {
  return element.scrollHeight > element.clientHeight + SCROLL_TOLERANCE;
}

function isVerticalScrollContainer(element) {
  if (!hasVerticalOverflow(element)) return false;

  const view = element.ownerDocument?.defaultView;
  const styles = view?.getComputedStyle(element);
  const overflowY = styles?.overflowY || styles?.overflow || "";
  return /^(auto|scroll|overlay)$/.test(overflowY);
}

function nestedPreviewCanScroll(target, preview) {
  for (let element = target; element && element !== preview; element = element.parentElement) {
    if (isVerticalScrollContainer(element)) return true;
  }

  return false;
}

function normalizedWheelDelta(event, pageHeight) {
  if (event.deltaMode === 1) return event.deltaY * LINE_SCROLL_PIXELS;
  if (event.deltaMode === 2) return event.deltaY * (pageHeight || FALLBACK_PAGE_HEIGHT);
  return event.deltaY;
}

export function forwardUnscrollablePreviewWheel(root, event) {
  if (
    event.defaultPrevented ||
    event.ctrlKey ||
    event.metaKey ||
    event.altKey ||
    event.shiftKey ||
    event.deltaY === 0 ||
    Math.abs(event.deltaY) <= Math.abs(event.deltaX || 0)
  ) {
    return false;
  }

  const target = event.target?.nodeType === 1 ? event.target : event.target?.parentElement;
  const preview = target?.closest?.("#editor-content");
  if (!preview || !root.contains(preview) || hasVerticalOverflow(preview)) return false;
  if (nestedPreviewCanScroll(target, preview)) return false;

  const tree = root.querySelector(".workspace-tree-pane");
  if (!tree || !hasVerticalOverflow(tree)) return false;

  const before = tree.scrollTop;
  const maximum = Math.max(0, tree.scrollHeight - tree.clientHeight);
  const delta = normalizedWheelDelta(event, tree.clientHeight);
  tree.scrollTop = Math.max(0, Math.min(maximum, before + delta));

  if (tree.scrollTop === before) return false;

  event.preventDefault();
  return true;
}

export const WorkspacePanel = {
  mounted() {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "true") {
      this.pushEvent("set_right_panel_collapsed", { collapsed: true });
    }

    this.handleEvent("persist_collapsed", ({ collapsed }) => {
      localStorage.setItem(STORAGE_KEY, collapsed ? "true" : "false");
    });

    this.handlePreviewWheel = (event) => forwardUnscrollablePreviewWheel(this.el, event);
    this.el.addEventListener("wheel", this.handlePreviewWheel, { passive: false });
  },

  destroyed() {
    this.el.removeEventListener("wheel", this.handlePreviewWheel);
  },
};

export default WorkspacePanel;
