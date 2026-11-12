// Fetch the Electron dist for the current platform when the package
// postinstall cannot do it (e.g. inside a minimal container image).
//
// Original work by xingguangcuican6666.
//
// Usage: node ci/fetch-electron.js
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const root = process.cwd();
const electronDir = path.join(root, "node_modules", "electron");
const version = require(path.join(electronDir, "package.json")).version;
const platform = process.env.npm_config_platform || process.platform;
const arch = process.env.npm_config_arch || process.arch;

async function main() {
  console.log(`fetching Electron ${version} (${platform}-${arch})`);
  const zip = await require("@electron/get").downloadArtifact({
    version,
    artifactName: "electron",
    platform,
    arch,
  });
  const dest = path.join(electronDir, "dist");
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  // bsdtar handles the zip natively; no extra JS dependency is needed.
  execFileSync("bsdtar", ["-xf", zip, "-C", dest], { stdio: "inherit" });
  const entry = platform === "win32" ? "electron.exe" : "electron";
  fs.writeFileSync(path.join(electronDir, "path.txt"), entry);
  console.log("electron dist ready at", dest);
}

main().catch((error) => {
  console.error("electron download failed:", error && error.message);
  process.exit(1);
});
