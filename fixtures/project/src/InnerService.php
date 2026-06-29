<?php

declare(strict_types=1);

namespace Test;

/**
 * Inner service that calls log() - constraint satisfied if ALL callers call setup() first
 */
class InnerService
{
    public function __construct(
        private readonly Logger $logger,
    ) {}

    public function doInnerWork(): void
    {
        // This calls log() without setup() - but should be OK if all callers setup first
        $this->logger->log('Inner work in progress');
    }
}
