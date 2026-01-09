<?php

declare(strict_types=1);

namespace Test;

/**
 * This service delegates to InnerService which calls log() without setup()
 * The constraint is satisfied because THIS method calls setup() before delegating
 */
class DelegatingService
{
    public function __construct(
        private readonly Logger $logger,
        private readonly InnerService $innerService,
    ) {}

    public function processWithSetup(): void
    {
        // Setup is called here
        $this->logger->setup('DelegatingService');

        // Then we delegate to inner service which calls log()
        $this->innerService->doInnerWork();

        $this->logger->reset();
    }

    public function processWithoutSetup(): void
    {
        // BUG: No setup() call before delegating
        $this->innerService->doInnerWork();
    }
}
