import express, { Request, Response } from 'express';

const app = express();
app.use(express.json());

app.get('/ping', async (_req: Request, res: Response) => {
  const pythonUrl = process.env.PYTHON_URL ?? 'http://localhost:8000';
  const downstream = await fetch(`${pythonUrl}/ping`).then((r) => r.json());
  res.json({ service: 'express', status: 'ok', downstream });
});

export default app;
