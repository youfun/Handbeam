import assert from "node:assert/strict";
import { ConversationActivity } from "../js/hooks/conversation_activity.js";

function style() {
  const values = new Map();
  return {
    values,
    getPropertyValue: name => values.get(name) || "",
    setProperty: (name, value) => values.set(name, value),
  };
}
function indicator(id, state = "running") {
  const sprite = { style: style(), dataset: {} };
  return {
    dataset: { runId: id, runState: state }, style: style(), sprite,
    querySelector: () => sprite,
  };
}

let clock = 0, rafId = 0;
const callbacks = new Map();
const listeners = new Map();
globalThis.performance = { now: () => clock };
globalThis.requestAnimationFrame = callback => {
  const id = ++rafId;
  callbacks.set(id, callback);
  return id;
};
globalThis.cancelAnimationFrame = id => callbacks.delete(id);
globalThis.document = {
  hidden: false,
  addEventListener: (name, callback) => listeners.set(name, callback),
  removeEventListener: name => listeners.delete(name),
};
const motion = { matches: false, addEventListener() {}, removeEventListener() {} };
globalThis.matchMedia = () => motion;
const pinned = indicator("same-conversation");
const regular = indicator("same-conversation");
const idle = indicator("idle-conversation", "idle");
const hook = { ...ConversationActivity, el: { querySelectorAll: () => [pinned, regular, idle] } };
hook.mounted();
const body = hook.bodies.get("same-conversation");
const value = name => pinned.sprite.style.getPropertyValue(`--run-${name}`);
function paint(time) {
  body.elapsed = time;
  hook.paint(body);
  assert.deepEqual(regular.sprite.dataset, pinned.sprite.dataset);
  assert.deepEqual(regular.sprite.style.values, pinned.sprite.style.values,
    "pinned and regular copies stay synchronized");
  return pinned.sprite.dataset.runAction;
}

assert.equal(hook.bodies.size, 2);
assert.equal(callbacks.size, 1, "all running conversations share one animation clock");
assert.equal(pinned.style.getPropertyValue("--run-color"), regular.style.getPropertyValue("--run-color"));
assert.equal(paint(0), "walk");
assert.equal(paint(1.99), "walk");
assert.equal(paint(2.8), "look");
assert.equal(value("eyes-x"), "-2px");
assert.equal(paint(4.7), "look");
assert.equal(value("eyes-x"), "2px");
assert.equal(value("step-a"), "0px");
assert.equal(value("step-b"), "0px", "feet stay planted while looking");
assert.equal(paint(5.6), "walk", "walking resumes immediately after looking");
assert.equal(value("eyes-x"), "0px");
assert.equal(value("upper-x"), "0px", "looking offsets reset before walking");
assert.equal(paint(5.9), "walk");
assert.equal(value("hop"), "-1px", "the final walk still bounces");
assert.equal(paint(7.59), "walk");
assert.equal(paint(7.6), "walk", "the cycle restarts after 7.6 seconds");
assert.equal(value("step-a"), "0px");
assert.equal(value("step-b"), "-1px");
assert.equal(paint(10.4), "look", "the next cycle has the same timing");
assert.equal(value("eyes-x"), "-2px");
for (let time = 0; time < 15.2; time += .05) {
  assert.ok(["walk", "look"].includes(paint(time)), "only walking and looking remain");
}

paint(3.2);
hook.updated();
assert.equal(body.elapsed, 3.2, "LiveView updates do not restart the cycle");
for (const el of [pinned, regular]) el.dataset.runState = "waiting_confirmation";
hook.updated();
assert.equal(callbacks.size, 0, "approval stops the clock");
assert.equal(body.elapsed, 3.2);
for (const el of [pinned, regular]) el.dataset.runState = "running";
hook.updated();
assert.equal(body.elapsed, 3.2, "approval resume preserves phase");
assert.equal(callbacks.size, 1);

motion.matches = true;
hook.onMotion();
assert.equal(callbacks.size, 0);
assert.equal(value("eyes-x"), "0px");
motion.matches = false;
hook.onMotion();
document.hidden = true;
hook.onVisibility();
assert.equal(callbacks.size, 0, "hidden pages stop the clock");
clock += 60_000;
document.hidden = false;
hook.onVisibility();
assert.equal(body.elapsed, 3.2, "background time does not advance the animation");
assert.equal(callbacks.size, 1);

for (const el of [pinned, regular]) el.dataset.runState = "idle";
hook.updated();
assert.equal(callbacks.size, 0);
for (const el of [pinned, regular]) el.dataset.runState = "running";
hook.updated();
assert.equal(body.elapsed, 0, "a new run starts with walking");
hook.destroyed();
assert.equal(callbacks.size, 0);
assert.equal(listeners.size, 0);
console.log("conversation activity: walk/look sequence, lifecycle, colors and clock checks passed");
