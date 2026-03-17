export default async function Home() {
  const baseUrl = process.env.NEXT_PUBLIC_BASE_URL ?? 'http://localhost:4000';
  let chain: Record<string, unknown> | null = null;
  let error: string | null = null;

  try {
    const res = await fetch(`${baseUrl}/api/ping`, { cache: 'no-store' });
    if (!res.ok) {
      error = `Backend returned ${res.status}`;
    } else {
      chain = await res.json();
    }
  } catch (e) {
    error = 'Could not reach backend chain.';
  }

  return (
    <main style={{ fontFamily: 'monospace', padding: '2rem' }}>
      <h1>Echo / Ping Chain</h1>
      {error && <p style={{ color: 'red' }}>{error}</p>}
      {chain && <pre>{JSON.stringify(chain, null, 2)}</pre>}
    </main>
  );
}
