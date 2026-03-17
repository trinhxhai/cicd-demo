// Mock Next.js Response before imports
const mockJson = jest.fn();
jest.mock('next/server', () => ({
  NextResponse: {
    json: (data: unknown, options?: unknown) => {
      mockJson(data, options);
      return { body: data, options };
    },
  },
}));

describe('GET /api/ping', () => {
  const mockNestResponse = {
    service: 'nest',
    status: 'ok',
    downstream: {
      service: 'express',
      status: 'ok',
      downstream: { service: 'python', status: 'ok' },
    },
  };

  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => mockNestResponse,
    } as Response);
    process.env.NEST_URL = 'http://fake-nest:3000';
  });

  afterEach(() => {
    jest.resetAllMocks();
    delete process.env.NEST_URL;
  });

  it('returns the full chain from NestJS', async () => {
    const { GET } = await import('./route');
    const response = await GET();
    expect(mockJson).toHaveBeenCalledWith(mockNestResponse, undefined);
  });

  it('calls NEST_URL/ping', async () => {
    const { GET } = await import('./route');
    await GET();
    expect(global.fetch).toHaveBeenCalledWith('http://fake-nest:3000/ping');
  });

  it('returns 502 when NEST_URL is unreachable', async () => {
    global.fetch = jest.fn().mockRejectedValue(new Error('ECONNREFUSED'));
    const { GET } = await import('./route');
    const response = await GET();
    expect(mockJson).toHaveBeenCalledWith(
      { error: 'upstream unavailable' },
      { status: 502 }
    );
  });
});
