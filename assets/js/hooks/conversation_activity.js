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
      let hash = 2166136261;
      for (const ch of id) hash = Math.imul(hash ^ ch.codePointAt(0), 16777619);
      hash >>>= 0;
      const body = next.get(id) || this.bodies.get(id) || {
        phase: (hash % 1000) / 1000 * Math.PI * 2,
        period: 0.9 + (hash % 20) / 100,
        boost: 0,
      };
      body.state = el.dataset.runState;
      const sprite = el.querySelector(".conversation-run-sprite");
      if (!sprite) continue;
      if (!next.has(id)) body.sprites = [];
      body.sprites.push(sprite);
      el.style.setProperty("--run-color", ["#7eb8c9", "#c9846a", "#6a9a72", "#8b7ec4"][hash % 4]);
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
    for (const sprite of body.sprites) {
      sprite.style.setProperty("--run-hop", moving && frame % 4 >= 2 ? "-1px" : "0px");
      sprite.style.setProperty("--run-step", frame < 4 ? "0px" : "-1px");
      sprite.style.setProperty("--run-sway", moving && frame % 4 >= 2 ? "1px" : "0px");
    }
  },

  tick(now) {
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    for (const body of this.bodies.values()) {
      if (body.state !== "running") continue;
      body.boost *= Math.exp(-dt / 0.7);
      const pull = 0.8 + 0.5 * Math.sin(body.phase) ** 2;
      body.phase = (body.phase + dt * Math.PI * 2 / body.period * pull * (1 + body.boost)) % (Math.PI * 2);
      this.paint(body);
    }
    this.frame = requestAnimationFrame(now => this.tick(now));
  },
};
