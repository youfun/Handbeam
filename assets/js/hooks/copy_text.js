export const CopyText = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy || "";
      if (!text) return;

      const done = () => {
        this.el.dataset.copied = "true";
        window.setTimeout(() => this.el.removeAttribute("data-copied"), 1500);
      };

      const fallback = () => {
        const input = document.createElement("textarea");
        input.value = text;
        input.setAttribute("readonly", "");
        input.style.position = "fixed";
        input.style.left = "-9999px";
        document.body.appendChild(input);
        input.select();

        try {
          if (document.execCommand("copy")) done();
        } finally {
          input.remove();
        }
      };

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(fallback);
      } else {
        fallback();
      }
    });
  },
};

export default CopyText;
