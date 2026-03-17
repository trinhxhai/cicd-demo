import axios from 'axios';

describe('GET /ping', () => {
  it('GET /ping returns chain response', async () => {
    const res = await axios.get(`/ping`);

    expect(res.status).toBe(200);
    expect(res.data.service).toBe('nest');
    expect(res.data.status).toBe('ok');
  });
});
