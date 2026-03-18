import { Injectable } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';

@Injectable()
export class AppService {
  constructor(private readonly http: HttpService) {}

  async ping(): Promise<unknown> {
    const expressUrl = process.env.EXPRESS_URL ?? 'http://localhost:3001';
    try {
      const { data } = await firstValueFrom(this.http.get(`${expressUrl}/ping`));
      return data;
    } catch (err) {
      console.error('[api-nest] downstream call failed:', err);
      throw new Error('downstream unavailable');
    }
  }
}
