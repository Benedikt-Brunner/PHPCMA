<?php

declare(strict_types=1);

namespace Test;

/**
 * Middle layer service - calls InnerService which calls log()
 * Does NOT call setup() itself - relies on callers to do so
 */
class MiddleService
{
    public function __construct(
        private readonly InnerService $innerService,
    ) {}

    public function doMiddleWork(): void
    {
        // This delegates to InnerService which calls log()
        // We don't call setup() here - the caller (DeepCaller) should have done it
        $this->innerService->doInnerWork();
    }
}
