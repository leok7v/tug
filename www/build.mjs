// Build the self-contained www/index.html: encode each source image to AVIF
// (via ImageMagick) and inline it as a base64 data: URI in index.template.html.
// The result has zero external dependencies — one file, one HTTP request.
//
//   node build.mjs          (or: make)
//
// Requires `magick` (ImageMagick with libheif/AVIF). The built index.html is
// committed, so GitHub Pages / CI never needs an AVIF encoder.

import { execSync } from "node:child_process";
import { readFileSync, writeFileSync, rmSync } from "node:fs";

// placeholder -> { source image, max dimension, AVIF quality (0..100) }
const images = {
  TUG_DOCKER: { src: "tug-docker.png",    resize: "1600x1600>", q: 60 },
  TUG_WAY:    { src: "the-tug-way.png",    resize: "1600x1600>", q: 58 },
  LESS_MORE:  { src: "less-is-more.jpeg",  resize: "1400x1400>", q: 62 },
};

let html = readFileSync("index.template.html", "utf8");
const tmp = "build.tmp.avif";

for (const [key, { src, resize, q }] of Object.entries(images)) {
  execSync(`magick ${JSON.stringify(src)} -resize '${resize}' -strip -quality ${q} ${tmp}`,
           { stdio: "inherit" });
  const b64 = readFileSync(tmp).toString("base64");
  const before = html.length;
  html = html.replaceAll(`@@${key}@@`, `data:image/avif;base64,${b64}`);
  if (html.length === before) console.warn(`! placeholder @@${key}@@ not found in template`);
  console.log(`${src.padEnd(22)} -> AVIF ${(b64.length / 1024 | 0)}K base64`);
}
try { rmSync(tmp); } catch {}

writeFileSync("index.html", html);
console.log(`built index.html (${(html.length / 1024 | 0)}K, self-contained)`);

// og.jpg — social-share preview (a real file; data: URIs aren't read by scrapers).
// The page itself stays fully self-contained; this is only fetched by link unfurlers.
execSync(`magick tug-docker.png -resize 1200x630^ -gravity center -extent 1200x630 -strip -quality 82 og.jpg`,
         { stdio: "inherit" });
console.log("built og.jpg (1200x630 social card)");
