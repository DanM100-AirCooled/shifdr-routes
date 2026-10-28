// A static server for local tests: serves the repo and applies the rewrites in vercel.json,
// so /e/<CODE> opens the app the way it does on Vercel.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const rewrites = JSON.parse(fs.readFileSync(path.join(root, "vercel.json"), "utf8")).rewrites || [];
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".css": "text/css", ".svg": "image/svg+xml" };

export function serve(port = 8765) {
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    for (const r of rewrites) {
      if (new RegExp("^" + r.source.replace(/:[a-z]+/gi, "[^/]+") + "/?$").test(p)) { p = r.destination; break; }
    }
    if (p.endsWith("/")) p += "index.html";
    const file = path.join(root, p);
    if (!file.startsWith(root) || /[\\/](node_modules|\.git)[\\/]/.test(file)) { res.writeHead(403); return res.end(); }
    fs.readFile(file, (err, buf) => {
      if (err) { res.writeHead(404); return res.end("Not found"); }
      res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" });
      res.end(buf);
    });
  });
  return new Promise(ok => server.listen(port, "127.0.0.1", () => ok(server)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = +process.argv[2] || 8765;
  serve(port).then(() => console.log(`http://127.0.0.1:${port}`));
}
