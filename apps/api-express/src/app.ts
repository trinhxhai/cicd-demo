import express, { Request, Response } from 'express';

const app: express.Express = express();
app.use(express.json());

app.get('/ping', async (_req: Request, res: Response) => {
  const pythonUrl = process.env.PYTHON_URL ?? 'http://localhost:8000';
  try {
    const downstream = await fetch(`${pythonUrl}/ping`, {
      signal: AbortSignal.timeout(5000),
    }).then((r) => r.json());
    res.json({ service: 'express', status: 'ok', message: 'message from express', downstream });
  } catch (err) {
    console.error('[api-express] downstream call failed:', err);
    res.status(502).json({ service: 'express', status: 'error', error: 'downstream unavailable' });
  }
});

export default app;
