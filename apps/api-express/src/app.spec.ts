import request from 'supertest';
import app from './app';

const mockPythonResponse = {
  service: 'python',
  status: 'ok',
};

describe('GET /ping', () => {
  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => mockPythonResponse,
    } as Response);
  });

  afterEach(() => {
    jest.resetAllMocks();
  });

  it('returns express service info with python downstream', async () => {
    const res = await request(app).get('/ping');
    expect(res.status).toBe(200);
    expect(res.body.service).toBe('express');
    expect(res.body.status).toBe('ok');
    expect(res.body.downstream).toEqual(mockPythonResponse);
  });

  it('calls PYTHON_URL/ping once', async () => {
    process.env.PYTHON_URL = 'http://fake-python:8000';
    await request(app).get('/ping');
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledWith('http://fake-python:8000/ping');
  });
});
