import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "../..");

const mimeTypes = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".json": "application/json",
  ".css": "text/css",
  ".wasm": "application/wasm",
  ".png": "image/png",
};

const server = http.createServer((req, res) => {
  let reqPath = req.url || "/";
  if (reqPath === "/") reqPath = "/index.html";

  let filePath;
  if (reqPath.startsWith("/node_modules/")) {
    filePath = path.join(rootDir, reqPath);
  } else {
    filePath = path.join(__dirname, reqPath);
  }

  const ext = path.extname(filePath);
  const contentType = mimeTypes[ext] || "text/plain";

  fs.readFile(filePath, (err, content) => {
    if (err) {
      if (err.code === "ENOENT") {
        res.writeHead(404, { "Content-Type": "text/plain" });
        res.end("404 Not Found");
      } else {
        res.writeHead(500);
        res.end("500 Server Error");
      }
    } else {
      res.writeHead(200, { "Content-Type": contentType });
      res.end(content);
    }
  });
});

const PORT = 3000;
server.listen(PORT, () => {
  console.log(`Doppio Reference PWA running at http://localhost:${PORT}/`);
});
