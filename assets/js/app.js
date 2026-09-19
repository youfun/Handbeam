import { StreamingMarkdown } from "./hooks/streaming_markdown.js";
import { ChatScroll } from "./hooks/chat_scroll.js";
import { ConversationNav } from "./hooks/conversation_nav.js";
import { ComposerPasteUpload } from "./hooks/composer_paste_upload.js";
import { WorkspacePanel } from "./hooks/workspace_panel.js";
import { CopyText } from "./hooks/copy_text.js";
import { GhosttyTerminal } from "../vendor/ghostty.js";

// Theme initialization
let theme = 'light';
try {
  theme = localStorage.getItem('handbeam-theme') || 'light';
} catch (_) {}

document.documentElement.setAttribute('data-theme', theme);

// Phoenix LiveView client-side integration
// Dependencies loaded as regular scripts in the layout:
// - /assets/js/phoenix.js  (provides window.Phoenix.Socket)
// - /assets/js/phoenix_live_view.js (provides window.LiveView.LiveSocket)

// MobHook — Mob LiveView bridge. Native WebView injects window.mob pointing
// at the NIF. In LiveView mode this hook replaces it so handle_event/3 in
// LiveView receives JS messages. Requires #mob-bridge in root.html.heex.
const MobHook = {
  mounted() {
    window.mob = {
      send: (data) => this.pushEvent("mob_message", data),
      onMessage: (handler) => this.handleEvent("mob_push", handler),
      _dispatch: () => {}
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let Hooks = { StreamingMarkdown, ChatScroll, ConversationNav, ComposerPasteUpload, WorkspacePanel, CopyText, GhosttyTerminal, MobHook };

try {
  let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    hooks: Hooks,
    params: {_csrf_token: csrfToken},
    longPollFallbackMs: 2500
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
} catch (error) {
  console.error("Handbeam LiveSocket failed to start", error);
}

// Handle flash close
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "");
  });
});
