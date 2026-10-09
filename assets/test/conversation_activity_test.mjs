import assert from "node:assert/strict";
import { ConversationActivity } from "../js/hooks/conversation_activity.js";

function style() {
  const values = new Map();
  return {
    values,
    reads: 0,
    writes: 0,
    getPropertyValue(name) { this.reads++; return values.get(name) || ""; },
    setProperty(name, value) { this.writes++; values.set(name, value); },
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
function advance(seconds) {
  const end = clock + seconds * 1000;
  while (clock < end - .001) {
    clock = Math.min(end, clock + 50);
    const callback = callbacks.get(hook.frame);
    assert.ok(callback, "the shared clock remains scheduled");
    callbacks.delete(hook.frame);
    callback(clock);
  }
}
const growing = () => pinned.dataset.runGrowing;
assert.equal(growing(), "true", "a running bean first appears from the idle stem");
assert.equal(body.elapsed, 0);
assert.equal(value("step-b"), "0px", "feet do not step during appearance");
assert.equal(pinned.style.getPropertyValue("--run-reveal-opacity"), "0");
advance(.4);
assert.equal(body.elapsed, 0, "appearance does not consume any of the original cycle");
assert.equal(pinned.style.getPropertyValue("--run-stem-rise"), "-3.5px");
assert.equal(pinned.style.getPropertyValue("--run-limbs-opacity"), "0",
  "the body appears before the limbs");
const growthBeforePatch = body.growth;
hook.updated();
assert.equal(body.growth, growthBeforePatch, "patches do not restart appearance");
assert.deepEqual(pinned.style.values, regular.style.values);
advance(.3);
assert.ok(Number(pinned.style.getPropertyValue("--run-limbs-opacity")) > 0);
assert.equal(value("step-b"), "0px", "limbs appear without changing their pose");
advance(.15);
assert.equal(growing(), "false", "appearance controls detach once the bean is complete");
assert.equal(body.growth, 1);
assert.ok(Math.abs(body.elapsed - .05) < .00001);

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

const conversationColor = pinned.style.getPropertyValue("--run-color");
for (const el of [pinned, regular]) el.dataset.runState = "idle";
hook.updated();
assert.equal(callbacks.size, 0, "idle stems do not keep an animation clock running");
assert.equal(pinned.style.getPropertyValue("--run-color"), conversationColor,
  "the idle stem inherits the same conversation color as the running bean");
assert.equal(regular.style.getPropertyValue("--run-color"), conversationColor);
for (const el of [pinned, regular]) el.dataset.runState = "running";
hook.updated();
assert.equal(body.elapsed, 0, "a new run starts with the appearance transition");
assert.equal(growing(), "true");
assert.equal(body.growth, 0);
assert.equal(pinned.style.getPropertyValue("--run-color"), conversationColor,
  "starting again preserves the idle stem's color");
advance(.4);
const pausedGrowth = body.growth;
for (const el of [pinned, regular]) el.dataset.runState = "waiting_confirmation";
hook.updated();
assert.equal(callbacks.size, 0);
assert.equal(growing(), "false", "approval displays its marker immediately");
for (const el of [pinned, regular]) el.dataset.runState = "running";
hook.updated();
assert.equal(body.growth, pausedGrowth, "approval resumes the unfinished appearance");
advance(.45);
assert.equal(growing(), "false");
for (const el of [pinned, regular]) el.dataset.runState = "idle";
hook.updated();
assert.equal(callbacks.size, 0);
assert.equal(growing(), "false", "ending immediately restores the static stem");
motion.matches = true;
for (const el of [pinned, regular]) el.dataset.runState = "running";
hook.updated();
assert.equal(body.growth, 1, "reduced motion skips appearance");
assert.equal(growing(), "false");
assert.equal(callbacks.size, 0);
hook.destroyed();
assert.equal(callbacks.size, 0);
assert.equal(listeners.size, 0);
// Check real visibility transitions separately from the no-observer fallback above.
let observer;
globalThis.IntersectionObserver = class {
  constructor(callback) { this.callback = callback; this.targets = new Set(); observer = this; }
  observe(el) { this.targets.add(el); }
  unobserve(el) { this.targets.delete(el); }
  disconnect() { this.targets.clear(); }
  emit(entries) { this.callback(entries.map(([target, visible]) => ({ target, isIntersecting: visible }))); }
};
motion.matches = false;
const visibleCopy = indicator("scrolling-conversation");
const hiddenCopy = indicator("scrolling-conversation");
let elements = [visibleCopy, hiddenCopy];
const scrolling = { ...ConversationActivity, el: { querySelectorAll: () => elements } };
scrolling.mounted();
const scrollingBody = scrolling.bodies.get("scrolling-conversation");
function scrollAdvance(seconds) {
  const end = clock + seconds * 1000;
  while (clock < end - .001) {
    clock = Math.min(end, clock + 25);
    const callback = callbacks.get(scrolling.frame);
    assert.ok(callback);
    callbacks.delete(scrolling.frame);
    callback(clock);
  }
}
observer.emit([[hiddenCopy, false]]);
const hiddenWrites = hiddenCopy.style.writes + hiddenCopy.sprite.style.writes;
const hiddenReads = hiddenCopy.style.reads + hiddenCopy.sprite.style.reads;
scrollAdvance(.85);
assert.equal(scrollingBody.growth, 1);
assert.equal(hiddenCopy.style.writes + hiddenCopy.sprite.style.writes, hiddenWrites,
  "an offscreen duplicate receives no appearance or pose writes");
assert.equal(hiddenCopy.style.reads + hiddenCopy.sprite.style.reads, hiddenReads,
  "offscreen copies do not even read their inline styles");
const pose = scrollingBody.pose;
const poseReads = visibleCopy.sprite.style.reads;
const appearanceReads = visibleCopy.style.reads;
scrollAdvance(.025);
assert.equal(scrollingBody.pose, pose, "the same walk frame reuses its calculated pose");
assert.equal(visibleCopy.sprite.style.reads, poseReads, "unchanged poses skip style checks");
assert.equal(visibleCopy.style.reads, appearanceReads, "completed appearance skips style checks");
observer.emit([[hiddenCopy, true]]);
assert.deepEqual(hiddenCopy.sprite.style.values, visibleCopy.sprite.style.values,
  "a restored copy immediately matches the visible pinned copy");
assert.equal(hiddenCopy.dataset.runGrowing, "false", "restoring a copy does not replay appearance");
observer.emit([[visibleCopy, false], [hiddenCopy, false]]);
assert.equal(callbacks.size, 0, "no RAF runs when all active icons are offscreen");
const elapsedOffscreen = scrollingBody.elapsed;
const offscreenWrites = visibleCopy.sprite.style.writes;
clock += 2800;
observer.emit([[visibleCopy, true]]);
assert.ok(Math.abs(scrollingBody.elapsed - (elapsedOffscreen + 2.8) % 7.6) < .00001,
  "offscreen progress is restored lazily at the current phase");
assert.equal(visibleCopy.sprite.dataset.runAction, "look");
assert.equal(callbacks.size, 1);
assert.ok(visibleCopy.sprite.style.writes > offscreenWrites);
// The two leaf thresholds must invalidate the cache even while the eyes stay still.
scrollingBody.elapsed = 2 + .23 * 3.6;
scrolling.paint(scrollingBody);
assert.equal(visibleCopy.sprite.style.getPropertyValue("--run-sway"), "0px");
scrollingBody.elapsed = 2 + .25 * 3.6;
scrolling.paint(scrollingBody);
assert.equal(visibleCopy.sprite.style.getPropertyValue("--run-sway"), "-1px");
scrollingBody.elapsed = 2 + .65 * 3.6;
scrolling.paint(scrollingBody);
assert.equal(visibleCopy.sprite.style.getPropertyValue("--run-sway"), "0px");
scrollingBody.elapsed = 2 + .69 * 3.6;
scrolling.paint(scrollingBody);
assert.equal(visibleCopy.sprite.style.getPropertyValue("--run-sway"), "1px");
observer.emit([[visibleCopy, false]]);
clock += 500;
document.hidden = true;
scrolling.onVisibility();
const beforeBackground = scrollingBody.elapsed;
clock += 60_000;
observer.emit([[visibleCopy, true]]);
assert.equal(callbacks.size, 0, "observer callbacks cannot restart a hidden page");
document.hidden = false;
scrolling.onVisibility();
assert.equal(scrollingBody.elapsed, beforeBackground, "background time is excluded from offscreen catch-up");
assert.equal(callbacks.size, 1);
// Replace a visible DOM node while retaining the same dialogue and phase.
const replacement = indicator("scrolling-conversation");
elements = [replacement];
const beforePatch = scrollingBody.elapsed;
scrolling.updated();
assert.equal(scrollingBody.elapsed, beforePatch);
assert.equal(observer.targets.has(visibleCopy), false);
assert.equal(observer.targets.has(hiddenCopy), false);
assert.equal(observer.targets.has(replacement), true);
assert.deepEqual(replacement.sprite.style.values, visibleCopy.sprite.style.values);
// A retained node can have its client-side styles removed by a server patch.
replacement.sprite.style.values.clear();
scrolling.updated();
assert.deepEqual(replacement.sprite.style.values, visibleCopy.sprite.style.values,
  "LiveView patches invalidate the DOM pose cache");
observer.emit([[replacement, false]]);
replacement.dataset.runState = "waiting_confirmation";
scrolling.updated();
const beforeApproval = scrollingBody.elapsed;
clock += 2000;
replacement.dataset.runState = "running";
scrolling.updated();
observer.emit([[replacement, true]]);
assert.equal(scrollingBody.elapsed, beforeApproval, "approval time never enters offscreen progress");
// Reduced motion also pauses lazy progress, not just the animation clock.
observer.emit([[replacement, false]]);
motion.matches = true;
scrolling.onMotion();
const beforeReduced = scrollingBody.elapsed;
clock += 2000;
motion.matches = false;
scrolling.onMotion();
observer.emit([[replacement, true]]);
assert.equal(scrollingBody.elapsed, beforeReduced);
// New appearances that finish offscreen must not restart when scrolled into view.
replacement.dataset.runState = "idle";
scrolling.updated();
replacement.dataset.runState = "running";
scrolling.updated();
observer.emit([[replacement, false]]);
clock += 1300;
observer.emit([[replacement, true]]);
assert.equal(scrollingBody.growth, 1);
assert.equal(replacement.dataset.runGrowing, "false");
assert.ok(Math.abs(scrollingBody.elapsed - .5) < .00001);
scrolling.destroyed();
assert.equal(observer.targets.size, 0, "destroy disconnects all observed nodes");
assert.equal(scrolling.visibility.size, 0);
assert.equal(callbacks.size, 0);
assert.equal(listeners.size, 0);
// One visible conversation must not cause an offscreen conversation to repaint.
const foreground = indicator("foreground");
const offscreen = indicator("offscreen");
const staticStem = indicator("static", "idle");
const concurrent = { ...ConversationActivity,
  el: { querySelectorAll: () => [foreground, offscreen, staticStem] } };
concurrent.mounted();
assert.equal(observer.targets.has(staticStem), false, "static stems need no intersection observer");
observer.emit([[offscreen, false]]);
const offscreenBody = concurrent.bodies.get("offscreen");
const beforeOffscreenReads = offscreen.sprite.style.reads;
for (let i = 0; i < 40; i++) {
  clock += 25;
  const callback = callbacks.get(concurrent.frame);
  callbacks.delete(concurrent.frame);
  callback(clock);
}
assert.equal(offscreenBody.growth, 0, "invisible progress is calculated lazily, not on every frame");
assert.equal(offscreen.sprite.style.reads, beforeOffscreenReads);
assert.equal(concurrent.bodies.get("foreground").growth, 1);
observer.emit([[offscreen, true]]);
assert.equal(offscreenBody.growth, 1);
assert.ok(Math.abs(offscreenBody.elapsed - .2) < .00001,
  "another conversation's clock does not double-count offscreen time");
concurrent.destroyed();
assert.equal(observer.targets.size, 0);
assert.equal(callbacks.size, 0);
console.log("conversation activity: appearance, original poses, visibility, caching, patches and lifecycle checks passed");
