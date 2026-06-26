<?php

declare(strict_types=1);

namespace Test\Notify;

/**
 * A notification channel abstraction. Production code depends on this
 * interface and Symfony DI injects the single concrete implementor.
 */
interface NotifierInterface
{
    public function send(string $message): void;
}
