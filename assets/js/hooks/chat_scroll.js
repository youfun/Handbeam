/**
 * ChatScroll hook — auto-scroll & scroll retention for the chat panel.
 *
 * Behavior:
 * - On mount: scroll to bottom, mark as "pinned".
 * - On user scroll: track whether user is within threshold of bottom.
 * - After DOM updates (LiveView morph / stream insert / innerHTML changes):
 *   if pinned → auto-scroll to bottom; if not pinned → preserve position.
 * - LiveView can push "user-message-sent" event to force-scroll and re-pin.
 *
 * Content growth must not unpin. A growing transcript fires `scroll` before
 * we can set scrollTop, which used to flip pinned=false and freeze the pane.
 */

const SCROLL_THRESHOLD_PX = 64;

export const ChatScroll = {
  mounted() {
    this.pinned = true;
    this._programmatic = false;

    requestAnimationFrame(() => {
      this.scrollToBottom();
    });

    this.onUserIntent = () => {
      this._userIntent = true;
    };

    this.onScroll = () => {
      if (this._programmatic) return;
      const el = this.el;
      if (!el) return;
      const distFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
      const nearBottom = distFromBottom <= SCROLL_THRESHOLD_PX;
      if (this._userIntent) {
        this.pinned = nearBottom;
        if (nearBottom) this._userIntent = false;
      }
    };

    this.el.addEventListener("scroll", this.onScroll, { passive: true });
    this.el.addEventListener("wheel", this.onUserIntent, { passive: true });
    this.el.addEventListener("touchstart", this.onUserIntent, { passive: true });
    this.el.addEventListener("pointerdown", this.onUserIntent, { passive: true });

    this.observer = new MutationObserver(() => {
      this.maybeScrollToBottom();
    });

    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      characterData: true,
    });

    this.handleEvent("user-message-sent", () => {
      this.pinned = true;
      this._userIntent = false;
      this.scrollToBottom();
    });

    this.handleEvent("scroll_chat_to_bottom", () => {
      this.pinned = true;
      this._userIntent = false;
      this.scrollToBottom();
    });

    this.onUnpin = () => {
      this.pinned = false;
      this._userIntent = true;
    };
    this.el.addEventListener("handbeam:unpin-chat-scroll", this.onUnpin);
  },

  updated() {
    this.maybeScrollToBottom();
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    if (this.el) {
      this.el.removeEventListener("scroll", this.onScroll);
      this.el.removeEventListener("wheel", this.onUserIntent);
      this.el.removeEventListener("touchstart", this.onUserIntent);
      this.el.removeEventListener("pointerdown", this.onUserIntent);
      this.el.removeEventListener("handbeam:unpin-chat-scroll", this.onUnpin);
    }
  },

  maybeScrollToBottom() {
    if (!this.pinned) return;
    this.scrollToBottom();
  },

  scrollToBottom() {
    const el = this.el;
    if (!el) return;
    this._programmatic = true;
    const apply = () => {
      el.scrollTop = el.scrollHeight;
    };
    apply();
    requestAnimationFrame(() => {
      apply();
      requestAnimationFrame(() => {
        apply();
        this._programmatic = false;
      });
    });
  },
};

export default ChatScroll;
