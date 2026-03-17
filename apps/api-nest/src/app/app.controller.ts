import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { AppService } from './app.service';

@Controller()
export class AppController {
  constructor(private readonly appService: AppService) {}

  @Get('ping')
  async ping() {
    try {
      const downstream = await this.appService.ping();
      return { service: 'nest', status: 'ok', downstream };
    } catch {
      throw new HttpException('downstream unavailable', HttpStatus.BAD_GATEWAY);
    }
  }
}
