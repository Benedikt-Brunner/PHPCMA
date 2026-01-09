<?php

declare(strict_types=1);

namespace Test;

/**
 * This service correctly calls setup() before log()
 */
class GoodService
{
    public function __construct(
        private readonly Logger $logger,
    ) {}

    public function doWork(): void
    {
        $this->logger->setup('GoodService');

        // Do some work...

        $this->logger->log('Work completed successfully');
        $this->logger->reset();
    }

    public function doMoreWork(): void
    {
        $this->logger->setup('GoodService::doMoreWork');
        $this->logger->log('Starting more work');

        // More work...

        $this->logger->log('More work done');
        $this->logger->reset();
    }
}
