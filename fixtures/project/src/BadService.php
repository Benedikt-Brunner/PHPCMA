<?php

declare(strict_types=1);

namespace Test;

/**
 * This service has a BUG: it calls log() without calling setup() first
 */
class BadService
{
    public function __construct(
        private readonly Logger $logger,
    ) {}

    public function doWork(): void
    {
        // BUG: Missing setup() call before log()!
        $this->logger->log('This will fail at runtime');
    }
}
