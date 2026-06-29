<?php

declare(strict_types=1);

namespace Test;

/**
 * This service calls setup() at the top level, then calls MiddleService
 * which eventually calls log() through InnerService.
 *
 * Call chain: DeepCaller::process -> MiddleService::doMiddleWork -> InnerService::doInnerWork -> Logger::log
 *
 * setup() is called at line 26 in DeepCaller::process
 * log() is called at line 19 in InnerService::doInnerWork
 *
 * The constraint IS satisfied because setup() is called before the chain that leads to log()
 */
class DeepCaller
{
    public function __construct(
        private readonly Logger $logger,
        private readonly MiddleService $middleService,
    ) {}

    public function process(): void
    {
        // Setup is called here (2 levels above the log call)
        $this->logger->setup('DeepCaller');

        // This calls MiddleService which calls InnerService which calls log()
        $this->middleService->doMiddleWork();

        $this->logger->reset();
    }
}
