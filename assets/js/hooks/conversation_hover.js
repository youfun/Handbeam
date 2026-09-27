/**
 * Shows a fixed card to the right of a sidebar conversation row.
 * The card lives outside the scroll container so overflow cannot clip it.
 */
export const ConversationHover = {
  mounted() {
    this.card = this.el.querySelector("#conversation-hover-card");
    this.scroll = this.el.querySelector("#projects-sidebar-scroll");
    this.row = null;
    this.hideTimer = null;

    this.onOver = (event) => {
      const row = event.target.closest("[data-conversation-id]");
      if (!row || !this.el.contains(row)) return;
      if (event.target.closest(".conversation-hover")) return;
      this.show(row);
    };
    this.onOut = (event) => {
      if (!this.row) return;
      const next = event.relatedTarget;
      if (next && (this.row.contains(next) || (this.card && this.card.contains(next)))) return;
      this.scheduleHide();
    };
    this.onScroll = () => {
      if (this.row) this.place(this.row);
    };

    this.el.addEventListener("pointerover", this.onOver);
    this.el.addEventListener("pointerout", this.onOut);
    if (this.scroll) this.scroll.addEventListener("scroll", this.onScroll, { passive: true });
    if (this.card) {
      this.card.addEventListener("pointerenter", () => this.clearHide());
      this.card.addEventListener("pointerleave", () => this.scheduleHide());
    }
  },

  updated() {
    this.card = this.el.querySelector("#conversation-hover-card");
    if (this.row && this.row.isConnected) this.show(this.row);
    else this.hide();
  },

  destroyed() {
    this.clearHide();
    this.el.removeEventListener("pointerover", this.onOver);
    this.el.removeEventListener("pointerout", this.onOut);
    if (this.scroll) this.scroll.removeEventListener("scroll", this.onScroll);
  },

  show(row) {
    if (!this.card) return;
    if (row.closest(".archived")) return this.hide();
    this.clearHide();
    this.row = row;

    const title = this.card.querySelector("[data-hover-title]");
    const age = this.card.querySelector("[data-hover-age]");
    const copy = this.card.querySelector("[data-copy]");
    const text = row.dataset.conversationTitle || "";
    if (title) title.textContent = text;
    if (copy) copy.dataset.copy = text;
    if (age) {
      const value = row.dataset.conversationAge || "";
      age.textContent = value;
      age.hidden = value === "";
    }

    const workspaceId = row.dataset.workspaceId || "";
    this.card.querySelectorAll("[data-hover-context]").forEach((node) => {
      node.hidden = node.dataset.hoverContext !== workspaceId;
    });

    this.card.hidden = false;
    this.card.classList.add("is-open");
    this.place(row);
  },

  place(row) {
    const rect = row.getBoundingClientRect();
    const width = this.card.offsetWidth || 220;
    const height = this.card.offsetHeight || 72;
    const pad = 8;
    let left = rect.right + 10;
    if (left + width > window.innerWidth - pad) left = Math.max(pad, rect.left - width - 10);
    let top = rect.top - 4;
    if (top + height > window.innerHeight - pad) top = Math.max(pad, window.innerHeight - height - pad);
    this.card.style.left = `${left}px`;
    this.card.style.top = `${top}px`;
  },

  scheduleHide() {
    this.clearHide();
    this.hideTimer = window.setTimeout(() => this.hide(), 80);
  },

  clearHide() {
    if (this.hideTimer) window.clearTimeout(this.hideTimer);
    this.hideTimer = null;
  },

  hide() {
    this.row = null;
    if (!this.card) return;
    this.card.classList.remove("is-open");
    this.card.hidden = true;
  }
};

export default ConversationHover;
