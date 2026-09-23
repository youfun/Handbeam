export const CopyText = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy || "";
      if (!text) return;

      const done = () => {
        this.el.dataset.copied = "true";
        window.setTimeout(() => this.el.removeAttribute("data-copied"), 1500);
      };

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(() => {});
      }
    });
  },
};

export default CopyText;
