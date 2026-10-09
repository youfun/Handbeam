const conversationColors = [
  "#7eb8c9", "#c9846a", "#6a9a72", "#8b7ec4",
  "#c5a552", "#c47d9b", "#58aaa0", "#6e94cc",
];

// Mix all hash bits before selecting a color, rather than just FNV's low bits.
function conversationHash(id) {
  let hash = 2166136261;
  for (const ch of id) hash = Math.imul(hash ^ ch.codePointAt(0), 16777619);
  hash = Math.imul(hash ^ (hash >>> 16), 0x85ebca6b);
  hash = Math.imul(hash ^ (hash >>> 13), 0xc2b2ae35);
  return (hash ^ (hash >>> 16)) >>> 0;
}

// Runtime owns running/waiting/idle; the 7.6-second sequence is purely visual.
const cycleDuration = 7.6;
const appearanceDuration = 0.8;
export const ConversationActivity = {
  mounted() {
    this.bodies = new Map();
    this.motion = matchMedia("(prefers-reduced-motion: reduce)");
    this.onVisibility = () => this.schedule();
    this.onMotion = () => this.sync();
    document.addEventListener("visibilitychange", this.onVisibility);
    this.motion.addEventListener("change", this.onMotion);
    this.sync();
  },

  updated() { this.sync(); },

  destroyed() {
    cancelAnimationFrame(this.frame);
    document.removeEventListener("visibilitychange", this.onVisibility);
    this.motion.removeEventListener("change", this.onMotion);
  },

  sync() {
    const next = new Map();
    for (const el of this.el.querySelectorAll("[data-run-id]")) {
      const id = el.dataset.runId;
      const hash = conversationHash(id);
      const body = next.get(id) || this.bodies.get(id) || { elapsed: 0, growth: 0 };
      const sprite = el.querySelector(".conversation-run-sprite");
      if (!sprite) continue;
      // Keep phase across LiveView patches and approval; reset after completion.
      if (body.state === "idle") {
        body.elapsed = 0;
        body.growth = 0;
      }
      body.state = el.dataset.runState;
      if (body.state === "idle") body.growth = 0;
      if (body.state === "running" && this.motion.matches) body.growth = 1;
      if (!next.has(id)) {
        body.sprites = [];
        body.indicators = [];
      }
      body.sprites.push(sprite);
      body.indicators.push(el);
      el.style.setProperty("--run-color", conversationColors[hash % conversationColors.length]);
      this.paintAppearance(body);
      this.paint(body);
      next.set(id, body);
    }
    this.bodies = next;
    this.schedule();
  },

  schedule() {
    if (document.hidden || this.motion.matches ||
        ![...this.bodies.values()].some(body => body.state === "running")) {
      cancelAnimationFrame(this.frame);
      this.frame = null;
      return;
    }
    if (this.frame) return;
    this.last = performance.now();
    this.frame = requestAnimationFrame(now => this.tick(now));
  },

  paintAppearance(body) {
    const growing = body.state === "running" && body.growth < 1 && !this.motion.matches;
    const p = body.growth * body.growth * (3 - 2 * body.growth);
    for (const el of body.indicators) {
      const flag = growing ? "true" : "false";
      if (el.dataset.runGrowing !== flag) el.dataset.runGrowing = flag;
      if (!growing) continue;
      const values = {
        "--run-stem-rise": `${-7 * p}px`,
        "--run-reveal-top": `${59.615 * (1 - p)}%`,
        "--run-reveal-bottom": `${40.385 * (1 - p)}%`,
        "--run-reveal-opacity": `${p}`,
        "--run-limbs-opacity": `${Math.max(0, (p - .65) / .35)}`,
      };
      for (const [name, value] of Object.entries(values)) {
        if (el.style.getPropertyValue(name) !== value) el.style.setProperty(name, value);
      }
    }
  },

  paint(body) {
    const moving = body.state === "running" && body.growth >= 1 && !this.motion.matches;
    const time = moving ? body.elapsed % cycleDuration : 0;
    const stage = time < 2 ? 0 : time < 5.6 ? 1 : 2;
    const local = stage === 0 ? time : stage === 1 ? time - 2 : time - 5.6;
    const action = stage === 1 ? "look" : "walk";
    const values = {
      "--run-hop": 0, "--run-upper-x": 0,
      "--run-eyes-x": 0, "--run-sway": 0,
      "--run-step-a": 0, "--run-step-b": 0,
      "--run-left-y": 0, "--run-right-y": 0,
    };
    if (moving && stage !== 1) {
      const frame = Math.floor(local * 8) % 8;
      values["--run-hop"] = frame % 4 >= 2 ? -1 : 0;
      values["--run-step-a"] = frame < 4 ? 0 : -1;
      values["--run-step-b"] = frame < 4 ? -1 : 0;
      values["--run-left-y"] = values["--run-step-b"];
      values["--run-right-y"] = values["--run-step-a"];
      values["--run-sway"] = frame % 4 >= 2 ? 1 : 0;
    } else if (moving && stage === 1) {
      const p = local / 3.6;
      values["--run-eyes-x"] = p < .12 ? 0 : p < .20 ? -1 : p < .44 ? -2 : p < .56 ? 0 : p < .64 ? 1 : p < .88 ? 2 : 0;
      values["--run-upper-x"] = p >= .20 && p < .44 ? -1 : p >= .64 && p < .88 ? 1 : 0;
      values["--run-sway"] = p >= .24 && p < .44 ? -1 : p >= .68 && p < .88 ? 1 : 0;
    }
    for (const sprite of body.sprites) {
      if (sprite.dataset.runAction !== action) sprite.dataset.runAction = action;
      for (const [name, value] of Object.entries(values)) {
        const cssValue = `${value}px`;
        if (sprite.style.getPropertyValue(name) !== cssValue) sprite.style.setProperty(name, cssValue);
      }
    }
  },

  tick(now) {
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    for (const body of this.bodies.values()) {
      if (body.state !== "running") continue;
      let remaining = dt;
      if (body.growth < 1) {
        const consumed = Math.min(remaining, appearanceDuration * (1 - body.growth));
        body.growth = Math.min(1, body.growth + consumed / appearanceDuration);
        remaining -= consumed;
      }
      body.elapsed = (body.elapsed + remaining) % cycleDuration;
      this.paintAppearance(body);
      this.paint(body);
    }
    this.frame = null;
    this.schedule();
  },
};
