import { Test, TestingModule } from '@nestjs/testing';
import { AppController } from './app.controller';
import { AppService } from './app.service';

describe('AppController', () => {
  let controller: AppController;
  let service: AppService;

  const mockExpressResponse = {
    service: 'express',
    status: 'ok',
    downstream: { service: 'python', status: 'ok' },
  };

  beforeEach(async () => {
    const app: TestingModule = await Test.createTestingModule({
      controllers: [AppController],
      providers: [
        {
          provide: AppService,
          useValue: { ping: jest.fn().mockResolvedValue(mockExpressResponse) },
        },
      ],
    }).compile();

    controller = app.get(AppController);
    service = app.get(AppService);
  });

  describe('GET /ping', () => {
    it('returns nest service info with express+python downstream', async () => {
      const result = await controller.ping();
      expect(result.service).toBe('nest');
      expect(result.status).toBe('ok');
      expect(result.downstream).toEqual(mockExpressResponse);
    });

    it('delegates to AppService.ping()', async () => {
      await controller.ping();
      expect(service.ping).toHaveBeenCalledTimes(1);
    });

    it('returns 502 when downstream throws', async () => {
      (service.ping as jest.Mock).mockRejectedValueOnce(new Error('downstream unavailable'));
      await expect(controller.ping()).rejects.toMatchObject({
        status: 502,
      });
    });
  });
});
