<?php

declare(strict_types=1);

namespace Test;

/**
 * Another caller of InnerService - this one does NOT call setup() first
 * This should cause InnerService::doInnerWork to be flagged as a violation
 */
class AnotherCaller
{
    public function __construct(
        private readonly InnerService $innerService,
    ) {}

    public function callWithoutSetup(): void
    {
        // BUG: This path doesn't call setup() before InnerService calls log()
        $this->innerService->doInnerWork();
    }
}
