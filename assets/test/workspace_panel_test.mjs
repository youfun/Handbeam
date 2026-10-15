import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { WorkspacePanel } from "../js/hooks/workspace_panel.js";

const dom = new JSDOM(`
  <div id="workspace-panel">
    <div class="workspace-tree-pane"></div>
    <div id="editor-content">
      <div id="file-preview">
        <div id="error">Binary files cannot be previewed as text</div>
        <pre id="nested-preview">preview</pre>
      </div>
    </div>
  </div>
`, { url: "https://handbeam.test" });

const { document, WheelEvent } = dom.window;
const root = document.getElementById("workspace-panel");
const tree = root.querySelector(".workspace-tree-pane");
const preview = document.getElementById("editor-content");
const error = document.getElementById("error");
const nestedPreview = document.getElementById("nested-preview");

function setDimensions(element, { clientHeight, scrollHeight }) {
  Object.defineProperties(element, {
    clientHeight: { configurable: true, value: clientHeight },
    scrollHeight: { configurable: true, value: scrollHeight },
  });
}

function wheel(target, options = {}) {
  const event = new WheelEvent("wheel", {
    bubbles: true,
    cancelable: true,
    deltaY: 40,
    ...options,
  });
  target.dispatchEvent(event);
  return event;
}

setDimensions(tree, { clientHeight: 200, scrollHeight: 1000 });
setDimensions(preview, { clientHeight: 200, scrollHeight: 200 });
setDimensions(nestedPreview, { clientHeight: 100, scrollHeight: 100 });

globalThis.localStorage = dom.window.localStorage;

const hook = {
  ...WorkspacePanel,
  el: root,
  handleEvent() {},
  pushEvent() {},
};
hook.mounted();

// An error/binary preview cannot scroll, so its wheel gesture moves the file tree.
tree.scrollTop = 100;
let event = wheel(error);
assert.equal(tree.scrollTop, 140);
assert.equal(event.defaultPrevented, true);

// A scrollable preview keeps ownership of the gesture, including at its boundary.
setDimensions(preview, { clientHeight: 200, scrollHeight: 500 });
tree.scrollTop = 100;
preview.scrollTop = 0;
event = wheel(error, { deltaY: -40 });
assert.equal(tree.scrollTop, 100);
assert.equal(event.defaultPrevented, false);

// A nested scroll container in an otherwise fixed preview also keeps the gesture.
setDimensions(preview, { clientHeight: 200, scrollHeight: 200 });
setDimensions(nestedPreview, { clientHeight: 100, scrollHeight: 500 });
nestedPreview.style.overflowY = "auto";
event = wheel(nestedPreview);
assert.equal(tree.scrollTop, 100);
assert.equal(event.defaultPrevented, false);
setDimensions(nestedPreview, { clientHeight: 100, scrollHeight: 100 });

// Browser gestures, modifier scrolling, and horizontal pans are not intercepted.
for (const options of [
  { ctrlKey: true },
  { metaKey: true },
  { altKey: true },
  { shiftKey: true },
  { deltaX: 40, deltaY: 40 },
]) {
  tree.scrollTop = 100;
  event = wheel(error, options);
  assert.equal(tree.scrollTop, 100);
  assert.equal(event.defaultPrevented, false);
}

// Mouse-wheel line and page deltas are normalized before moving the tree.
tree.scrollTop = 0;
event = wheel(error, { deltaMode: 1, deltaY: 2 });
assert.equal(tree.scrollTop, 32);
assert.equal(event.defaultPrevented, true);

tree.scrollTop = 0;
event = wheel(error, { deltaMode: 2, deltaY: 1 });
assert.equal(tree.scrollTop, 200);
assert.equal(event.defaultPrevented, true);

// Do not consume a wheel event when the tree is already at that boundary.
tree.scrollTop = 0;
event = wheel(error, { deltaY: -40 });
assert.equal(tree.scrollTop, 0);
assert.equal(event.defaultPrevented, false);

tree.scrollTop = 800;
event = wheel(error, { deltaY: 40 });
assert.equal(tree.scrollTop, 800);
assert.equal(event.defaultPrevented, false);

// LiveView hook teardown removes the delegated listener.
hook.destroyed();
tree.scrollTop = 100;
event = wheel(error);
assert.equal(tree.scrollTop, 100);
assert.equal(event.defaultPrevented, false);

delete globalThis.localStorage;
dom.window.close();
console.log("workspace_panel_test passed");
