import { NextResponse } from 'next/server';

export async function GET() {
  const nestUrl = process.env.NEST_URL ?? 'http://localhost:3000';
  try {
    const data = await fetch(`${nestUrl}/ping`).then((r) => r.json());
    return NextResponse.json(data);
  } catch {
    return NextResponse.json({ error: 'upstream unavailable' }, { status: 502 });
  }
}
