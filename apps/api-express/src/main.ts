import app from './app';

const port = process.env.PORT ?? 3001;
const server = app.listen(port, () => {
  console.log(`api-express listening on port ${port}`);
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
