<?php

declare(strict_types=1);

namespace Test;

/**
 * Simple logger that requires setup() to be called before log()
 */
class Logger
{
    public function setup(string $context): void
    {
        // Initialize logging context
    }

    public function log(string $message): void
    {
        // Log the message
    }

    public function reset(): void
    {
        // Reset the logger
    }
}
