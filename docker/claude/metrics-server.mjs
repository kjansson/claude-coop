// metrics-server.mjs — Lightweight Prometheus metrics endpoint
// Serves the contents of a Prometheus text-format file written by statusline.sh
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';

const PORT = parseInt(process.env.METRICS_PORT || '9465', 10);
const METRICS_FILES = [
  '/tmp/claude-env-info.prom',
  '/tmp/claude-statusline-metrics.prom',
  '/tmp/claude-hooks-metrics.prom',
];

async function readMetricsFile(path) {
  try {
    return await readFile(path, 'utf-8');
  } catch {
    return '';
  }
}

const server = createServer(async (req, res) => {
  if (req.url === '/metrics' && req.method === 'GET') {
    const parts = await Promise.all(METRICS_FILES.map(readMetricsFile));
    const combined = parts.filter(Boolean).join('\n');
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4; charset=utf-8' });
    res.end(combined || '# No metrics yet - waiting for first assistant message\n');
  } else {
    res.writeHead(404);
    res.end('Not Found\n');
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[metrics-server] Serving Prometheus metrics on :${PORT}/metrics`);
});
