// Static preview server for desktop/src with a mocked Tauri bridge injected
// before app.js, so the v4 UI can be exercised in an ordinary browser without
// building the Tauri app. Usage (from the toolkit root):
//
//   node desktop/dev/preview-server.js desktop/src desktop/dev 4173
//
// Then open http://localhost:4173/ (or classic.html). Everything the page
// invokes goes to mock-tauri.js, which fakes projects, agents, intent
// resolution and streaming missions.
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.resolve(process.argv[2] || "desktop/src");
const mockDir = path.resolve(process.argv[3] || "desktop/dev");
const port = Number(process.argv[4] || 4173);
const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8"
};

http.createServer((request, response) => {
  let file = decodeURIComponent(request.url.split("?")[0]);
  if (file === "/") file = "/index.html";
  const fromRoot = path.join(root, file);
  const full = file === "/__mock.js" ? path.join(mockDir, "mock-tauri.js")
    : fs.existsSync(fromRoot) ? fromRoot : path.join(mockDir, file);
  if (!full.startsWith(root) && !full.startsWith(mockDir)) {
    response.writeHead(403);
    response.end("forbidden");
    return;
  }
  fs.readFile(full, (error, data) => {
    if (error) {
      response.writeHead(404);
      response.end("not found: " + file);
      return;
    }
    let body = data;
    if (file === "/index.html" || file === "/classic.html") {
      body = Buffer.from(
        data.toString("utf8").replace(/<script src="(app|classic|control)\.js"><\/script>/, '<script src="/__mock.js"></script><script src="$1.js"></script>'),
        "utf8"
      );
    }
    response.writeHead(200, { "Content-Type": types[path.extname(full)] || "application/octet-stream", "Cache-Control": "no-store" });
    response.end(body);
  });
}).listen(port, "127.0.0.1", () => console.log(`AgentSync Max preview: http://localhost:${port}/ (mocked Tauri bridge)`));
