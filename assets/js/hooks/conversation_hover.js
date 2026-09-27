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

    this.workspaceCard = this.el.querySelector("#workspace-hover-card");
    this.workspaceRow = null;

    this.onOver = (event) => {
      const row = event.target.closest("[data-conversation-id]");
      if (row && this.el.contains(row) && !event.target.closest(".conversation-hover")) {
        this.hideWorkspace();
        this.show(row);
        return;
      }

      const title = event.target.closest(".workspace-title-row");
      const group = title && title.closest("[data-workspace-path]");
      if (group && this.el.contains(group) && !event.target.closest(".workspace-hover")) {
        this.hide();
        this.showWorkspace(group);
      }
    };
    this.onOut = (event) => {
      const next = event.relatedTarget;
      if (this.row) {
        if (next && (this.row.contains(next) || (this.card && this.card.contains(next)))) return;
        this.scheduleHide();
      }
      if (this.workspaceRow) {
        if (
          next &&
          (this.workspaceRow.contains(next) ||
            (this.workspaceCard && this.workspaceCard.contains(next)))
        ) {
          return;
        }
        this.scheduleHideWorkspace();
      }
    };
    this.onScroll = () => {
      if (this.row) this.place(this.row);
      if (this.workspaceRow) this.placeWorkspace(this.workspaceRow);
    };

    this.el.addEventListener("pointerover", this.onOver);
    this.el.addEventListener("pointerout", this.onOut);
    if (this.scroll) this.scroll.addEventListener("scroll", this.onScroll, { passive: true });
    if (this.card) {
      this.card.addEventListener("pointerenter", () => this.clearHide());
      this.card.addEventListener("pointerleave", () => this.scheduleHide());
    }
    if (this.workspaceCard) {
      this.workspaceCard.addEventListener("pointerenter", () => this.clearHideWorkspace());
      this.workspaceCard.addEventListener("pointerleave", () => this.scheduleHideWorkspace());
      this.onRename = () => {
        const id = this.workspaceRow && this.workspaceRow.dataset.workspaceId;
        if (!id) return;
        this.pushEvent("open_rename_workspace", { id });
        this.hideWorkspace();
      };
      this.workspaceCard
        .querySelector("[data-workspace-hover-rename]")
        .addEventListener("click", this.onRename);
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

  showWorkspace(group) {
    if (!this.workspaceCard) return;
    this.clearHideWorkspace();
    this.workspaceRow = group;
    const name = this.workspaceCard.querySelector("[data-workspace-hover-name]");
    const path = this.workspaceCard.querySelector("[data-workspace-hover-path]");
    const repo = this.workspaceCard.querySelector("[data-workspace-hover-repo]");
    const repoName = this.workspaceCard.querySelector("[data-workspace-hover-repo-name]");
    const rename = this.workspaceCard.querySelector("[data-workspace-hover-rename]");
    if (name) name.textContent = group.dataset.workspaceName || "";
    if (path) path.textContent = group.dataset.workspacePath || "";
    const repository = group.dataset.workspaceRepo || "";
    if (repoName) repoName.textContent = repository;
    if (repo) repo.hidden = repository === "";
    if (rename) rename.dataset.workspaceId = group.dataset.workspaceId || "";
    this.workspaceCard.hidden = false;
    this.workspaceCard.classList.add("is-open");
    this.placeWorkspace(group);
  },

  placeWorkspace(group) {
    const row = group.querySelector(".workspace-title-row") || group;
    const rect = row.getBoundingClientRect();
    const width = this.workspaceCard.offsetWidth || 240;
    const height = this.workspaceCard.offsetHeight || 64;
    const pad = 8;
    let left = rect.right + 10;
    if (left + width > window.innerWidth - pad) left = Math.max(pad, rect.left - width - 10);
    let top = rect.top - 4;
    if (top + height > window.innerHeight - pad) {
      top = Math.max(pad, window.innerHeight - height - pad);
    }
    this.workspaceCard.style.left = `${left}px`;
    this.workspaceCard.style.top = `${top}px`;
  },

  scheduleHideWorkspace() {
    this.clearHideWorkspace();
    this.workspaceHideTimer = window.setTimeout(() => this.hideWorkspace(), 80);
  },

  clearHideWorkspace() {
    if (this.workspaceHideTimer) window.clearTimeout(this.workspaceHideTimer);
    this.workspaceHideTimer = null;
  },

  hideWorkspace() {
    this.workspaceRow = null;
    if (!this.workspaceCard) return;
    this.workspaceCard.classList.remove("is-open");
    this.workspaceCard.hidden = true;
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
