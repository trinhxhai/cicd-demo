import { NestFactory } from '@nestjs/core';
import { AppModule } from './app/app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.enableShutdownHooks();
  const port = process.env.PORT ?? 3000;
  await app.listen(port);
  console.log(`SERVICE_SECRET: ${process.env.SERVICE_SECRET ?? '(not set)'}`);
}

bootstrap();
