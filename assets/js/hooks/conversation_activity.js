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

// Runtime state stays in LiveView; only phase and short-lived momentum live here.
export const ConversationActivity = {
  mounted() {
    this.bodies = new Map();
    this.motion = matchMedia("(prefers-reduced-motion: reduce)");
    this.onVisibility = () => this.schedule();
    this.onMotion = () => this.sync();
    document.addEventListener("visibilitychange", this.onVisibility);
    this.motion.addEventListener("change", this.onMotion);
    this.handleEvent("conversation_activity", ({ id, kind }) => {
      const body = this.bodies.get(id);
      if (body?.state === "running" && !document.hidden && !this.motion.matches) {
        body.boost = Math.min(0.55, body.boost + (kind.startsWith("tool_") ? 0.35 : 0.18));
      }
    });
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
      const body = next.get(id) || this.bodies.get(id) || {
        phase: (hash % 1000) / 1000 * Math.PI * 2,
        period: 0.9 + (hash % 20) / 100,
        boost: 0,
      };
      body.state = el.dataset.runState;
      const mode = el.dataset.runMode || "run";
      if (body.mode !== mode) body.modeTime = 0;
      body.mode = mode;
      const sprite = el.querySelector(".conversation-run-sprite");
      if (!sprite) continue;
      if (!next.has(id)) body.sprites = [];
      body.sprites.push(sprite);
      el.style.setProperty("--run-color", conversationColors[hash % conversationColors.length]);
      if (body.state !== "running" || this.motion.matches) body.boost = 0;
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

  paint(body) {
    const moving = body.state === "running" && !this.motion.matches;
    const frame = moving ? Math.floor(body.phase / (Math.PI * 2) * 8) % 8 : 0;
    let upperX = 0, upperY = 0, eyes = 0, tapX = 0, tapY = 0, sway = 0;
    const walking = moving && body.mode === "run";
    if (moving && body.mode === "look") {
      const t = (body.modeTime % 3.6) / 3.6;
      eyes = t < .12 ? 0 : t < .20 ? -1 : t < .44 ? -2 : t < .56 ? 0 : t < .64 ? 1 : t < .88 ? 2 : 0;
      upperX = t >= .20 && t < .44 ? -1 : t >= .64 && t < .88 ? 1 : 0;
      sway = t >= .24 && t < .44 ? -1 : t >= .68 && t < .88 ? 1 : 0;
    } else if (body.mode === "edit") {
      eyes = 1;
      if (moving) {
        const t = (body.modeTime % 1.6) / 1.6;
        const raised = (t >= .10 && t < .22) || (t >= .32 && t < .44);
        const tapping = (t >= .22 && t < .28) || (t >= .44 && t < .50);
        tapY = raised ? -4 : (t >= .22 && t < .32) || (t >= .44 && t < .56) ? 1 : 0;
        tapX = tapY === 1 ? 1 : 0;
        upperY = tapping ? 1 : 0;
        sway = tapping ? 1 : 0;
      }
    }
    for (const sprite of body.sprites) {
      const values = {
        "--run-hop": walking && frame % 4 >= 2 ? -1 : 0,
        "--run-step": walking && frame >= 4 ? -1 : 0,
        "--run-sway": walking && frame % 4 >= 2 ? 1 : sway,
        "--run-upper-x": upperX, "--run-upper-y": upperY,
        "--run-eyes-x": eyes, "--run-tap-x": tapX, "--run-tap-y": tapY,
      };
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
      body.modeTime += dt;
      body.boost *= Math.exp(-dt / 0.7);
      const pull = 0.8 + 0.5 * Math.sin(body.phase) ** 2;
      body.phase = (body.phase + dt * Math.PI * 2 / body.period * pull * (1 + body.boost)) % (Math.PI * 2);
      this.paint(body);
    }
    this.frame = requestAnimationFrame(now => this.tick(now));
  },
};
