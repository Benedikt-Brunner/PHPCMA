<?php

declare(strict_types=1);

namespace Tests;

use Test\Logger;

/**
 * A test-only caller of Logger::log, used to exercise the `exclude_tests`
 * edge filter: this caller must appear by default but vanish when
 * `edge_filter.exclude_tests` is set.
 */
class LoggerUsageTest
{
    public function testLogging(Logger $logger): void
    {
        $logger->setup('test');
        $logger->log('from a test');
    }
}
