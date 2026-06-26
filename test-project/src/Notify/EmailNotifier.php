<?php

declare(strict_types=1);

namespace Test\Notify;

/**
 * The sole in-project implementor of NotifierInterface. Because it is unique,
 * Phase A DI-aware resolution can bind interface-typed calls to it.
 */
class EmailNotifier implements NotifierInterface
{
    public function send(string $message): void
    {
        // Pretend to send an email.
    }
}
