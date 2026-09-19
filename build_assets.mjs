import { build, context } from "esbuild";
import { copyFile, mkdir } from "node:fs/promises";

await mkdir("priv/static/assets/js", { recursive: true });
await Promise.all([
  copyFile("deps/phoenix/priv/static/phoenix.js", "priv/static/assets/js/phoenix.js"),
  copyFile(
    "deps/phoenix_live_view/priv/static/phoenix_live_view.js",
    "priv/static/assets/js/phoenix_live_view.js"
  )
]);

const options = {
  entryPoints: ["assets/js/app.js"],
  bundle: true,
  format: "iife",
  target: "es2020",
  outfile: "priv/static/assets/js/app.js",
  sourcemap: false,
  minify: false
};

if (process.argv.includes("--watch")) {
  const ctx = await context(options);
  await ctx.watch();
  console.log("watching assets/js -> priv/static/assets/js/app.js");
} else {
  await build(options);
}
